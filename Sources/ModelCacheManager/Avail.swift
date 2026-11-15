import Foundation
import Darwin
import CryptoKit

/// `llmavail`: which models are on this Mac, and which of them are complete and ready to run.
///
/// Strictly read-only. Nothing here deletes, downloads, moves or writes anything, and nothing touches the network
/// (the optional Hugging Face access check lives in `HFAccess` and runs only with `--access`).
///
/// Sizes are what the files take on disk with every link followed to the real data: the Hugging Face cache on this
/// kind of setup keeps weights in a shared `blobs/` store and model folders hold only links into it, so `du` on a
/// model folder shows a few MB for a 30 GB model.
enum Avail {
    struct Row {
        var source: String            // hf, ollama, lmstudio, folder
        var id: String                // the app's model id: what Keep, notes and projects are keyed by
        var name: String              // repo id, Ollama name:tag, LM Studio publisher/model, or folder entry
        var revision: String?         // HF commit, Ollama manifest digest
        var format: String            // safetensors, mlx, gguf, ollama, pytorch, onnx, none
        var quant: String?
        var bytes: Int64
        var problems: [String] = []   // why it isn't complete
        var unchecked: [String] = []  // checks skipped because reading the file would change its access time
        var unverified = false        // one of those was needed to tell (an index or manifest): neither complete nor not
        var path: String
        var lastUsed: Date?
        var lastUsedSource = "unknown"
        var inUse: String?
        var keep = false
        var projectKept = false
        var projects: [String] = []
        var note = ""
        var snapshots = 1             // HF: snapshots in the repo folder (the row describes one)
        var variants: [String] = []   // Ollama manifest lists: each runner's variant and whether it is whole
        var gated: String?            // set by --access
        var access: String?           // set by --access
        var hashRefs: [AvailVerify.Ref] = []   // files --verify can hash, each with the hash it was downloaded under
        var unreferenced: [String] = []        // files with no recorded hash to check against
        var verify: AvailVerify.Summary?       // set by --verify
        var complete: Bool { problems.isEmpty && !unverified }
        var status: String { !problems.isEmpty ? "incomplete" : unverified ? "unverified" : "complete" }
    }

    struct Collection {
        var rows: [Row] = []
        var usageReliable = true
        var notes: [String] = []      // store-level remarks (a watched folder that couldn't be read, …)
        var hfRoot = ""
        var ollamaRoot = ""
        var lmstudioRoots: [String] = []
    }

    struct Options {
        var ollamaRoot = OllamaStore.root.path
        var lmstudioRoots: [String] = Avail.defaultLMStudioRoots
        var extraFolders: [String] = []   // --path, added to the app's watched folders for this run only
        var usage = true                  // ps / lsof checks for "in use"
    }

    static var defaultLMStudioRoots: [String] {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if let m = ProcessInfo.processInfo.environment["LMSTUDIO_MODELS"], !m.isEmpty { return [m] }
        return [home + "/.lmstudio/models", home + "/.cache/lm-studio/models"]
    }

    // MARK: Collect

    static func collect(_ o: Options, state: AppState) -> Collection {
        var c = Collection()
        var st = state
        st.settings.modelFolders += o.extraFolders.filter { !st.settings.modelFolders.contains($0) }   // in memory only
        let res = CacheScanner.scan(state: st, includeOllama: false, askOllamaServer: false, checkUsage: o.usage)
        c.usageReliable = res.usageReliable
        c.hfRoot = realPath(CacheScanner.cacheRoot.path)
        for p in res.folderProblems { c.notes.append("watched folder not read: \(p)") }

        for m in res.models {
            switch m.store {
            case .hf:
                guard m.kind == "model" else { continue }   // datasets and spaces aren't models to run
                c.rows.append(hfRow(m))
            case .folder:
                c.rows.append(folderRow(m))
            case .ollama:
                continue   // listed from the store below, which also reads the newer manifests-v2 layout
            }
        }

        // Ollama and LM Studio are read here, then their files go through the same in-use checks as the rest.
        c.ollamaRoot = realPath(o.ollamaRoot)
        var extras: [(Row, CachedModel, Set<String>)] = ollamaModels(root: c.ollamaRoot)
        for root in o.lmstudioRoots {
            let r = realPath(root)
            guard Deleter.isRealDirectory(r) else { continue }
            c.lmstudioRoots.append(r)
            extras += lmstudioModels(root: r)
        }
        if !extras.isEmpty {
            var reposByReal: [String: Set<String>] = [:]
            for (_, m, files) in extras { for f in files { reposByReal[f, default: []].insert(m.id) } }
            let merged = Tracker.merge(extras.map(\.1), state)
            var usage = UsageDetector.Result()
            if o.usage, !reposByReal.isEmpty {
                usage = UsageDetector.detect(models: merged, reposByReal: reposByReal,
                                             roots: [c.ollamaRoot] + c.lmstudioRoots, askOllamaServer: false)
                c.usageReliable = c.usageReliable && usage.reliable
            }
            for (i, e) in extras.enumerated() {
                var m = merged[i]
                if let r = usage.running[m.id] { m.inUseReason = r; m.lastSeenInUse = Date() }
                else if let a = usage.agents[m.id] ?? usage.unknown[m.id] { m.inUseReason = a }
                var row = e.0
                apply(m, to: &row)
                c.rows.append(row)
            }
        }
        let order = ["hf": 0, "lmstudio": 1, "ollama": 2, "folder": 3]
        c.rows.sort {
            let sa = order[$0.source] ?? 9, sb = order[$1.source] ?? 9
            return sa != sb ? sa < sb : $0.name.lowercased() < $1.name.lowercased()
        }
        return c
    }

    /// Last used, in use, Keep, note: the app's own bookkeeping for this model id.
    static func apply(_ m: CachedModel, to row: inout Row) {
        row.lastUsed = m.lastUsed == .distantPast ? nil : m.lastUsed
        row.lastUsedSource = m.lastUsedSource
        row.inUse = m.inUseReason
        row.keep = m.excluded
        row.projectKept = m.projectKept
        row.projects = m.projectNames
        row.note = m.note
    }

    // MARK: Hugging Face cache

    static func hfRow(_ m: CachedModel) -> Row {
        let a = analyzeHFRepo(folder: m.folder.path, name: m.name)
        var row = Row(source: "hf", id: m.id, name: m.name, revision: a.revision, format: a.report.format,
                      quant: a.report.quant, bytes: m.totalBytes, problems: a.report.problems,
                      path: a.snapshotPath ?? m.folder.path)
        row.snapshots = a.snapshots
        row.unchecked = a.report.unchecked; row.unverified = a.report.unverified
        for e in a.report.entries {
            guard let real = e.real, let size = e.size else { continue }
            if let ref = AvailVerify.hfRef(rel: e.rel, path: e.path, real: real, size: size) { row.hashRefs.append(ref) }
            else { row.unreferenced.append(e.rel) }
        }
        apply(m, to: &row)
        return row
    }

    struct HFRepo { var revision: String?; var snapshotPath: String?; var snapshots = 0; var report: Report }

    /// One cached repo: the snapshot `refs/main` names (or the newest one), checked for every weight file.
    static func analyzeHFRepo(folder: String, name: String) -> HFRepo {
        var problems: [String] = []
        var rev: String?
        if let d = readRegular(folder + "/refs/main", max: 4096, guardAtime: false) {   // refs/ dates aren't evidence of use
            let s = String(decoding: d, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            if isPlainName(s) { rev = s }
        }
        let snapDir = folder + "/snapshots"
        let snaps = ((try? FileManager.default.contentsOfDirectory(atPath: snapDir)) ?? [])
            .filter { isPlainName($0) && !$0.hasPrefix(".") && Deleter.isRealDirectory(snapDir + "/" + $0) }
        var chosen: String?
        if let r = rev, snaps.contains(r) {
            chosen = r
        } else {
            if let r = rev { problems.append("refs/main points at \(short(r)), which isn't in snapshots/") }
            chosen = snaps.max { (mtime(snapDir + "/" + $0) ?? .distantPast) < (mtime(snapDir + "/" + $1) ?? .distantPast) }
        }
        guard let snap = chosen else {
            return HFRepo(revision: rev, snapshotPath: nil, snapshots: 0,
                          report: Report(format: "none", quant: nil, problems: ["no snapshot: only refs are cached, no files"], bytes: 0))
        }
        var report = assess(dir: snapDir + "/" + snap, name: name)
        // huggingface_hub writes `<blob>.incomplete` while a file downloads and renames it when it's done.
        let unfinished = ((try? FileManager.default.contentsOfDirectory(atPath: folder + "/blobs")) ?? [])
            .filter { $0.hasSuffix(".incomplete") }
        if !unfinished.isEmpty {
            // Can't tell which revision it belongs to: the chosen snapshot's own files are checked above, so this
            // only stops a clean "complete" (review L4).
            report.unchecked.append("\(unfinished.count) unfinished download\(unfinished.count == 1 ? "" : "s") in this repo's blobs/ (.incomplete), maybe for another revision")
            report.unverified = report.problems.isEmpty
        }
        report.problems = problems + report.problems
        return HFRepo(revision: snap, snapshotPath: snapDir + "/" + snap, snapshots: snaps.count, report: report)
    }

    // MARK: Watched folders (the app's own model folders, plus --path)

    static func folderRow(_ m: CachedModel) -> Row {
        let report: Report
        if m.kind == "folder" {
            report = assess(dir: m.folder.path, name: m.name)
        } else {
            let root = m.folderRoot ?? m.folder.deletingLastPathComponent().path
            let entries = m.folderMembers.map { n in entry(rel: n, path: root + "/" + n) }
            report = assess(entries: entries, base: root, name: m.name, configDir: nil)
        }
        var row = Row(source: "folder", id: m.id, name: m.name, revision: nil, format: report.format,
                      quant: report.quant, bytes: m.totalBytes, problems: report.problems, path: m.folder.path)
        row.unchecked = report.unchecked; row.unverified = report.unverified
        row.unreferenced = report.entries.filter { $0.size != nil }.map(\.rel)   // a plain folder records no hashes
        apply(m, to: &row)
        return row
    }

    // MARK: LM Studio (`<root>/<publisher>/<model>/`)

    static func lmstudioModels(root: String) -> [(Row, CachedModel, Set<String>)] {
        var out: [(Row, CachedModel, Set<String>)] = []
        for pub in sortedNames(root) where !pub.hasPrefix(".") && Deleter.isRealDirectory(root + "/" + pub) {
            for model in sortedNames(root + "/" + pub) where !model.hasPrefix(".") {
                let dir = root + "/" + pub + "/" + model
                guard Deleter.isRealDirectory(dir) else { continue }
                let listing = listTree(dir)
                let report = assess(entries: listing.entries, base: dir, name: pub + "/" + model, configDir: dir,
                                    walkProblems: listing.problems)
                var files = Set<String>()
                var cm = CachedModel(id: "lmstudio:" + dir, kind: "folder", name: pub + "/" + model, folder: URL(fileURLWithPath: dir))
                cm.store = .folder           // matched in process lists by "<publisher>/<model>" and by path
                cm.folderRoot = root + "/" + pub
                cm.folderMembers = [model]
                var seenReal = Set<String>()
                for e in listing.entries {
                    guard let real = e.real, let s = e.size, seenReal.insert(real).inserted else { continue }
                    files.insert(real)
                    cm.totalBytes += s
                    if let t = e.mtime { cm.downloaded = max(cm.downloaded ?? t, t) }
                    if let t = e.atime { cm.lastAccess = max(cm.lastAccess ?? t, t) }
                }
                var row = Row(source: "lmstudio", id: cm.id, name: cm.name, revision: nil, format: report.format,
                              quant: report.quant, bytes: cm.totalBytes, problems: report.problems, path: dir)
                row.unchecked = report.unchecked; row.unverified = report.unverified
                row.unreferenced = report.entries.filter { $0.size != nil }.map(\.rel)   // LM Studio records no hashes
                out.append((row, cm, files))
            }
        }
        return out
    }

    // MARK: Ollama (`manifests/` and the newer `manifests-v2/`)

    private static let hexDigest = #"^[0-9a-f]{64}$"#
    private static let layerDigest = #"^sha256:[0-9a-fA-F]{64}$"#

    /// Every `<host>/<namespace>/<model>/<tag>` manifest, as a row. A manifest may be a file or (manifests-v2)
    /// a link into `blobs/`; a link that leads anywhere else is reported, never read.
    static func ollamaModels(root: String) -> [(Row, CachedModel, Set<String>)] {
        guard root != "/", Deleter.isRealDirectory(root) else { return [] }
        var out: [(Row, CachedModel, Set<String>)] = []
        var at: [String: Int] = [:]   // id -> index in out
        for layout in ["manifests-v2", "manifests"] {
            let base = root + "/" + layout
            guard Deleter.isRealDirectory(base) else { continue }
            for host in sortedNames(base) where Deleter.isRealDirectory(base + "/" + host) {
                for ns in sortedNames(base + "/" + host) where Deleter.isRealDirectory(base + "/\(host)/\(ns)") {
                    for model in sortedNames(base + "/\(host)/\(ns)") where Deleter.isRealDirectory(base + "/\(host)/\(ns)/\(model)") {
                        for tag in sortedNames(base + "/\(host)/\(ns)/\(model)") {
                            let parts = [host, ns, model, tag]
                            guard OllamaStore.isValidManifestPath(parts) else { continue }
                            guard let r = ollamaManifest(root: root, path: base + "/" + parts.joined(separator: "/"), parts: parts) else { continue }
                            // The same model in both layouts is one row: the first whole one (manifests-v2 first).
                            // If the two copies disagree, which one Ollama uses isn't known: unverified (review L5).
                            if let i = at[r.1.id] {
                                if out[i].0.complete != r.0.complete {
                                    let broken = out[i].0.complete ? r : out[i]
                                    if !out[i].0.complete { out[i] = r }
                                    out[i].0.unverified = true
                                    out[i].0.unchecked.append("its \(broken.0.path.contains("/manifests-v2/") ? "manifests-v2" : "manifests") copy is incomplete (\(broken.0.problems.first ?? "unverified")), and which copy Ollama uses isn't known")
                                }
                            } else {
                                at[r.1.id] = out.count
                                out.append(r)
                            }
                        }
                    }
                }
            }
        }
        return out
    }

    static func ollamaManifest(root: String, path: String, parts: [String]) -> (Row, CachedModel, Set<String>)? {
        // manifests-v2 says ollama.com where manifests/ says registry.ollama.ai: the same model, so the same id
        // (the app's id for it, so Keep and notes carry over) and the same name a process would use.
        let host = OllamaStore.normalHost(parts[0])
        let (ns, model, tag) = (parts[1], parts[2], parts[3])
        let display = host == OllamaStore.defaultHost ? (ns == "library" ? "\(model):\(tag)" : "\(ns)/\(model):\(tag)")
                                                      : "\(host)/\(ns)/\(model):\(tag)"
        let id = host == OllamaStore.defaultHost ? "ollama/\(ns)/\(model):\(tag)" : "ollama/\(host)/\(ns)/\(model):\(tag)"
        var cm = CachedModel(id: id, kind: "model", name: display, folder: URL(fileURLWithPath: path))
        cm.store = .ollama
        cm.ollamaName = "\(host)/\(ns)/\(model):\(tag)"
        var row = Row(source: "ollama", id: id, name: display, revision: nil, format: "ollama", quant: nil,
                      bytes: 0, path: path)

        var lst = stat()
        guard lstat(path, &lst) == 0 else { return nil }
        var manifestRefs: [AvailVerify.Ref] = []   // v2 manifest blobs, named by their own hash too
        let blobsDir = root + "/blobs/"
        var manifestFile = path
        switch lst.st_mode & S_IFMT {
        case S_IFREG: break
        case S_IFLNK:
            let target = realPath(path)
            let name = ((try? FileManager.default.destinationOfSymbolicLink(atPath: path)) as NSString?)?.lastPathComponent ?? ""
            if name.hasPrefix("sha256-"), String(name.dropFirst(7)).range(of: hexDigest, options: .regularExpression) != nil {
                row.revision = String(name.dropFirst(7))
            }
            var st = stat()
            if stat(path, &st) != 0 {
                row.problems.append("manifest missing: the link points at a blob that isn't on disk")
                return (row, cm, [])
            }
            guard target.hasPrefix(blobsDir) else {
                row.problems.append("manifest link leads outside the store's blobs/, not read")
                return (row, cm, [])
            }
            manifestFile = target
            if let hex = row.revision { manifestRefs.append(blobRef(target, hex)) }
        default:
            return nil
        }
        // Manifests are bookkeeping: the app never counts their dates as use (it reads them on every scan itself),
        // so reading one here changes nothing that matters. Layer files are the evidence, and are never read.
        let read = readFile(manifestFile, max: 4 << 20, guardAtime: false)
        guard case .ok(let data) = read, let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            row.problems.append("manifest can't be read or parsed")
            return (row, cm, [])
        }
        row.revision = row.revision ?? sha256Hex(data)
        var files = Set<String>([realPath(path)])

        // A manifest list (Ollama 0.40+): one manifest per runner (MLX safetensors, llama.cpp GGUF, …), each a blob.
        // Ready to run when at least one of them is whole.
        let checks: [LayerCheck]
        if let list = json["manifests"] as? [[String: Any]] {
            var cs: [LayerCheck] = []
            for e in list {
                let label = [e["runner"] as? String, e["format"] as? String].compactMap { $0 }.joined(separator: "/")
                guard let d = e["digest"] as? String, d.range(of: layerDigest, options: .regularExpression) != nil else {
                    cs.append(LayerCheck(label: label, problems: ["a variant has a malformed digest"])); continue
                }
                let blob = blobsDir + "sha256-" + String(d.dropFirst(7)).lowercased()
                let sub = readFile(blob, max: 4 << 20, guardAtime: false)   // a manifest blob: bookkeeping, as above
                guard case .ok(let sd) = sub,
                      let sj = try? JSONSerialization.jsonObject(with: sd) as? [String: Any] else {
                    cs.append(LayerCheck(label: label, problems: ["\(label.isEmpty ? "variant" : label): manifest missing"])); continue
                }
                files.insert(realPath(blob))
                manifestRefs.append(blobRef(blob, String(d.dropFirst(7)).lowercased()))
                var c = checkLayers(sj, blobsDir: blobsDir)
                c.label = label
                c.problems = c.problems.map { label.isEmpty ? $0 : "\(label): \($0)" }
                cs.append(c)
            }
            checks = cs
        } else if json["layers"] is [[String: Any]] {
            checks = [checkLayers(json, blobsDir: blobsDir)]
        } else {
            row.problems.append("manifest can't be read or parsed")
            return (row, cm, files)
        }
        let whole = checks.filter { $0.problems.isEmpty && $0.present && !$0.unverified }
        if checks.count > 1 || !(checks.first?.label.isEmpty ?? true) {
            row.variants = checks.map { c in
                (c.label.isEmpty ? "variant" : c.label) + ": "
                    + (c.unverified ? "unverified" : c.problems.isEmpty && c.present ? "complete" : "incomplete")
            }
        }
        if whole.isEmpty {
            if checks.contains(where: \.unverified) {
                // A variant that couldn't be read might be the whole one: can't tell either way.
                row.unverified = true
                row.unchecked.append("a variant's manifest not read (\(touchReason))")
            } else {
                row.problems = checks.flatMap(\.problems)
                if row.problems.isEmpty { row.problems = ["no variant has any layers"] }
            }
        }
        // Size, quant and files: of the variants that are whole (else of everything found).
        let counted = whole.isEmpty ? checks : whole
        var seenBlobs = Set<String>()
        for c in counted {
            for (real, size) in c.blobs where seenBlobs.insert(real).inserted { row.bytes += size }
            files.formUnion(c.blobs.map(\.0))
            cm.ollamaBlobs += c.digests
            if let t = c.mtime { cm.downloaded = max(cm.downloaded ?? t, t) }
            if let t = c.atime { cm.lastAccess = max(cm.lastAccess ?? t, t) }
        }
        let quants = counted.compactMap { c -> String? in
            guard let q = c.quant else { return nil }
            return counted.count > 1 && !c.label.isEmpty ? "\(q) (\(c.label))" : q
        }
        row.quant = quants.isEmpty ? quantFromName(tag) : quants.joined(separator: ", ")
        cm.ollamaBlobs = Array(Set(cm.ollamaBlobs)).sorted()
        cm.totalBytes = row.bytes
        var seenRefs = Set<String>()
        row.hashRefs = (manifestRefs + counted.flatMap(\.refs)).filter { seenRefs.insert($0.real).inserted }
        return (row, cm, files)
    }

    struct LayerCheck {
        var label = ""
        var problems: [String] = []
        var unverified = false              // its manifest wasn't read (it would change the access time)
        var blobs: [(String, Int64)] = []   // real path, size
        var digests: [String] = []
        var refs: [AvailVerify.Ref] = []    // every blob is named by the SHA-256 of its content
        var quant: String?
        var mtime: Date?, atime: Date?
        var present: Bool { !blobs.isEmpty }
    }

    /// One image manifest: every layer (and the config) must be in blobs/ at its full size.
    static func checkLayers(_ json: [String: Any], blobsDir: String) -> LayerCheck {
        var c = LayerCheck()
        var layers = (json["layers"] as? [[String: Any]]) ?? []
        let config = json["config"] as? [String: Any]
        if let cf = config { layers.append(cf) }
        if layers.isEmpty { c.problems.append("manifest lists no layers") }
        for l in layers {
            guard let d = l["digest"] as? String, d.range(of: layerDigest, options: .regularExpression) != nil else {
                c.problems.append("a layer has a malformed digest"); continue
            }
            let hex = String(d.dropFirst(7)).lowercased()
            c.digests.append(hex)
            let blob = blobsDir + "sha256-" + hex
            var st = stat()
            guard stat(blob, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG else {
                c.problems.append("layer \(short(hex)) missing"); continue
            }
            let have = Int64(st.st_size)
            if let w = (l["size"] as? NSNumber)?.int64Value, have < w {
                c.problems.append("layer \(short(hex)) is short (\(have) of \(w) bytes)")
            }
            c.blobs.append((realPath(blob), have))
            c.refs.append(AvailVerify.Ref(rel: "blobs/sha256-" + hex, real: realPath(blob), size: have, algo: .sha256, hex: hex))
            let m = Date(timeIntervalSince1970: TimeInterval(st.st_mtimespec.tv_sec))
            let a = Date(timeIntervalSince1970: TimeInterval(st.st_atimespec.tv_sec))
            c.mtime = max(c.mtime ?? m, m)
            c.atime = max(c.atime ?? a, a)
        }
        // The config layer is a small JSON file: its `file_type` is the quantisation (Q4_K_M, nvfp4, …).
        if let cf = config, let d = cf["digest"] as? String, d.range(of: layerDigest, options: .regularExpression) != nil,
           let cd = readRegular(blobsDir + "sha256-" + String(d.dropFirst(7)).lowercased(), max: 1 << 20),
           let cj = try? JSONSerialization.jsonObject(with: cd) as? [String: Any],
           let ft = cj["file_type"] as? String, !ft.isEmpty {
            c.quant = ft
        }
        return c
    }

    private static func blobRef(_ path: String, _ hex: String) -> AvailVerify.Ref {
        var st = stat()
        let size = stat(path, &st) == 0 ? Int64(st.st_size) : 0
        return AvailVerify.Ref(rel: "blobs/sha256-" + hex, real: realPath(path), size: size, algo: .sha256, hex: hex)
    }

    static func sha256Hex(_ d: Data) -> String { SHA256.hash(data: d).map { String(format: "%02x", $0) }.joined() }

    // MARK: Checking a model's files

    struct Entry {
        let rel: String        // path relative to the model folder
        let path: String
        var real: String?      // regular file the entry resolves to (links followed)
        var size: Int64?
        var mtime: Date?, atime: Date?
        var broken = false     // a link to nothing
    }

    struct Report {
        var format: String; var quant: String?; var problems: [String]; var bytes: Int64
        var unchecked: [String] = []; var unverified = false
        var entries: [Entry] = []
    }

    static func entry(rel: String, path: String) -> Entry {
        var e = Entry(rel: rel, path: path)
        var st = stat()
        if stat(path, &st) == 0 {
            if (st.st_mode & S_IFMT) == S_IFREG {
                e.real = realPath(path)
                e.size = Int64(st.st_size)
                e.mtime = Date(timeIntervalSince1970: TimeInterval(st.st_mtimespec.tv_sec))
                e.atime = Date(timeIntervalSince1970: TimeInterval(st.st_atimespec.tv_sec))
            }
        } else {
            var l = stat()
            if lstat(path, &l) == 0 && (l.st_mode & S_IFMT) == S_IFLNK { e.broken = true }
        }
        return e
    }

    /// Files under a model folder (six levels deep at most; deeper files are not seen). Folders are walked only if they are real folders,
    /// never through a link; file links are followed to stat their target, and that's all.
    static func listTree(_ dir: String, maxDepth: Int = 6, maxEntries: Int = 50_000) -> (entries: [Entry], problems: [String]) {
        var out: [Entry] = [], problems: [String] = []
        func walk(_ rel: String, depth: Int) {
            let abs = rel.isEmpty ? dir : dir + "/" + rel
            guard let names = try? FileManager.default.contentsOfDirectory(atPath: abs) else {
                problems.append("can't read \(rel.isEmpty ? "the folder" : rel)"); return
            }
            for n in names.sorted() {
                guard out.count < maxEntries else { problems.append("more than \(maxEntries) files, not all checked"); return }
                let r = rel.isEmpty ? n : rel + "/" + n, p = abs + "/" + n
                var l = stat()
                guard lstat(p, &l) == 0 else { continue }
                if (l.st_mode & S_IFMT) == S_IFDIR {
                    if depth < maxDepth { walk(r, depth: depth + 1) }
                    continue
                }
                let e = entry(rel: r, path: p)
                if e.real != nil || e.broken { out.append(e) }
            }
        }
        walk("", depth: 1)
        return (out, problems)
    }

    static func assess(dir: String, name: String) -> Report {
        let t = listTree(dir)
        return assess(entries: t.entries, base: dir, name: name, configDir: dir, walkProblems: t.problems)
    }

    static let weightExtensions: Set<String> = ["safetensors", "gguf", "bin", "pt", "pth", "ckpt", "npz", "onnx"]
    private static let shardPattern = try! NSRegularExpression(pattern: #"^(.*)-(\d{5})-of-(\d{5})\.(safetensors|gguf|bin)$"#,
                                                               options: .caseInsensitive)

    /// Format, quantisation and everything that stops the model being complete.
    static func assess(entries: [Entry], base: String, name: String, configDir: String?, walkProblems: [String] = []) -> Report {
        var problems = walkProblems
        let byRel = Dictionary(entries.map { ($0.rel, $0) }, uniquingKeysWith: { a, _ in a })
        func ext(_ rel: String) -> String { (rel as NSString).pathExtension.lowercased() }
        let weights = entries.filter { weightExtensions.contains(ext($0.rel)) }

        for e in entries where e.broken { problems.append("missing: \(e.rel) (link to a file that isn't on disk)") }
        let unfinished = entries.filter { $0.rel.hasSuffix(".incomplete") }
        if !unfinished.isEmpty { problems.append("\(unfinished.count) unfinished download\(unfinished.count == 1 ? "" : "s") (.incomplete)") }

        // 1. Every shard an index (`model.safetensors.index.json`, `pytorch_model.bin.index.json`, diffusers
        //    sub-folders' own) names must be here.
        var unchecked: [String] = [], unverified = false
        var indexedDirs = Set<String>()   // "<dir>|<ext>" that an index covers
        for e in entries where e.rel.hasSuffix(".safetensors.index.json") || e.rel.hasSuffix(".bin.index.json") {
            let dirRel = (e.rel as NSString).deletingLastPathComponent
            let wext = e.rel.hasSuffix(".safetensors.index.json") ? "safetensors" : "bin"
            guard let real = e.real else { continue }
            let read = readFile(real, max: 32 << 20)
            if case .wouldTouch = read {
                unchecked.append("\(e.rel) not read (\(touchReason))")
                unverified = true   // the numbered-shard check below still runs for this folder
                continue
            }
            indexedDirs.insert(dirRel + "|" + wext)
            guard case .ok(let d) = read,
                  let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
                  let map = j["weight_map"] as? [String: Any] else {
                problems.append("\(e.rel) can't be read"); continue
            }
            for file in Set(map.values.compactMap { $0 as? String }).sorted() {
                guard isSafeRelative(file) else { problems.append("\(e.rel) names an unsafe path, not followed"); continue }
                let rel = dirRel.isEmpty ? file : dirRel + "/" + file
                if byRel[rel]?.size == nil && byRel[rel]?.broken != true {   // broken links are already reported
                    problems.append("missing shard: \(rel)")
                }
            }
        }

        // 1b. Diffusers: every component `model_index.json` names (`"unet": ["diffusers", "UNet2DConditionModel"]`)
        //     needs its folder with files in it. A component set to null is optional.
        if let mi = byRel["model_index.json"], let real = mi.real {
            switch readFile(real, max: 1 << 20) {
            case .ok(let d):
                if let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any] {
                    for (k, v) in j.sorted(by: { $0.key < $1.key }) where !k.hasPrefix("_") {
                        guard let pair = v as? [Any], pair.count == 2, !(pair[0] is NSNull), !(pair[1] is NSNull),
                              isSafeRelative(k), !k.contains("/") else { continue }
                        let files = entries.filter { $0.rel.hasPrefix(k + "/") && $0.size != nil }
                        if files.isEmpty {
                            problems.append("missing component: \(k)/ (named in model_index.json)")
                        } else if files.contains(where: { $0.rel.hasSuffix("/config.json") }),
                                  !files.contains(where: { weightExtensions.contains(ext($0.rel)) }) {
                            // A model component (it has a config.json) needs weights; tokenizers and schedulers don't.
                            problems.append("missing weights in component \(k)/")
                        }
                    }
                }
            case .wouldTouch:
                unchecked.append("model_index.json not read (\(touchReason))")
                unverified = true
            case .failed: break
            }
        }

        // 2. Numbered shards without an index (split GGUF `x-00001-of-00003.gguf`): every number must be here.
        var groups: [String: (total: Int, have: Set<Int>)] = [:]
        for e in entries where e.size != nil || e.broken {
            let ns = e.rel as NSString
            guard let m = shardPattern.firstMatch(in: e.rel, range: NSRange(location: 0, length: ns.length)) else { continue }
            let wext = ns.substring(with: m.range(at: 4)).lowercased()
            if indexedDirs.contains(ns.deletingLastPathComponent + "|" + wext) { continue }
            let key = ns.substring(with: m.range(at: 1)) + "|" + ns.substring(with: m.range(at: 3)) + "|" + wext
            let n = Int(ns.substring(with: m.range(at: 2))) ?? 0
            var g = groups[key] ?? (Int(ns.substring(with: m.range(at: 3))) ?? 0, [])
            if e.size != nil { g.have.insert(n) }
            groups[key] = g
        }
        for (key, g) in groups.sorted(by: { $0.key < $1.key }) {
            let first = g.have.contains(0) ? 0 : 1            // some repos count from 00000
            let missing = (first..<(first + g.total)).filter { !g.have.contains($0) }
            if !missing.isEmpty {
                let base = key.components(separatedBy: "|")[0]
                problems.append("missing \(missing.count) of \(g.total) parts of \(base)")
            }
        }

        // 3. Each weights file is whole: as long as its header says (safetensors offsets, GGUF tensor table).
        for e in weights {
            guard let real = e.real else { continue }
            switch ext(e.rel) {
            case "safetensors":
                switch safetensorsCheck(real) {
                case .ok(let p?): problems.append("\(e.rel): \(p)")
                case .ok(nil): break
                case .wouldTouch:
                    unchecked.append("\(e.rel): header not checked (\(touchReason))")
                    unverified = true   // a never-read file is the likeliest to be truncated (review M2)
                case .failed: problems.append("\(e.rel): can't be read")
                }
            case "gguf":
                switch ggufCheck(real) {
                case .ok(.whole): break
                case .ok(.problem(let p)): problems.append("\(e.rel): \(p)")
                case .ok(.unknown(let why)):
                    unchecked.append("\(e.rel): \(why)")
                    unverified = true
                case .failed: problems.append("\(e.rel): can't be read")
                case .wouldTouch:
                    unchecked.append("\(e.rel): header not checked (\(touchReason))")
                    unverified = true
                }
            default: break
            }
        }

        // Format and quantisation.
        let present = weights.filter { $0.size != nil }
        let exts = Set(present.map { ext($0.rel) })
        var config: [String: Any]?
        if let dir = configDir {
            switch readFile(dir + "/config.json", max: 8 << 20) {
            case .ok(let d): config = try? JSONSerialization.jsonObject(with: d) as? [String: Any]
            case .wouldTouch: unchecked.append("config.json not read (\(touchReason)), quant from the name only")
            case .failed: break
            }
        }
        let format: String
        if exts.contains("gguf") { format = "gguf" }
        else if exts.contains("safetensors") || exts.contains("npz") {
            let lower = name.lowercased()
            format = (config?["quantization"] != nil || lower.contains("mlx") || exts.contains("npz")) ? "mlx" : "safetensors"
        }
        else if !exts.isDisjoint(with: ["bin", "pt", "pth", "ckpt"]) { format = "pytorch" }
        else if exts.contains("onnx") { format = "onnx" }
        else { format = "none" }
        if present.isEmpty && weights.isEmpty { problems.insert("no weights files", at: 0) }

        var quant: String?
        if format == "gguf" {
            let qs = present.filter { ext($0.rel) == "gguf" }.compactMap { ggufQuant(($0.rel as NSString).lastPathComponent) }
            var seen = Set<String>()
            let uniq = qs.filter { seen.insert($0).inserted }
            if !uniq.isEmpty { quant = uniq.joined(separator: ",") }
        }
        quant = quant ?? quantFrom(name: name, config: config)
        var seen = Set<String>(), bytes: Int64 = 0
        for e in entries { if let r = e.real, let sz = e.size, seen.insert(r).inserted { bytes += sz } }
        return Report(format: format, quant: quant, problems: problems, bytes: bytes, unchecked: unchecked,
                      unverified: unverified && problems.isEmpty, entries: entries)
    }

    // MARK: Quantisation

    private static func firstMatch(_ pattern: String, _ s: String, group: Int = 1) -> String? {
        guard let re = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else { return nil }
        let ns = s as NSString
        guard let m = re.firstMatch(in: s, range: NSRange(location: 0, length: ns.length)) else { return nil }
        return ns.substring(with: m.range(at: group))
    }

    /// From a GGUF file name: `Qwen3.8-27B-Q4_K_M.gguf` → Q4_K_M, `…-UD-IQ2_XXS-00001-of-00003.gguf` → UD-IQ2_XXS.
    static func ggufQuant(_ file: String) -> String? {
        let stem = file.replacingOccurrences(of: #"(-\d{5}-of-\d{5})?\.gguf$"#, with: "", options: [.regularExpression, .caseInsensitive])
        return firstMatch(#"(?:^|[-_.])((?:UD-)?I?Q\d+(?:_[A-Z0-9]+)*|BF16|F16|F32|MXFP4|NVFP4)$"#, stem)?.uppercased()
            ?? firstMatch(#"(?:^|[-_.])((?:UD-)?I?Q\d+(?:_[A-Z0-9]+)*|BF16|F16|F32|MXFP4|NVFP4)(?=[-_.])"#, stem)?.uppercased()
    }

    /// From the name alone: 3.3bpw, 4bit, bf16, Q8, mxfp4 …
    static func quantFromName(_ name: String) -> String? {
        if let b = firstMatch(#"(\d+(?:\.\d+)?)[-_ ]?bpw"#, name) { return b + "bpw" }
        if let b = firstMatch(#"(?<![A-Za-z0-9.])(\d{1,2})[-_ ]?bits?(?![A-Za-z])"#, name) { return b + "bit" }
        if let t = firstMatch(#"(?:^|[-_./:])(bf16|fp16|f16|fp8|fp32|int4|int8|mxfp4|nvfp4|(?:ud-)?i?q\d(?:_[a-z0-9]+)*)(?=$|[-_./])"#, name) {
            return t.hasPrefix("q") || t.hasPrefix("Q") || t.lowercased().hasPrefix("iq") || t.lowercased().hasPrefix("ud-") ? t.uppercased() : t.lowercased()
        }
        return nil
    }

    /// Name first when it says bits per weight (mixed quants), then config.json, then the rest of the name, then dtype.
    static func quantFrom(name: String, config: [String: Any]?) -> String? {
        if let b = firstMatch(#"(\d+(?:\.\d+)?)[-_ ]?bpw"#, name) { return b + "bpw" }
        if let q = config?["quantization"] as? [String: Any] {
            let mode = (q["mode"] as? String)?.lowercased()
            if let m = mode, m != "affine", !m.isEmpty { return m }
            if let bits = (q["bits"] as? NSNumber)?.intValue { return "\(bits)bit" }
        }
        if let qc = config?["quantization_config"] as? [String: Any] {
            let method = (qc["quant_method"] as? String)?.lowercased()
            let bits = (qc["bits"] as? NSNumber)?.intValue ?? (qc["load_in_4bit"] as? Bool == true ? 4 : (qc["load_in_8bit"] as? Bool == true ? 8 : nil))
            switch (method, bits) {
            case let (m?, b?): return "\(m)-\(b)bit"
            case let (m?, nil): return m
            case let (nil, b?): return "\(b)bit"
            default: break
            }
        }
        if let n = quantFromName(name) { return n }
        let text = config?["text_config"] as? [String: Any]
        if let d = (config?["torch_dtype"] as? String) ?? (config?["dtype"] as? String)
            ?? (text?["torch_dtype"] as? String) ?? (text?["dtype"] as? String) {
            switch d.lowercased() {
            case "bfloat16": return "bf16"
            case "float16": return "fp16"
            case "float32": return "fp32"
            default: return d.lowercased()
            }
        }
        return nil
    }

    // MARK: File checks (bounded reads, regular files only)

    enum FileRead<T> { case ok(T), wouldTouch, failed }

    static let touchReason = "reading it would change its last-access time"

    /// On APFS, reading a file whose access time is older than its modification time sets the access time to now
    /// (opening it doesn't). The app counts access times as evidence of use, so llmavail must not read such a file:
    /// it would make the model look used today and hold off auto-delete. Checked on the open descriptor.
    static func readWouldTouch(_ st: stat) -> Bool {
        let a = st.st_atimespec, m = st.st_mtimespec
        return a.tv_sec < m.tv_sec || (a.tv_sec == m.tv_sec && a.tv_nsec < m.tv_nsec)
    }

    /// Runs `body` on a regular file opened read-only and non-blocking, unless reading it would change its access
    /// time. Checked with stat() BEFORE opening: on a Mac with an on-access malware scanner the open itself can lead
    /// to a read (security review 2026-11-14, H1), and opening a device can have side effects (L1). After opening,
    /// the descriptor must still be that same regular file.
    static func withRegularFile<T>(_ path: String, guardAtime: Bool = true, _ body: (Int32, Int64) -> T?) -> FileRead<T> {
        var pre = stat()
        guard stat(path, &pre) == 0, (pre.st_mode & S_IFMT) == S_IFREG else { return .failed }
        if guardAtime && readWouldTouch(pre) { return .wouldTouch }
        let fd = open(path, O_RDONLY | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { return .failed }
        defer { close(fd) }
        var st = stat()
        guard fstat(fd, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG,
              st.st_dev == pre.st_dev, st.st_ino == pre.st_ino else { return .failed }   // swapped since the stat
        if guardAtime && readWouldTouch(st) { return .wouldTouch }
        return body(fd, Int64(st.st_size)).map { .ok($0) } ?? .failed
    }

    /// A small regular file, at most `max` bytes.
    static func readFile(_ path: String, max: Int, guardAtime: Bool = true) -> FileRead<Data> {
        withRegularFile(path, guardAtime: guardAtime) { fd, size -> Data? in
            guard size <= Int64(max) else { return nil }
            let h = FileHandle(fileDescriptor: fd, closeOnDealloc: false)
            guard let d = try? h.read(upToCount: max + 1), d.count <= max else { return nil }
            return d
        }
    }

    /// The same, nil when it can't (or mustn't) be read.
    static func readRegular(_ path: String, max: Int, guardAtime: Bool = true) -> Data? {
        if case .ok(let d) = readFile(path, max: max, guardAtime: guardAtime) { return d }
        return nil
    }

    private static func pread(_ fd: Int32, _ count: Int, at offset: Int64) -> [UInt8]? {
        var buf = [UInt8](repeating: 0, count: count)
        var got = 0
        while got < count {
            let n = buf.withUnsafeMutableBytes { Darwin.pread(fd, $0.baseAddress! + got, count - got, off_t(offset) + off_t(got)) }
            if n <= 0 { return nil }
            got += n
        }
        return buf
    }

    /// A GGUF file is as long as its tensor table says (see `GGUF`).
    static func ggufCheck(_ path: String) -> FileRead<GGUF.Check> {
        withRegularFile(path) { fd, size in GGUF.check(fd: fd, size: size) }
    }

    /// A safetensors file is 8 bytes of header length, a JSON header, then the tensors; the header's largest
    /// `data_offsets` end says how long the file must be. Catches a truncated or half-copied shard without
    /// reading the weights. `.ok(nil)` = whole, `.ok(problem)` otherwise.
    static func safetensorsCheck(_ path: String) -> FileRead<String?> {
        withRegularFile(path) { fd, size -> String?? in
            guard size >= 8, let lenBytes = pread(fd, 8, at: 0) else { return .some("too short to be a safetensors file") }
            let n = lenBytes.enumerated().reduce(UInt64(0)) { $0 | (UInt64($1.element) << (8 * UInt64($1.offset))) }
            guard n >= 2, n <= 100 << 20, Int64(n) + 8 <= size else { return .some("damaged header") }
            guard let hb = pread(fd, Int(n), at: 8),
                  let j = try? JSONSerialization.jsonObject(with: Data(hb)) as? [String: Any] else { return .some("damaged header") }
            // Offsets come from the file: checked against the file's size before any arithmetic, so a crafted
            // header can't overflow (security review 2026-11-14, M1).
            let room = size - 8 - Int64(n)
            var end: Int64 = 0
            for (k, v) in j where k != "__metadata__" {
                guard let t = v as? [String: Any], let offs = t["data_offsets"] as? [NSNumber], offs.count == 2 else { continue }
                let a = offs[0].int64Value, b = offs[1].int64Value
                guard a >= 0, b >= a else { return .some("damaged header (bad tensor offsets)") }
                if b > room { return .some("truncated (header needs \(b) data bytes, file has \(room))") }
                end = max(end, b)
            }
            return .some(nil)
        }
    }

    // MARK: Helpers

    static func isPlainName(_ s: String) -> Bool {
        !s.isEmpty && s != "." && s != ".." && !s.contains("/") && !s.contains("\0")
    }

    /// A relative path that stays inside its folder: no leading "/", no "." or ".." parts.
    static func isSafeRelative(_ s: String) -> Bool {
        guard !s.isEmpty, !s.hasPrefix("/"), !s.contains("\0") else { return false }
        return s.split(separator: "/", omittingEmptySubsequences: false).allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
    }

    static func sortedNames(_ dir: String) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []).filter(isPlainName).sorted()
    }

    static func mtime(_ path: String) -> Date? {
        var st = stat()
        return lstat(path, &st) == 0 ? Date(timeIntervalSince1970: TimeInterval(st.st_mtimespec.tv_sec)) : nil
    }

    static func short(_ s: String) -> String { String(s.prefix(12)) }
}
