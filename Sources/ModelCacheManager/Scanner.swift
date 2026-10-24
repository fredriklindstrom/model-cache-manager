import Foundation
import Darwin

enum ModelStore: String { case hf, ollama, folder }

struct CachedModel: Identifiable, Hashable {
    let id: String          // "model/org/name", same as `hf cache ls`; "ollama/library/qwen3:8b" for Ollama;
                            // "folder:<absolute path>" for a model folder, "file:<…>" for a model file in a watched folder
    let kind: String
    let name: String        // "org/name"; "qwen3:8b" for Ollama; "<watched folder>/<entry>" for a model folder
    let folder: URL         // the repo folder; for Ollama, the manifest file; for a model folder, the entry itself
    var store = ModelStore.hf
    var folderRoot: String?                  // watched folder the entry sits directly in
    var folderMembers: [String] = []         // names directly in folderRoot that make up the model (split GGUF parts)
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
    var folderBytes: Int64 = 0               // watched model folders (each model's own files)
    var folderProblems: [String] = []        // watched folders that couldn't be read, and why
    var folderRootsRead: [String] = []
    var folderRootsMissing: [String] = []
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
/// `utf8`: run it in a UTF-8 locale. launchd gives apps and agents no locale, and in the C locale `ps` and `lsof`
/// print every non-ASCII byte of a path as an escape (`Mod\xc3\xa8les`), so a model under such a path would never
/// match (security review 2026-10-24, H1).
@discardableResult
func runCommand(_ path: String, _ args: [String], utf8: Bool = false) -> (out: String, status: Int32) {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: path)
    p.arguments = args
    if utf8 {
        var env = ProcessInfo.processInfo.environment
        env["LC_ALL"] = "en_US.UTF-8"; env["LANG"] = "en_US.UTF-8"
        p.environment = env
    }
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
        let folders = FolderStore.scan(state.settings.modelFolders)
        let listing = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
        // No readable HF cache, no Ollama store and no model folder: nothing to judge, so nothing may be auto-deleted.
        guard listing != nil || ollama.present || !folders.models.isEmpty else {
            // Still report the watched folders, so one that is missing (an unplugged drive) is remembered.
            return ScanResult(models: [], uniqueBytes: 0, folderProblems: folders.problems,
                              folderRootsRead: folders.roots, folderRootsMissing: folders.missing, usageReliable: false)
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
        // A link inside a watched model folder that points into either store keeps that file from looking exclusive
        // (deleting the store's model would break the folder model). Folder files themselves stay out of the
        // stores' accounting: each folder model's sizes come from FolderStore.
        for (target, owners) in folders.linkTargets {
            reposByReal[target, default: []].formUnion(owners.map { "folder-link:folder:" + $0 })
        }

        var unique: Int64 = 0, ollamaUnique: Int64 = 0
        var stats: [String: FileStat] = [:]
        for (r, owners) in reposByReal {
            // Only linked to from a watched folder: not part of either store's total (review L8).
            if owners.allSatisfy({ $0.hasPrefix("folder-link:") }) { continue }
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
                    let who = other.hasPrefix("folder-link:folder:")
                        ? "the link at \(other.dropFirst("folder-link:folder:".count)) (in a watched folder)" : other
                    models[i].deleteBlocked = models[i].deleteBlocked ?? "a file in it is also used by \(who)"
                }
                if reposByReal[r]?.count == 1 {
                    models[i].exclusiveBytes += s.size
                    if !r.hasPrefix(folderPrefix) && r != models[i].folder.path {
                        models[i].externalExclusiveFiles.append(URL(fileURLWithPath: r))
                    }
                }
            }
        }

        // Links under a watched folder that couldn't all be seen: a store model they might point into can't be
        // ruled out, so no store model with shared files may be deleted until they can (review 2, M2).
        if let why = folders.linksIncomplete {
            for i in models.indices where models[i].store != .folder && models[i].deleteBlocked == nil {
                models[i].deleteBlocked = "couldn't see every link under a watched folder (\(why)), so a link into this model can't be ruled out"
            }
        }
        if let why = hfIncomplete {
            for i in models.indices where models[i].store == .ollama || !models[i].externalExclusiveFiles.isEmpty {
                models[i].deleteBlocked = "couldn't read all of the Hugging Face cache (\(why)), so files shared with another model can't be ruled out"
            }
        }

        models += folders.models
        // Any model (either store, or another watched folder) holding a file that a link under a watched folder
        // points at can't be deleted while the link exists: the link's owner would break (review M1).
        for i in models.indices where models[i].deleteBlocked == nil {
            let mine = models[i].store == .folder ? (folders.files[models[i].id] ?? []) : (realsByRepo[models[i].id] ?? [])
            for f in mine {
                guard let owner = folders.linkTargets[f]?.first(where: { $0 != models[i].folder.path
                                                                         && !$0.hasPrefix(models[i].folder.path + "/") }) else { continue }
                models[i].deleteBlocked = "a file in it is also used by the link at \(owner) (in a watched folder)"
                break
            }
        }
        var usageMap = reposByReal
        for (id, files) in folders.files { for f in files { usageMap[f, default: []].insert(id) } }
        let usage = UsageDetector.detect(models: models, reposByReal: usageMap,
                                         roots: [root.path] + (ollama.present ? [ollama.root] : []) + folders.roots)
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
        staging += folders.staging
        return ScanResult(models: Tracker.merge(models, state), uniqueBytes: unique,
                          ollamaBytes: ollamaUnique, ollamaPresent: ollama.present,
                          folderBytes: folders.models.reduce(0) { $0 + $1.exclusiveBytes }, folderProblems: folders.problems,
                          folderRootsRead: folders.roots, folderRootsMissing: folders.missing,
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
            if m.store == .folder { return FolderStore.mentions(text, m) }
            return text.contains(m.name) || text.contains(m.folder.lastPathComponent)
        }

        // Both listings first: lsof also tells each process's working folder, which step 1 needs for relative paths.
        let ps = runCommand("/bin/ps", ["-axww", "-o", "pid=,args="], utf8: true)
        if ps.status != 0 || ps.out.isEmpty { r.reliable = false }
        let lsof = runCommand("/usr/sbin/lsof", ["-n", "-w", "-F", "pcfn"], utf8: true)
        if lsof.status < 0 || lsof.out.isEmpty { r.reliable = false }
        var opens: [(cmd: String, path: String)] = []
        var cwdByPid: [Int32: String] = [:]
        var pid: Int32 = 0, cmd = "a process", fd = ""
        for line in lsof.out.split(separator: "\n") {
            switch line.first {
            case "p": pid = Int32(line.dropFirst()) ?? 0; cmd = "a process"; fd = ""
            case "c": cmd = String(line.dropFirst())
            case "f": fd = String(line.dropFirst())
            case "n":
                let raw = String(line.dropFirst())
                guard let path = decodeLsofName(raw) else {
                    // A name lsof could only print escaped: if it may lie under a root, the models there can't be
                    // ruled out as in use, so they are locked (not counted as use).
                    // Only the models that name could belong to: the part before the first escape is inside the
                    // model, or the escape falls inside the model's own folder name.
                    let cut = raw.firstIndex(where: { $0 == "\\" || $0 == "^" }) ?? raw.endIndex
                    let head = String(raw[..<cut])
                    guard head.count > 1, roots.contains(where: { head.hasPrefix($0 + "/") || $0.hasPrefix(head) }) else { continue }
                    for m in models where r.unknown[m.id] == nil {
                        let f = m.folder.path, parent = (f as NSString).deletingLastPathComponent
                        if head == f || head.hasPrefix(f + "/") || (f.hasPrefix(head) && head.hasPrefix(parent + "/")) {
                            r.unknown[m.id] = "\(unknownPrefix): a file under it has a name lsof could not print"
                        }
                    }
                    continue
                }
                // A working folder counts as open too (a server started inside a snapshot: `--model .`).
                if fd == "cwd" { cwdByPid[pid] = path }
                opens.append((cmd, path))
            default: continue
            }
        }

        // 1. Process arguments, e.g. `mlx_lm.server --model org/name`, or `--model qwen3-8b` run from inside a
        //    watched folder (its working folder is that folder, or the model folder itself).
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
            if let cwd = cwdByPid[pid] {
                for m in models where m.store == .folder && r.running[m.id] == nil {
                    if FolderStore.usedFrom(cwd: cwd, args: s, m) { r.running[m.id] = "In use by \(exe)" }
                }
            }
        }

        // 2. Files held open (including memory-mapped weights).
        for (cmd, path) in opens {
            guard roots.contains(where: { path.hasPrefix($0 + "/") }) else { continue }
            let ids = reposByReal[path] ?? Set(models.filter { path.hasPrefix($0.folder.path + "/") }.map(\.id))
            // A store file opened through a link in a watched model folder: that folder model is in use too.
            let owners = ids.map { $0.hasPrefix("folder-link:") ? String($0.dropFirst("folder-link:".count)) : $0 }
            for id in owners where r.running[id] == nil { r.running[id] = "Open in \(cmd)" }
        }

        // 3. Launch agents and daemons that name a model (catches servers that are stopped right now). Matched on the
        //    plist's own string values (NSDictionary.description escapes non-ASCII characters).
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        for dir in ["\(home)/Library/LaunchAgents", "/Library/LaunchAgents", "/Library/LaunchDaemons"] {
            guard let files = try? FileManager.default.contentsOfDirectory(atPath: dir) else { continue }
            for f in files where f.hasSuffix(".plist") && !f.hasPrefix(Agent.label) {
                guard let dict = NSDictionary(contentsOfFile: "\(dir)/\(f)") else { continue }
                let text = plistStrings(dict).joined(separator: "\n")
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
    static func record(_ res: ScanResult, into s: inout AppState) {
        let now = Date()
        for m in res.models {
            if s.firstSeen[m.id] == nil { s.firstSeen[m.id] = now }
            if m.lockIsUse { s.lastSeenInUse[m.id] = now }
        }
        // A watched folder that was unreadable (an unplugged drive) and is back: its models start a fresh
        // observation period, so weeks away don't make them all due at once (review L6).
        s.missingFolderRoots.formUnion(res.folderRootsMissing)
        for m in res.models where m.store == .folder {
            if let root = m.folderRoot, s.missingFolderRoots.contains(root) { s.firstSeen[m.id] = now }
        }
        s.missingFolderRoots.subtract(res.folderRootsRead)
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

/// Every string value in a property list (keys included), however deeply nested.
func plistStrings(_ any: Any) -> [String] {
    switch any {
    case let s as String: return [s]
    case let d as NSDictionary: return d.flatMap { [($0.key as? String) ?? ""] + plistStrings($0.value) }
    case let a as NSArray: return a.flatMap { plistStrings($0) }
    default: return []
    }
}

/// A name from `lsof -F n`. lsof prints bytes it considers unprintable as `\xNN` (and `\\` for a backslash, `^X`
/// for control characters); the bytes are put back and decoded as UTF-8. nil when that fails or another escape
/// is left, so the caller can treat the name as unreadable rather than guess.
func decodeLsofName(_ s: String) -> String? {
    guard s.contains("\\") || s.contains("^") else { return s }
    var bytes: [UInt8] = []
    var it = Array(s.utf8)[...]
    while let b = it.first {
        it = it.dropFirst()
        if b == UInt8(ascii: "\\") {
            if it.first == UInt8(ascii: "\\") { bytes.append(b); it = it.dropFirst(); continue }
            guard it.first == UInt8(ascii: "x"), it.count >= 3,
                  let v = UInt8(String(decoding: it.dropFirst().prefix(2), as: UTF8.self), radix: 16) else { return nil }
            bytes.append(v); it = it.dropFirst(3)
        } else if b == UInt8(ascii: "^") {
            return nil          // a control character in a file name: don't guess
        } else {
            bytes.append(b)
        }
    }
    return String(bytes: bytes, encoding: .utf8)
}
