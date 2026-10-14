import Foundation
import Darwin

enum ModelStore: String { case hf, ollama }

struct CachedModel: Identifiable, Hashable {
    let id: String          // "model/org/name", same as `hf cache ls`; "ollama/library/qwen3:8b" for Ollama
    let kind: String
    let name: String        // "org/name"; "qwen3:8b" for Ollama
    let folder: URL         // the repo folder; for Ollama, the manifest file
    var store = ModelStore.hf
    var ollamaName: String?                  // "registry.ollama.ai/library/qwen3:8b", what the Ollama API takes
    var ollamaDigest: String?                // sha256 of the manifest, to match what the Ollama server reports
    var ollamaBlobs: [String] = []           // blob digests the manifest references
    var totalBytes: Int64 = 0
    var exclusiveBytes: Int64 = 0            // what deleting it actually frees
    var externalExclusiveFiles: [URL] = []   // shared-store blobs only this model uses
    var lastAccess: Date?
    var downloaded: Date?
    var lastSeenInUse: Date?
    var firstSeen: Date?
    var inUseReason: String?                 // running process / open file / launch agent
    var deleteBlocked: String?               // the scan couldn't see everything that might share this model's files
    var excluded = false
    var note = ""
    var projectNames: [String] = []
    var projectKept = false        // in a project marked Keep

    /// Running or referenced by a launch agent: never deleted, by hand or automatically.
    var isLocked: Bool { inUseReason != nil }
    /// The lock is evidence of use (a process or open file saw it), not a launch agent or an unanswered check.
    var lockIsUse: Bool {
        guard let r = inUseReason else { return false }
        return !r.hasPrefix("Used by launch agent") && !r.hasPrefix(UsageDetector.unknownPrefix)
    }
    /// Never auto-deleted.
    var isProtectedFromAuto: Bool { isLocked || excluded || projectKept }

    /// Latest real evidence of use. This is what the window shows.
    var lastUsed: Date {
        [lastAccess, downloaded, lastSeenInUse].compactMap { $0 }.max() ?? .distantPast
    }
    var lastUsedSource: String {
        let lu = lastUsed
        if lastSeenInUse == lu { return "seen in use" }
        if lastAccess == lu { return "file access" }
        if downloaded == lu { return "downloaded" }
        return "unknown"
    }
    /// What the auto-delete clock runs from: real use, but never earlier than when tracking started
    /// (macOS keeps no read history, so a model gets a full period of observation first).
    var autoClock: Date { max(lastUsed, firstSeen ?? .distantPast) }
    var inGracePeriod: Bool { (firstSeen ?? .distantPast) > lastUsed }
}

struct ScanResult {
    var models: [CachedModel]
    var uniqueBytes: Int64                   // Hugging Face cache
    var ollamaBytes: Int64 = 0
    var ollamaPresent = false
    /// False when the in-use checks (ps / lsof) failed; auto-delete must not run on such a scan.
    var usageReliable = true
    /// Why Ollama's store couldn't be read in full; Ollama models can't be deleted until it can.
    var ollamaIncomplete: String?
    /// Hidden staging folders left by an interrupted delete (their data is still on disk).
    var leftoverStaging: [String] = []
}

struct FileStat { let size: Int64; let atime: Date; let mtime: Date }

func fileStat(_ path: String) -> FileStat? {
    var st = stat()
    guard stat(path, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG else { return nil }
    return FileStat(size: Int64(st.st_size),
                    atime: Date(timeIntervalSince1970: TimeInterval(st.st_atimespec.tv_sec)),
                    mtime: Date(timeIntervalSince1970: TimeInterval(st.st_mtimespec.tv_sec)))
}

/// Canonical path with every symlink resolved (keeps /private, unlike URL.resolvingSymlinksInPath).
func realPath(_ path: String) -> String {
    guard let p = realpath(path, nil) else { return path }
    defer { free(p) }
    return String(cString: p)
}

/// Runs a tool directly (no shell). `status` is -1 if it could not be started.
@discardableResult
func runCommand(_ path: String, _ args: [String]) -> (out: String, status: Int32) {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: path)
    p.arguments = args
    let out = Pipe()
    p.standardOutput = out
    p.standardError = FileHandle.nullDevice
    do { try p.run() } catch { return ("", -1) }
    let data = out.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return (String(decoding: data, as: UTF8.self), p.terminationStatus)
}

enum CacheScanner {
    static var cacheRoot: URL {
        let env = ProcessInfo.processInfo.environment
        if let h = env["HF_HUB_CACHE"] { return URL(fileURLWithPath: h) }
        if let h = env["HF_HOME"] { return URL(fileURLWithPath: h).appendingPathComponent("hub") }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".cache/huggingface/hub")
    }

    static func scan(state: AppState) -> ScanResult {
        let fm = FileManager.default
        let root = URL(fileURLWithPath: realPath(cacheRoot.path))
        let ollama = OllamaStore.scan()
        let listing = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
        // No readable HF cache and no Ollama store: nothing to judge, so nothing may be auto-deleted.
        guard listing != nil || ollama.present else {
            return ScanResult(models: [], uniqueBytes: 0, usageReliable: false)
        }
        let entries = listing ?? []

        var models: [CachedModel] = []
        var realsByRepo: [String: Set<String>] = [:]
        var reposByReal: [String: Set<String>] = [:]
        var metaFiles = Set<String>()
        // Anything the HF walk can't read might hold a link to a shared file, so files outside a model's own
        // folder (and every Ollama layer) can't be judged exclusive until it can.
        var hfIncomplete: String?
        var rootStat = stat()
        if listing == nil && lstat(root.path, &rootStat) == 0 { hfIncomplete = "can't list \(root.path)" }   // missing is fine
        func walker(_ url: URL) -> FileManager.DirectoryEnumerator? {
            fm.enumerator(at: url, includingPropertiesForKeys: nil, options: [], errorHandler: { u, _ in
                if hfIncomplete == nil { hfIncomplete = "can't read \(u.path)" }
                return true
            })
        }

        for e in entries {
            let parts = e.lastPathComponent.components(separatedBy: "--")
            guard parts.count >= 3, ["models", "datasets", "spaces"].contains(parts[0]) else { continue }
            let kind = String(parts[0].dropLast())
            let name = parts.dropFirst().joined(separator: "/")
            let id = "\(kind)/\(name)"
            // Only real folders directly in the cache. A "model folder" that is a symlink could point
            // at the shared blob store or another model, so it is never listed (and never deleted).
            let folderPath = root.path + "/" + e.lastPathComponent
            guard Deleter.isRealDirectory(folderPath) else {
                var st = stat()
                if lstat(folderPath, &st) == 0 && (st.st_mode & S_IFMT) != S_IFLNK { continue }   // a stray file: links nothing
                // Not listed, but what it points at still counts as "in use by another repo",
                // so a blob it references can never look exclusive to a real model.
                if let en = walker(URL(fileURLWithPath: realPath(folderPath))) {
                    var seen = 0
                    for case let u as URL in en {
                        seen += 1
                        if seen > 20_000 { hfIncomplete = hfIncomplete ?? "more than 20,000 files behind \(e.lastPathComponent)"; break }   // a link to somewhere huge must not stall the scan
                        let real = realPath(u.path)
                        if fileStat(real) != nil { reposByReal[real, default: []].insert("symlinked:" + e.lastPathComponent) }
                    }
                }
                continue
            }
            let folder = URL(fileURLWithPath: folderPath)
            models.append(CachedModel(id: id, kind: kind, name: name, folder: folder))

            // Every file in the repo folder, followed through its symlinks to the real data.
            var reals = Set<String>()
            var meta = Set<String>()     // refs/ files: bookkeeping, not model data, so no usage dates
            if let en = walker(folder) {
                for case let u as URL in en {
                    let real = realPath(u.path)
                    guard fileStat(real) != nil else { continue }
                    reals.insert(real)
                    if u.path.hasPrefix(folder.path + "/refs/") { meta.insert(real) }
                }
            }
            realsByRepo[id] = reals
            metaFiles.formUnion(meta)
            for r in reals { reposByReal[r, default: []].insert(id) }
        }

        // Ollama rows join the same accounting, so a file shared across the two stores is never exclusive to either.
        models += ollama.models
        for (id, reals) in ollama.reals {
            realsByRepo[id] = reals
            for r in reals { reposByReal[r, default: []].insert(id) }
        }
        for r in ollama.unlistedReals { reposByReal[r, default: []].insert("ollama-unlisted") }

        var unique: Int64 = 0, ollamaUnique: Int64 = 0
        var stats: [String: FileStat] = [:]
        for (r, owners) in reposByReal {
            guard let s = fileStat(r) else { continue }
            stats[r] = s
            if owners.allSatisfy({ $0.hasPrefix("ollama") }) { ollamaUnique += s.size } else { unique += s.size }
        }

        for i in models.indices {
            let id = models[i].id
            let folderPrefix = models[i].folder.path + "/"
            for r in realsByRepo[id] ?? [] {
                guard let s = stats[r] else { continue }
                models[i].totalBytes += s.size
                if !metaFiles.contains(r) {
                    models[i].lastAccess = max(models[i].lastAccess ?? s.atime, s.atime)
                    models[i].downloaded = max(models[i].downloaded ?? s.mtime, s.mtime)
                }
                // A file inside an HF model's folder that something else also uses (an Ollama layer or another
                // folder linking to it) would break that user if the folder were removed.
                if models[i].store == .hf, r.hasPrefix(folderPrefix), let owners = reposByReal[r], owners.count > 1 {
                    let other = owners.subtracting([id]).sorted().first ?? "another model"
                    models[i].deleteBlocked = models[i].deleteBlocked ?? "a file in it is also used by \(other)"
                }
                if reposByReal[r]?.count == 1 {
                    models[i].exclusiveBytes += s.size
                    if !r.hasPrefix(folderPrefix) && r != models[i].folder.path {
                        models[i].externalExclusiveFiles.append(URL(fileURLWithPath: r))
                    }
                }
            }
        }

        if let why = hfIncomplete {
            for i in models.indices where models[i].store == .ollama || !models[i].externalExclusiveFiles.isEmpty {
                models[i].deleteBlocked = "couldn't read all of the Hugging Face cache (\(why)), so files shared with another model can't be ruled out"
            }
        }

        let usage = UsageDetector.detect(models: models, reposByReal: reposByReal,
                                         roots: [root.path] + (ollama.present ? [ollama.root] : []))
        let now = Date()
        for i in models.indices {
            let id = models[i].id
            if let r = usage.running[id] {
                models[i].inUseReason = r
                models[i].lastSeenInUse = now
            } else if let a = usage.agents[id] ?? usage.unknown[id] {
                models[i].inUseReason = a
            }
        }
        var staging = entries.map(\.lastPathComponent).filter { $0.hasPrefix(".mcc-staging-") }.map { root.path + "/" + $0 }
        if ollama.present, let names = try? fm.contentsOfDirectory(atPath: ollama.root) {
            staging += names.filter { $0.hasPrefix(".mcc-staging-") }.map { ollama.root + "/" + $0 }
        }
        return ScanResult(models: Tracker.merge(models, state), uniqueBytes: unique,
                          ollamaBytes: ollamaUnique, ollamaPresent: ollama.present,
                          usageReliable: usage.reliable, ollamaIncomplete: ollama.incomplete, leftoverStaging: staging)
    }
}

/// Finds models that something on this Mac is using right now.
/// macOS does not update access times when model files are read, so file dates alone can't tell.
enum UsageDetector {
    struct Result {
        var running: [String: String] = [:]
        var agents: [String: String] = [:]
        var unknown: [String: String] = [:]   // can't tell, so locked, but not counted as use
        var reliable = true
    }
    static let unknownPrefix = "Can't tell if in use"

    static func detect(models: [CachedModel], reposByReal: [String: Set<String>], roots: [String]) -> Result {
        var r = Result()

        /// The program a command line runs, skipping interpreters: `python …/mlx_lm.server --model x` → `mlx_lm.server`.
        func programName(_ line: String) -> String {
            let interpreters = ["python", "python3", "bash", "sh", "zsh", "node", "perl", "ruby", "env", "uv", "uvx"]
            for token in line.split(separator: " ") {
                let base = String(token).components(separatedBy: "/").last ?? ""
                if base.hasPrefix("-") { continue }
                let bare = base.lowercased().replacingOccurrences(of: #"[0-9.]+$"#, with: "", options: .regularExpression)
                if interpreters.contains(bare) { continue }
                return base
            }
            return "a process"
        }

        func matches(_ text: String, _ m: CachedModel) -> Bool {
            if m.store == .ollama { return OllamaStore.mentions(text, m) }
            return text.contains(m.name) || text.contains(m.folder.lastPathComponent)
        }

        // 1. Process arguments, e.g. `mlx_lm.server --model org/name`.
        let ps = runCommand("/bin/ps", ["-axww", "-o", "pid=,args="])
        if ps.status != 0 || ps.out.isEmpty { r.reliable = false }
        let me = ProcessInfo.processInfo.processIdentifier
        for line in ps.out.split(separator: "\n") {
            let trimmed = line.drop { $0 == " " }
            guard let space = trimmed.firstIndex(of: " "), let pid = Int32(trimmed[..<space]) else { continue }
            if pid == me { continue }
            let s = String(trimmed[space...].drop { $0 == " " })
            let exe = programName(s)
            for m in models where r.running[m.id] == nil && matches(s, m) {
                r.running[m.id] = "In use by \(exe)"
            }
        }

        // 2. Files held open (including memory-mapped weights).
        var cmd = "a process"
        let lsof = runCommand("/usr/sbin/lsof", ["-n", "-w", "-F", "cn"])
        if lsof.status < 0 || lsof.out.isEmpty { r.reliable = false }
        for line in lsof.out.split(separator: "\n") {
            if line.hasPrefix("c") { cmd = String(line.dropFirst()); continue }
            guard line.hasPrefix("n") else { continue }
            let path = String(line.dropFirst())
            guard roots.contains(where: { path.hasPrefix($0 + "/") }) else { continue }
            let ids = reposByReal[path] ?? Set(models.filter { path.hasPrefix($0.folder.path + "/") }.map(\.id))
            for id in ids where r.running[id] == nil { r.running[id] = "Open in \(cmd)" }
        }

        // 3. Launch agents and daemons that name a model (catches servers that are stopped right now).
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        for dir in ["\(home)/Library/LaunchAgents", "/Library/LaunchAgents", "/Library/LaunchDaemons"] {
            guard let files = try? FileManager.default.contentsOfDirectory(atPath: dir) else { continue }
            for f in files where f.hasSuffix(".plist") && !f.hasPrefix(Agent.label) {
                guard let dict = NSDictionary(contentsOfFile: "\(dir)/\(f)") else { continue }
                let text = dict.description
                for m in models where r.agents[m.id] == nil && matches(text, m) {
                    r.agents[m.id] = "Used by launch agent \(f.replacingOccurrences(of: ".plist", with: ""))"
                }
            }
        }

        // 4. Models a running Ollama server has loaded (`ollama ps`). A stopped server is fine:
        //    its runner processes and the weights they hold open are already covered above.
        let ollamaModels = models.filter { $0.store == .ollama }
        if !ollamaModels.isEmpty {
            switch OllamaStore.loaded() {
            case .failure(.notRunning): break
            // A bad reply locks the Ollama models only: Hugging Face deletes don't depend on the Ollama server.
            case .failure(.failed(let why)):
                for m in ollamaModels where r.running[m.id] == nil {
                    r.unknown[m.id] = "\(unknownPrefix): the Ollama server's model list failed (\(why))"
                }
            case .success(let list):
                for m in ollamaModels where r.running[m.id] == nil {
                    if list.contains(where: { $0.name == m.ollamaName?.lowercased() || $0.digest == m.ollamaDigest }) {
                        r.running[m.id] = "Loaded in Ollama"
                    }
                }
            }
        }
        return r
    }
}

enum Tracker {
    /// Record what this scan saw (first sighting, in-use) into the shared state.
    static func record(_ models: [CachedModel], into s: inout AppState) {
        let now = Date()
        for m in models {
            if s.firstSeen[m.id] == nil { s.firstSeen[m.id] = now }
            if m.lockIsUse { s.lastSeenInUse[m.id] = now }
        }
    }

    static func merge(_ models: [CachedModel], _ s: AppState) -> [CachedModel] {
        models.map { m in
            var m = m
            m.firstSeen = s.firstSeen[m.id]
            if let d = s.lastSeenInUse[m.id] { m.lastSeenInUse = max(m.lastSeenInUse ?? d, d) }
            m.excluded = s.excluded.contains(m.id)
            m.note = s.notes[m.id] ?? ""
            let mine = s.projects.filter { $0.models.contains(m.id) }
            m.projectNames = mine.map(\.name).sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
            m.projectKept = mine.contains(where: \.keep)
            return m
        }
    }
}
