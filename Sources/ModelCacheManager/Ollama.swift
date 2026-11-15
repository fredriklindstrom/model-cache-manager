import Foundation
import Darwin
import CryptoKit

/// Ollama's own model store: `manifests/<host>/<namespace>/<model>/<tag>` JSON files that point at
/// content-addressed layers in `blobs/sha256-<hex>`. Layers are shared between tags and models, the
/// same problem as the Hugging Face `blobs/` store, so sizes, locks and deletes follow the same rules.
enum OllamaStore {
    static let defaultHost = "registry.ollama.ai"
    /// Ollama 0.40's `manifests-v2/` names the default registry `ollama.com`; `manifests/` says `registry.ollama.ai`.
    /// Both are the same model, so they get the same id (and Keep, notes and history carry over).
    static func normalHost(_ h: String) -> String { h.lowercased() == "ollama.com" ? defaultHost : h }
    /// Manifests are small JSON files; nothing bigger than this is ever read.
    private static let maxReadBytes = 4 << 20
    /// A manifest path component: no slash, no leading dot (so never "." or ".."). Only the host may hold a
    /// colon (`localhost:5000`), so `model:tag` always splits one way and two models can't share an id.
    private static let partPattern = #"^[A-Za-z0-9_][A-Za-z0-9_.-]{0,254}$"#
    private static let hostPattern = #"^[A-Za-z0-9_][A-Za-z0-9_.:-]{0,254}$"#
    /// Digests in either case: on a case-insensitive disk `sha256-ABC…` and `sha256-abc…` are the same file.
    private static let digestPattern = #"^sha256:[0-9a-fA-F]{64}$"#
    private static let mentionedDigest = try! NSRegularExpression(pattern: "sha256[:-]([0-9a-f]{64})", options: .caseInsensitive)

    /// Honours `OLLAMA_MODELS` (used verbatim, as Ollama does), then the default `~/.ollama/models`.
    static var root: URL {
        if let m = ProcessInfo.processInfo.environment["OLLAMA_MODELS"], !m.isEmpty { return URL(fileURLWithPath: m) }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".ollama/models")
    }

    /// The store exists here: `manifests/`, or Ollama 0.40's `manifests-v2/`. A manifests folder that is a symlink
    /// doesn't count: nothing is listed or deleted.
    static func isPresent(root: String) -> Bool {
        root != "/" && Deleter.isRealDirectory(root)
            && (Deleter.isRealDirectory(root + "/manifests") || Deleter.isRealDirectory(root + "/manifests-v2"))
    }

    private static func isValidPart(_ s: String) -> Bool { s.range(of: partPattern, options: .regularExpression) != nil }

    /// `<host>/<namespace>/<model>/<tag>`, each part valid for its place.
    static func isValidManifestPath(_ parts: [String]) -> Bool {
        parts.count == 4 && parts[0].range(of: hostPattern, options: .regularExpression) != nil
            && parts.dropFirst().allSatisfy(isValidPart)
    }

    static func blobPath(_ hex: String, root: String) -> String { root + "/blobs/sha256-" + hex }

    enum Layout { case v1, v2 }

    struct Manifest {
        /// v1: the manifest file (real path, no symlinks on the way). v2: the tag entry in `manifests-v2/`
        /// (usually a link into `blobs/`), never resolved.
        let path: String
        let host, namespace, model, tag: String   // host normalised (see normalHost)
        let digests: Set<String>      // hex of every blob it uses (config + layers; v2 also its manifest blobs)
        let fileDigest: String        // sha256 of the manifest bytes: what Ollama reports as the model's digest
        var layout = Layout.v1
        /// v2: the manifest blobs themselves (the tag's own and, for a manifest list, each variant's). Bookkeeping
        /// the app reads on every scan, so their dates are never evidence of use.
        var metaDigests = Set<String>()

        var qualifiedName: String { "\(host)/\(namespace)/\(model):\(tag)" }
        /// "qwen3:8b", "someone/model:tag" or "hf.co/org/repo:tag", like `ollama list`.
        var displayName: String {
            guard host == OllamaStore.defaultHost else { return qualifiedName }
            return namespace == "library" ? "\(model):\(tag)" : "\(namespace)/\(model):\(tag)"
        }
        var id: String {
            host == OllamaStore.defaultHost ? "ollama/\(namespace)/\(model):\(tag)" : "ollama/\(host)/\(namespace)/\(model):\(tag)"
        }
    }

    struct References {
        var manifests: [Manifest] = []    // manifests/ (the only layout this app deletes from)
        /// manifests-v2/ (Ollama 0.40+). Listed and sized, and every blob they use counts as used, but never deleted
        /// here: removing a v1 model must not take a layer a v2 manifest still needs.
        var v2: [Manifest] = []
        /// Lowercased ids of every v2 tag, duplicates included: a model with any of them is never deleted here.
        var v2IDs = Set<String>()
        /// Digests named by anything under `manifests/` that isn't a readable manifest (a symlink, a file in the
        /// wrong place, JSON we can't parse). Never listed, but those blobs always count as used by someone else.
        var unlisted = Set<String>()
        /// Why the walk couldn't read everything (an unreadable folder or file, a size or time budget hit).
        /// A reference it missed would make a shared blob look exclusive, so any entry here blocks Ollama deletes.
        var incomplete: [String] = []
        var isComplete: Bool { incomplete.isEmpty }
    }

    /// Every manifest in the store and the blobs it references. Cheap (small files), so it is re-run before deleting.
    static func references(root: String) -> References {
        var refs = References()
        var budget = 64 << 20   // total bytes read from odd entries, so a link to somewhere huge can't stall the scan
        walk(root + "/manifests", parts: [], into: &refs, budget: &budget)
        // Two manifests that map to the same id (only possible through odd names) are never listed; their blobs stay protected.
        let dupes = Dictionary(grouping: refs.manifests, by: \.id).filter { $0.value.count > 1 }
        for (_, ms) in dupes { for m in ms { refs.unlisted.formUnion(m.digests) } }
        refs.manifests.removeAll { dupes[$0.id] != nil }

        let v2 = root + "/manifests-v2"
        var st = stat()
        if lstat(v2, &st) == 0 {
            if (st.st_mode & S_IFMT) == S_IFDIR {
                walkV2(v2, parts: [], root: root, into: &refs, budget: &budget)
            } else {
                refs.incomplete.append("\(v2) is not a folder")   // a link here could hide references
            }
        } else if errno != ENOENT {
            refs.incomplete.append("can't inspect \(v2)")
        }
        refs.v2IDs = Set(refs.v2.map { $0.id.lowercased() })   // before duplicates are dropped (review M1)
        let dupes2 = Dictionary(grouping: refs.v2, by: \.id).filter { $0.value.count > 1 }
        for (_, ms) in dupes2 { for m in ms { refs.unlisted.formUnion(m.digests) } }
        refs.v2.removeAll { dupes2[$0.id] != nil }
        return refs
    }

    private static let blobName = #"^sha256-[0-9a-f]{64}$"#

    /// `manifests-v2/<host>/<namespace>/<model>/<tag>`: normally a link to the manifest's blob in `blobs/`. A
    /// manifest list (one manifest per runner: MLX, llama.cpp, …) names each variant's manifest, also a blob.
    /// A link to nothing names nothing; a link anywhere but `blobs/sha256-…` is read only for the digests it
    /// mentions, which then count as used.
    private static func walkV2(_ path: String, parts: [String], root: String, into refs: inout References, budget: inout Int) {
        var st = stat()
        guard lstat(path, &st) == 0 else {
            if errno != ENOENT { refs.incomplete.append("can't inspect \(path)") }
            return
        }
        let type = st.st_mode & S_IFMT
        // Hidden plain files above the tag level (Finder's .DS_Store) are read for any digests they mention, as in
        // manifests/, and otherwise ignored, so they don't block every delete (review 2, N1). Hidden links, folders
        // and anything at the tag level stay strict.
        if type == S_IFREG && parts.count < 4 && (path as NSString).lastPathComponent.hasPrefix(".") {
            refs.unlisted.formUnion(harvest(path, budget: &budget, incomplete: &refs.incomplete))
            return
        }
        if type == S_IFDIR && parts.count < 4 {
            guard let names = try? FileManager.default.contentsOfDirectory(atPath: path) else {
                refs.incomplete.append("can't list \(path)"); return
            }
            for n in names { walkV2(path + "/" + n, parts: parts + [n], root: root, into: &refs, budget: &budget) }
            return
        }
        if parts.count == 4 && (type == S_IFLNK || type == S_IFREG) {
            var target = stat()
            if type == S_IFLNK && stat(path, &target) != 0 {
                if errno != ENOENT { refs.incomplete.append("can't inspect \(path)") }
                return   // a deleted model's leftover link: nothing on disk to protect
            }
            let file = type == S_IFLNK ? realPath(path) : path
            let inBlobs = (file as NSString).deletingLastPathComponent == root + "/blobs"
                && (file as NSString).lastPathComponent.range(of: blobName, options: .regularExpression) != nil
            if type == S_IFREG || inBlobs {
                let done: Bool = autoreleasepool {
                    guard let data = readSmall(file) else { return false }
                    budget -= data.count
                    if budget < 0 { refs.incomplete.append("read budget used up at \(path)") }
                    guard let m = parseV2(path, parts, data, root: root, refs: &refs, budget: &budget) else {
                        refs.unlisted.formUnion(digestsMentioned(in: data))   // unparseable: everything it names stays protected
                        return false
                    }
                    refs.v2.append(m)
                    return true
                }
                if done { return }
            }
        }
        // Anything else here (a tag that can't be parsed in full, a link out of blobs/, a file in the wrong place) may
        // hide layers we can't see: no Ollama model is deleted until it's sorted out (security review 2026-11-15, H1).
        // Links are never followed out of the store; plain files are read for the digests they mention.
        refs.incomplete.append("can't fully read \(path) in manifests-v2")
        if type == S_IFREG { refs.unlisted.formUnion(harvest(path, budget: &budget, incomplete: &refs.incomplete)) }
    }

    /// One v2 tag: a manifest, or a manifest list whose variants are manifests in `blobs/`. A variant whose
    /// manifest blob is gone references nothing on disk; one that can't be read or parsed makes the store incomplete.
    private static func parseV2(_ path: String, _ parts: [String], _ data: Data, root: String,
                                refs: inout References, budget: inout Int) -> Manifest? {
        guard isValidManifestPath(parts),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let hex = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        var digests = Set([hex]), meta = Set([hex])
        var mentioned = digestsMentioned(in: data)   // anything digest-shaped in these files that isn't theirs counts as used
        func layers(_ j: [String: Any]) -> Set<String>? {
            guard var entries = j["layers"] as? [[String: Any]] else { return nil }
            if let c = j["config"] as? [String: Any] { entries.append(c) }
            var out = Set<String>()
            for e in entries {
                guard let d = e["digest"] as? String, d.range(of: digestPattern, options: .regularExpression) != nil else { return nil }
                out.insert(String(d.dropFirst("sha256:".count)).lowercased())
            }
            return out
        }
        if let list = json["manifests"] as? [[String: Any]] {
            for e in list {
                guard let d = e["digest"] as? String, d.range(of: digestPattern, options: .regularExpression) != nil else { return nil }
                let sub = String(d.dropFirst("sha256:".count)).lowercased()
                digests.insert(sub); meta.insert(sub)
                let blob = blobPath(sub, root: root)
                var st = stat()
                guard lstat(blob, &st) == 0 else {
                    if errno != ENOENT { refs.incomplete.append("can't inspect \(blob)") }
                    // Gone: its layers are named nowhere else, so nothing on disk is protected for it. Unless the tag
                    // changed in the last 10 minutes: then a pull may be writing it, reusing layers already here.
                    // Not covered: a pull that fetches a variant later under an older, unchanged tag and writes no
                    // -partial files (every layer already here). The same narrow race v1 pulls have.
                    var tag = stat()
                    let recent = Date().addingTimeInterval(-600).timeIntervalSince1970
                    if lstat(path, &tag) == 0, Double(tag.st_mtimespec.tv_sec) > recent {
                        refs.incomplete.append("\(path) changed in the last 10 minutes and names a variant that isn't on disk yet (a pull may be in progress)")
                    }
                    continue
                }
                guard (st.st_mode & S_IFMT) == S_IFREG, let sd = readSmall(blob) else {
                    refs.incomplete.append("can't read variant manifest \(blob)"); continue   // its layers can't be seen
                }
                budget -= sd.count
                if budget < 0 { refs.incomplete.append("read budget used up at \(blob)") }
                mentioned.formUnion(digestsMentioned(in: sd))
                guard let sj = try? JSONSerialization.jsonObject(with: sd) as? [String: Any], let ls = layers(sj) else {
                    refs.incomplete.append("can't parse variant manifest \(blob)"); continue
                }
                digests.formUnion(ls)
            }
        } else if let ls = layers(json) {
            digests.formUnion(ls)
        } else {
            return nil
        }
        refs.unlisted.formUnion(mentioned.subtracting(digests))   // as for v1
        var m = Manifest(path: path, host: normalHost(parts[0]), namespace: parts[1], model: parts[2], tag: parts[3],
                         digests: digests, fileDigest: hex)
        m.layout = .v2
        m.metaDigests = meta
        return m
    }

    private static func walk(_ path: String, parts: [String], into refs: inout References, budget: inout Int) {
        var st = stat()
        guard lstat(path, &st) == 0 else {
            if errno != ENOENT { refs.incomplete.append("can't inspect \(path)") }   // gone since listing is fine
            return
        }
        let type = st.st_mode & S_IFMT
        if type == S_IFDIR && parts.count < 4 {
            guard let names = try? FileManager.default.contentsOfDirectory(atPath: path) else {
                refs.incomplete.append("can't list \(path)"); return
            }
            for n in names { walk(path + "/" + n, parts: parts + [n], into: &refs, budget: &budget) }
            return
        }
        if type == S_IFREG && parts.count == 4 {
            let done: Bool = autoreleasepool {
                guard let data = readSmall(path), let m = parseManifest(path, parts, data) else { return false }
                budget -= data.count   // real manifests count too, so many huge ones can't stall the scan
                if budget < 0 { refs.incomplete.append("read budget used up at \(path)") }
                refs.manifests.append(m)
                // Anything else digest-shaped in the file also counts as in use, so an unexpected field can't hide a reference.
                refs.unlisted.formUnion(digestsMentioned(in: data).subtracting(m.digests))
                return true
            }
            if done { return }
        }
        refs.unlisted.formUnion(harvest(path, budget: &budget, incomplete: &refs.incomplete))
    }

    private static func parseManifest(_ path: String, _ parts: [String], _ data: Data) -> Manifest? {
        guard isValidManifestPath(parts),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              var entries = json["layers"] as? [[String: Any]] else { return nil }
        if let c = json["config"] as? [String: Any] { entries.append(c) }
        var digests = Set<String>()
        for e in entries {
            guard let d = e["digest"] as? String, d.range(of: digestPattern, options: .regularExpression) != nil else { return nil }
            digests.insert(String(d.dropFirst("sha256:".count)).lowercased())
        }
        let hex = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        return Manifest(path: path, host: normalHost(parts[0]), namespace: parts[1], model: parts[2], tag: parts[3],
                        digests: digests, fileDigest: hex)
    }

    /// Reads a small regular file. Opened non-blocking and checked on the open descriptor, so a file swapped
    /// for a pipe or device after a check can't hang the scan (and the background agent with it).
    private static func readSmall(_ path: String) -> Data? {
        let fd = open(path, O_RDONLY | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { return nil }
        let h = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        var st = stat()
        guard fstat(fd, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG, st.st_size <= maxReadBytes else { return nil }
        guard let data = try? h.read(upToCount: maxReadBytes + 1), data.count <= maxReadBytes else { return nil }
        return data
    }

    /// Digests anywhere in a file: in the raw text, and in every JSON string or key once decoded, because
    /// Ollama's JSON reader accepts escapes like `sha256\u003a…` that a plain text search would miss.
    private static func digestsMentioned(in data: Data) -> Set<String> {
        var texts = [String(decoding: data, as: UTF8.self)]
        if let json = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) {
            func collect(_ v: Any) {
                if let s = v as? String { texts.append(s) }
                else if let a = v as? [Any] { a.forEach(collect) }
                else if let d = v as? [String: Any] { for (k, x) in d { texts.append(k); collect(x) } }
            }
            collect(json)
        }
        var found = Set<String>()
        for text in texts {
            let ns = text as NSString
            for m in mentionedDigest.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
                found.insert(ns.substring(with: m.range(at: 1)).lowercased())
            }
        }
        return found
    }

    /// Every digest mentioned in a file, or in the files under a folder (symlinks followed, bounded).
    /// Anything it can't read, or a budget it runs out of, is recorded in `incomplete`.
    private static func harvest(_ path: String, budget: inout Int, incomplete: inout [String]) -> Set<String> {
        var found = Set<String>()
        let real = realPath(path)
        func take(_ p: String) {
            guard budget > 0 else { incomplete.append("read budget used up at \(p)"); return }
            autoreleasepool {
                guard let d = readSmall(p) else { incomplete.append("can't read \(p) (unreadable or over 4 MB)"); return }
                budget -= d.count
                found.formUnion(digestsMentioned(in: d))
            }
        }
        var st = stat()
        guard stat(real, &st) == 0 else {
            if errno != ENOENT { incomplete.append("can't inspect \(path)") }   // a link to nothing names nothing
            return found
        }
        switch st.st_mode & S_IFMT {
        case S_IFREG: take(real); return found
        case S_IFDIR: break
        default: return found   // a socket, pipe or device holds no manifest
        }
        var failed = false
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey]
        guard let en = FileManager.default.enumerator(at: URL(fileURLWithPath: real), includingPropertiesForKeys: Array(keys),
                                                      options: [], errorHandler: { _, _ in failed = true; return true }) else {
            incomplete.append("can't list \(path)"); return found
        }
        var seen = 0
        for case let u as URL in en {
            seen += 1
            if seen > 20_000 { incomplete.append("more than 20,000 files under \(path)"); break }
            if budget <= 0 { incomplete.append("read budget used up under \(path)"); break }
            guard let v = try? u.resourceValues(forKeys: keys) else { incomplete.append("can't inspect \(u.path)"); continue }
            if v.isRegularFile == true { take(u.path); continue }
            guard v.isSymbolicLink == true else { continue }   // folders are walked by the enumerator itself
            var t = stat()
            if stat(u.path, &t) != 0 {
                if errno != ENOENT { incomplete.append("can't inspect \(u.path)") }
            } else if (t.st_mode & S_IFMT) == S_IFREG {
                take(u.path)
            } else if (t.st_mode & S_IFMT) == S_IFDIR {
                incomplete.append("a folder link at \(u.path)")   // not followed: could loop or point anywhere
            }
        }
        if failed { incomplete.append("can't read everything under \(path)") }
        return found
    }

    struct Scan {
        var root = ""
        var present = false
        var models: [CachedModel] = []
        var reals: [String: Set<String>] = [:]   // model id → real paths of its manifest and blobs
        var unlistedReals = Set<String>()        // blobs named by something that isn't a listed manifest
        var incomplete: String?                  // why the store couldn't be read in full (blocks Ollama deletes)
        /// Manifest files and manifest blobs: the app reads them on every scan, and on APFS a read can set the access
        /// time, so their dates would only show the app's own scans. Never evidence of use (like HF `refs/`).
        var meta = Set<String>()
    }

    static func scan() -> Scan {
        var s = Scan()
        s.root = realPath(root.path)
        guard isPresent(root: s.root) else { return s }
        s.present = true
        let refs = references(root: s.root)
        s.incomplete = refs.incomplete.first.map { refs.incomplete.count > 1 ? "\($0), and \(refs.incomplete.count - 1) more" : $0 }
        // One row per model: the v1 manifest and the v2 tag of the same model (Ollama 0.40 writes both) are one.
        let v2ByID = Dictionary(refs.v2.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let v1IDs = Set(refs.manifests.map(\.id))
        for entry in refs.manifests.map({ ($0 as Manifest?, v2ByID[$0.id]) }) + refs.v2.filter({ !v1IDs.contains($0.id) }).map({ (nil, $0) }) {
            let (v1, v2) = entry
            let m = (v1 ?? v2)!
            var model = CachedModel(id: m.id, kind: "model", name: m.displayName, folder: URL(fileURLWithPath: m.path))
            model.store = .ollama
            model.ollamaName = m.qualifiedName
            model.ollamaDigest = m.fileDigest
            let digests = (v1?.digests ?? []).union(v2?.digests ?? [])
            model.ollamaBlobs = digests.sorted()
            if let v = v2 { s.meta.formUnion(v.metaDigests.map { realPath(blobPath($0, root: s.root)) }) }
            if v2 != nil || refs.v2IDs.contains(m.id.lowercased()) {
                model.deleteBlocked = "Ollama 0.40 also keeps this model in its newer manifests-v2 layout, which this app doesn't delete from yet; remove it with `ollama rm \(m.displayName)`"
            }
            if let v = v1 { s.meta.insert(v.path) }
            s.models.append(model)
            s.reals[m.id] = Set((v1.map { [$0.path] } ?? []) + digests.map { realPath(blobPath($0, root: s.root)) })
        }
        s.unlistedReals = Set(refs.unlisted.map { realPath(blobPath($0, root: s.root)) })
        return s
    }

    /// An Ollama download leaves `sha256-…-partial` files while it runs. A recent one means a pull may be about
    /// to write a manifest that reuses a blob already on disk, so no blobs are removed until it's done.
    static func downloadInProgress(root: String) -> Bool {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: root + "/blobs") else { return false }
        let recent = Date().addingTimeInterval(-600)
        return names.contains { n in
            n.contains("-partial") && (fileStat(root + "/blobs/" + n)?.mtime ?? .distantPast) > recent
        }
    }

    // MARK: Names

    /// Ollama's name forms, all to `host/namespace/model:tag` (lowercased): `qwen3` → `registry.ollama.ai/library/qwen3:latest`.
    static func qualify(_ name: String) -> String {
        var parts = name.lowercased().components(separatedBy: "/")
        if let last = parts.last, !last.contains(":") { parts[parts.count - 1] = last + ":latest" }
        switch parts.count {
        case 1: return "\(defaultHost)/library/\(parts[0])"
        case 2: return "\(defaultHost)/\(parts[0])/\(parts[1])"
        default: return parts.joined(separator: "/")
        }
    }

    /// Whether a command line or launch agent names this model as a whole word (`ollama run qwen3:8b`, but not
    /// `qwen3:8b-q4`), or one of its blobs (a runner started with `--model …/blobs/sha256-…`).
    static func mentions(_ text: String, _ m: CachedModel) -> Bool {
        // Digests are hex, so a literal byte search matches the same; Foundation's default `contains` compares
        // Unicode-aware and took ~17 s across ~1,200 long command lines.
        let ns = text as NSString
        if m.ollamaBlobs.contains(where: { ns.range(of: $0, options: .literal).location != NSNotFound }) { return true }
        guard let q = m.ollamaName?.lowercased() else { return false }
        let tokens = text.split { !($0.isLetter || $0.isNumber || "._:/-".contains($0)) }
        return tokens.contains { qualify(String($0)) == q }
    }

    // MARK: Local server

    enum Reply { case notRunning, failed(String), ok(Int, Data) }

    /// The local server. `OLLAMA_HOST` may move the port (and pick IPv6 loopback), but requests only ever go to
    /// this Mac. A server bound only to a LAN address isn't reachable here and looks "not running"; its runner
    /// processes and open weights are still caught by the ps / lsof checks.
    static var serverURL: URL {
        var port = 11434, host = "127.0.0.1"
        if let h = ProcessInfo.processInfo.environment["OLLAMA_HOST"], !h.isEmpty,
           let c = URLComponents(string: h.contains("://") ? h : "http://" + h) {
            if let p = c.port, (1...65535).contains(p) { port = p }
            if c.host == "::1" || c.host == "[::1]" { host = "[::1]" }
        }
        return URL(string: "http://\(host):\(port)")!
    }

    /// Replies from the server are small lists; anything bigger is refused rather than buffered.
    private static let maxReplyBytes = 1 << 20

    /// Collects one reply: refuses redirects (requests never leave 127.0.0.1) and stops reading past the size cap.
    private final class Fetch: NSObject, URLSessionDataDelegate {
        var data = Data(), status = 0, tooBig = false, error: Error?
        let done = DispatchSemaphore(value: 0)

        func urlSession(_ s: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
            status = (response as? HTTPURLResponse)?.statusCode ?? 0
            if response.expectedContentLength > Int64(maxReplyBytes) { tooBig = true; completionHandler(.cancel); return }
            completionHandler(.allow)
        }
        func urlSession(_ s: URLSession, dataTask: URLSessionDataTask, didReceive chunk: Data) {
            data.append(chunk)
            if data.count > maxReplyBytes { tooBig = true; dataTask.cancel() }
        }
        func urlSession(_ s: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
            completionHandler(nil)   // the 3xx itself becomes the reply, which no caller accepts
        }
        func urlSession(_ s: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
            self.error = error
            done.signal()
        }
    }

    /// One blocking GET to the local server, bounded in time (whole request, not just idle gaps) and in size.
    /// "Not running" (connection refused) is a normal answer.
    static func call(_ path: String, timeout: TimeInterval) -> Reply {
        let c = URLSessionConfiguration.ephemeral
        c.connectionProxyDictionary = [:]   // loopback only, never through a proxy
        c.waitsForConnectivity = false
        c.timeoutIntervalForRequest = timeout
        c.timeoutIntervalForResource = timeout
        let fetch = Fetch()
        let session = URLSession(configuration: c, delegate: fetch, delegateQueue: nil)
        defer { session.invalidateAndCancel() }   // also releases the delegate
        session.dataTask(with: URLRequest(url: serverURL.appendingPathComponent(path), timeoutInterval: timeout)).resume()
        fetch.done.wait()
        if fetch.tooBig { return .failed("reply larger than \(maxReplyBytes >> 10) KB") }
        if let e = fetch.error as? URLError, e.code == .cannotConnectToHost { return .notRunning }
        if let e = fetch.error { return .failed(e.localizedDescription) }
        return .ok(fetch.status, fetch.data)
    }

    /// `{"models": [{"name": …, "digest": …}]}` from /api/ps or /api/tags, as (qualified name, digest) pairs.
    private static func modelList(_ path: String, timeout: TimeInterval) -> Result<[(name: String, digest: String)], ListError> {
        switch call(path, timeout: timeout) {
        case .notRunning: return .failure(.notRunning)
        case .failed(let why): return .failure(.failed(why))
        case .ok(let code, let data):
            guard code == 200, let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let list = json["models"] as? [[String: Any]] else { return .failure(.failed("unexpected reply from \(path)")) }
            return .success(list.compactMap { e in
                guard let n = (e["model"] as? String) ?? (e["name"] as? String) else { return nil }
                let d = ((e["digest"] as? String) ?? "").lowercased()
                return (qualify(n), d.hasPrefix("sha256:") ? String(d.dropFirst(7)) : d)
            })
        }
    }

    enum ListError: Error { case notRunning, failed(String) }

    /// Models the server has loaded right now (`ollama ps`).
    static func loaded() -> Result<[(name: String, digest: String)], ListError> { modelList("api/ps", timeout: 2) }
}
