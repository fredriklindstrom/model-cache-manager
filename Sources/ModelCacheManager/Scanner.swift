import Foundation
import Darwin

struct CachedModel: Identifiable, Hashable {
    let id: String          // "model/org/name", same as `hf cache ls`
    let kind: String
    let name: String        // "org/name"
    let folder: URL
    var totalBytes: Int64 = 0
    var exclusiveBytes: Int64 = 0            // what deleting it actually frees
    var externalExclusiveFiles: [URL] = []   // shared-store blobs only this model uses
    var lastAccess: Date?
    var downloaded: Date?
    var lastSeenInUse: Date?
    var firstSeen: Date?
    var inUseReason: String?                 // running process / open file / launch agent
    var excluded = false
    var note = ""
    var projectNames: [String] = []
    var projectKept = false        // in a project marked Keep

    /// Running or referenced by a launch agent: never deleted, by hand or automatically.
    var isLocked: Bool { inUseReason != nil }
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
    var uniqueBytes: Int64
    /// False when the in-use checks (ps / lsof) failed; auto-delete must not run on such a scan.
    var usageReliable = true
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
        guard let entries = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else {
            return ScanResult(models: [], uniqueBytes: 0, usageReliable: false)
        }

        var models: [CachedModel] = []
        var realsByRepo: [String: Set<String>] = [:]
        var reposByReal: [String: Set<String>] = [:]
        var metaFiles = Set<String>()

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
                // Not listed, but what it points at still counts as "in use by another repo",
                // so a blob it references can never look exclusive to a real model.
                if let en = fm.enumerator(at: URL(fileURLWithPath: realPath(folderPath)), includingPropertiesForKeys: nil) {
                    var seen = 0
                    for case let u as URL in en {
                        seen += 1
                        if seen > 20_000 { break }   // a link to somewhere huge must not stall the scan
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
            if let en = fm.enumerator(at: folder, includingPropertiesForKeys: nil) {
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

        var unique: Int64 = 0
        var stats: [String: FileStat] = [:]
        for r in reposByReal.keys {
            if let s = fileStat(r) { stats[r] = s; unique += s.size }
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
                if reposByReal[r]?.count == 1 {
                    models[i].exclusiveBytes += s.size
                    if !r.hasPrefix(folderPrefix) { models[i].externalExclusiveFiles.append(URL(fileURLWithPath: r)) }
                }
            }
        }

        let usage = UsageDetector.detect(models: models, reposByReal: reposByReal, root: root.path)
        let now = Date()
        for i in models.indices {
            let id = models[i].id
            if let r = usage.running[id] {
                models[i].inUseReason = r
                models[i].lastSeenInUse = now
            } else if let a = usage.agents[id] {
                models[i].inUseReason = a
            }
        }
        let staging = entries.map(\.lastPathComponent).filter { $0.hasPrefix(".mcc-staging-") }.map { root.path + "/" + $0 }
        return ScanResult(models: Tracker.merge(models, state), uniqueBytes: unique,
                          usageReliable: usage.reliable, leftoverStaging: staging)
    }
}

/// Finds models that something on this Mac is using right now.
/// macOS does not update access times when model files are read, so file dates alone can't tell.
enum UsageDetector {
    struct Result { var running: [String: String] = [:]; var agents: [String: String] = [:]; var reliable = true }

    static func detect(models: [CachedModel], reposByReal: [String: Set<String>], root: String) -> Result {
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
            text.contains(m.name) || text.contains(m.folder.lastPathComponent)
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
            guard path.hasPrefix(root + "/") else { continue }
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
        return r
    }
}

enum Tracker {
    /// Record what this scan saw (first sighting, in-use) into the shared state.
    static func record(_ models: [CachedModel], into s: inout AppState) {
        let now = Date()
        for m in models {
            if s.firstSeen[m.id] == nil { s.firstSeen[m.id] = now }
            if let r = m.inUseReason, !r.hasPrefix("Used by launch agent") { s.lastSeenInUse[m.id] = now }
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
