import Foundation
import Darwin
import CryptoKit

/// `llmavail --verify`: hash every file against the hash it was downloaded under, and (with `--access`) check that
/// those hashes and sizes are the ones the Hub lists for the cached revision.
///
/// Where the reference hash comes from:
/// - Hugging Face cache: a snapshot file links to `blobs/<name>`, and the name is the hash the Hub gave at download
///   (its ETag): the SHA-256 for large (LFS) files, the git blob SHA-1 for small ones.
/// - Ollama: every layer, config and manifest blob is `blobs/sha256-<hash of its content>`.
/// - LM Studio and loose folders keep no hash, so there is nothing to check their files against.
///
/// Read-only, and a file whose access time a read would change is skipped, as everywhere in llmavail.
enum AvailVerify {
    enum Algo { case sha256, gitSHA1 }

    struct Ref {
        let rel: String       // path inside the model (snapshot-relative for HF; "blobs/sha256-…" for Ollama)
        let real: String      // the regular file the data is in
        let size: Int64
        let algo: Algo
        let hex: String       // the reference hash, lowercase
    }

    struct Summary {
        var files = 0, matched = 0, mismatched = 0, skipped = 0, failed = 0, unreferenced = 0
        var hub: String?      // with --access, HF only: what the Hub's file list said
        var status: String {
            if mismatched > 0 { return "mismatch" }
            if files == 0 { return unreferenced > 0 ? "no reference hash" : "nothing to hash" }
            return matched == files && unreferenced == 0 ? "verified" : "partly verified"
        }
    }

    enum Outcome { case match, mismatch, wouldTouch, failed }

    private static let sha256Name = #"^[0-9a-f]{64}$"#
    private static let sha1Name = #"^[0-9a-f]{40}$"#

    /// The reference for an HF snapshot file: the name of the blob its link points at.
    static func hfRef(rel: String, path: String, real: String, size: Int64) -> Ref? {
        guard let dest = try? FileManager.default.destinationOfSymbolicLink(atPath: path) else { return nil }
        let name = (dest as NSString).lastPathComponent
        if name.range(of: sha256Name, options: .regularExpression) != nil {
            return Ref(rel: rel, real: real, size: size, algo: .sha256, hex: name)
        }
        if name.range(of: sha1Name, options: .regularExpression) != nil {
            return Ref(rel: rel, real: real, size: size, algo: .gitSHA1, hex: name)
        }
        return nil
    }

    /// Hashes one file. Streams it in 8 MB pieces without filling the page cache (F_NOCACHE), so a hash run doesn't
    /// push loaded models out of memory. `progress` gets the bytes read so far.
    static func hash(_ ref: Ref, progress: (Int64) -> Void = { _ in }) -> Outcome {
        let r: Avail.FileRead<Bool> = Avail.withRegularFile(ref.real) { fd, size -> Bool? in
            guard size == ref.size else { return nil }   // changed since the scan
            _ = fcntl(fd, F_NOCACHE, 1)
            var sha256 = SHA256()
            var sha1 = Insecure.SHA1()
            if ref.algo == .gitSHA1 { sha1.update(data: Data("blob \(size)\0".utf8)) }
            let chunk = 8 << 20
            let buf = UnsafeMutableRawPointer.allocate(byteCount: chunk, alignment: 16)
            defer { buf.deallocate() }
            var total: Int64 = 0
            while true {
                let n = read(fd, buf, chunk)
                if n < 0 { if errno == EINTR { continue }; return nil }
                if n == 0 { break }
                let piece = UnsafeRawBufferPointer(start: buf, count: n)
                if ref.algo == .sha256 { sha256.update(bufferPointer: piece) } else { sha1.update(bufferPointer: piece) }
                total += Int64(n)
                progress(total)
            }
            guard total == size else { return nil }
            let hex = ref.algo == .sha256 ? sha256.finalize().map { String(format: "%02x", $0) }.joined()
                                          : sha1.finalize().map { String(format: "%02x", $0) }.joined()
            return hex == ref.hex
        }
        switch r {
        case .ok(true): return .match
        case .ok(false): return .mismatch
        case .wouldTouch: return .wouldTouch
        case .failed: return .failed
        }
    }

    /// Hashes every row's files (each real file once, a few at a time), then fills `verify`, problems and
    /// unchecked. Progress goes to stderr when it's a terminal.
    static func run(_ rows: inout [Avail.Row], hub: Bool, token: String?, login: HFAccess.Login?) {
        var unique: [String: Ref] = [:]
        for r in rows { for ref in r.hashRefs where unique[ref.real] == nil { unique[ref.real] = ref } }
        let refs = unique.values.sorted { $0.size > $1.size }   // biggest first, so the tail runs in parallel
        let totalBytes = refs.reduce(Int64(0)) { $0 + $1.size }

        let lock = NSLock()
        var results: [String: Outcome] = [:]
        var doneBytes: Int64 = 0, doneFiles = 0
        let tty = isatty(2) == 1
        let start = Date()
        // Created only when it will run: libdispatch traps on releasing a timer that was never resumed.
        var ticker: DispatchSourceTimer?
        if tty && !refs.isEmpty {
            let t = DispatchSource.makeTimerSource(queue: .global())
            t.schedule(deadline: .now() + 1, repeating: 1)
            t.setEventHandler {
                lock.lock(); let b = doneBytes, f = doneFiles; lock.unlock()
                let rate = Double(b) / max(Date().timeIntervalSince(start), 0.1)
                let eta = rate > 0 ? Int(Double(totalBytes - b) / rate) : 0
                let line = "\rhashing: \(f) of \(refs.count) files, \(formatBytes(b)) of \(formatBytes(totalBytes)), "
                    + "\(formatBytes(Int64(rate)))/s, about \(eta / 60) min \(eta % 60) s left   "
                FileHandle.standardError.write(Data(line.utf8))
            }
            t.resume()
            ticker = t
        }
        let q = OperationQueue()
        q.maxConcurrentOperationCount = 3   // SSD-bound past this; ~2.5 GB/s per core for SHA-256
        for ref in refs {
            q.addOperation {
                var last: Int64 = 0
                let out = hash(ref) { n in
                    lock.lock(); doneBytes += n - last; lock.unlock()
                    last = n
                }
                lock.lock(); results[ref.real] = out; doneFiles += 1; doneBytes += ref.size - last; lock.unlock()
            }
        }
        q.waitUntilAllOperationsAreFinished()
        if let t = ticker {
            t.cancel()
            FileHandle.standardError.write(Data(("\r" + String(repeating: " ", count: 100) + "\r").utf8))
        }

        for i in rows.indices {
            var s = Summary()
            s.unreferenced = rows[i].unreferenced.count
            for ref in rows[i].hashRefs {
                s.files += 1
                switch results[ref.real] ?? .failed {
                case .match: s.matched += 1
                case .mismatch:
                    s.mismatched += 1
                    rows[i].problems.append("\(ref.rel): content doesn't match the hash it was downloaded under (damaged or altered)")
                case .wouldTouch:
                    s.skipped += 1
                    rows[i].unchecked.append("\(ref.rel): not hashed (\(Avail.touchReason))")
                case .failed:
                    s.failed += 1
                    rows[i].unchecked.append("\(ref.rel): couldn't be hashed (unreadable, or changed while checking)")
                }
            }
            rows[i].verify = s
        }

        guard hub else { return }
        let hfRows = rows.indices.filter { rows[$0].source == "hf" && !rows[$0].hashRefs.isEmpty }   // nothing cached, nothing to compare
        var replies: [Int: (files: [String: HFAccess.HubFile]?, error: String?)] = [:]
        let hq = OperationQueue()
        hq.maxConcurrentOperationCount = 6
        for i in hfRows {
            let (name, rev) = (rows[i].name, rows[i].revision)
            hq.addOperation {
                let r = HFAccess.revisionFiles(repo: name, revision: rev, token: token, login: login ?? .none)
                lock.lock(); replies[i] = r; lock.unlock()
            }
        }
        hq.waitUntilAllOperationsAreFinished()
        for i in hfRows {
            guard let reply = replies[i], let files = reply.files else {
                rows[i].verify?.hub = "not checked (\(replies[i]?.error ?? "no reply"))"
                continue
            }
            let c = compareHub(rows[i].hashRefs, files)
            rows[i].problems += c.problems
            rows[i].unchecked += c.notListed.map { "\($0): not in the Hub's file list for this revision" }
            rows[i].verify?.hub = c.problems.isEmpty ? "matches (\(c.compared) file\(c.compared == 1 ? "" : "s"))" : "differs"
        }
    }

    /// The Hub's file list for the revision against what is cached: each file's size, and the hash it was
    /// downloaded under. A difference means the cached file isn't the one the Hub has for that revision.
    static func compareHub(_ refs: [Ref], _ hub: [String: HFAccess.HubFile]) -> (problems: [String], notListed: [String], compared: Int) {
        var problems: [String] = [], notListed: [String] = [], compared = 0
        for ref in refs.sorted(by: { $0.rel < $1.rel }) {
            guard let h = hub[ref.rel] else { notListed.append(ref.rel); continue }
            compared += 1
            if let size = h.size, size != ref.size {
                problems.append("\(ref.rel): \(ref.size) bytes here, the Hub lists \(size) for this revision")
            }
            let expected = ref.algo == .sha256 ? h.sha256 : h.blobId
            if let e = expected, e != ref.hex {
                problems.append("\(ref.rel): downloaded under hash \(Avail.short(ref.hex)), the Hub lists \(Avail.short(e)) for this revision")
            }
        }
        return (problems, notListed, compared)
    }
}
