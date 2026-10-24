import Foundation
import Darwin

/// Model folders outside the Hugging Face cache and Ollama's store (benchmark downloads, `hf download --local-dir`,
/// loose GGUF files). You add the folders; each entry directly inside one that is clearly a model becomes a row:
/// a folder whose weights files (.gguf, .safetensors, .bin, …, within three levels) add up to at least 20 MB and to
/// most of its bytes, or a weights file of at least 20 MB (split GGUF parts `name-00001-of-00003.gguf` are one row).
/// A folder holding a git checkout, an app bundle or node_modules is never a model. Anything else in the watched
/// folder is left alone and never listed. (Security review 2026-10-24, M3: auto-delete trusts this test.)
///
/// Rules, same spirit as the two stores:
/// - Folders are walked through open folder handles (O_NOFOLLOW), never by path, so a folder swapped for a link
///   mid-scan isn't followed. Links are never listed or deleted through.
/// - Every link anywhere under a watched folder that points into the Hugging Face cache, Ollama's store or a watched
///   folder (a file, or a folder: its files are walked) marks those files as used by that link. The model holding
///   them can't be deleted while the link exists, so deleting a store model can't silently break a folder model.
/// - A file with other hard links frees nothing when deleted, so it isn't counted as exclusive.
/// - A watched folder may not be "/", your home folder or a folder above it, a system folder, inside or above
///   either store, or inside or above another watched folder. Compared by device and inode, so an alias path
///   (such as /System/Volumes/Data/…) can't get round it.
/// - A model that couldn't be read in full can't be deleted.
enum FolderStore {
    static let weightExtensions: Set<String> = ["gguf", "safetensors", "bin", "pt", "pth", "onnx", "npz", "ckpt", "mlmodel"]
    static let minWeightBytes: Int64 = 20_000_000
    /// Loose files directly in a watched folder count as models only with these (generic .bin/.pt/… only inside folders).
    static let looseExtensions: Set<String> = ["gguf", "safetensors", "onnx", "mlmodel"]
    private static let maxFiles = 200_000
    private static let maxLinkedFiles = 200_000          // across the whole scan
    private static let notModelMarkers: Set<String> = [".git", "node_modules"]

    struct Scan {
        var models: [CachedModel] = []
        var files: [String: Set<String>] = [:]        // model id -> its regular files (absolute), for the lsof check
        var linkTargets: [String: Set<String>] = [:]  // real file a link points at -> paths of the links' owners
        var roots: [String] = []                      // watched folders that were read
        var missing: [String] = []                    // watched folders that couldn't be read
        var problems: [String] = []
        var staging: [String] = []
        /// Why some links under a watched folder may not have been seen (store models with shared files are blocked).
        var linksIncomplete: String?
        var linkedFilesSeen = 0
    }

    // MARK: Which folders may be watched

    private struct Ident: Equatable { let dev: dev_t; let ino: ino_t }
    private static func ident(_ path: String) -> Ident? {
        var st = stat()
        return stat(path, &st) == 0 ? Ident(dev: st.st_dev, ino: st.st_ino) : nil
    }
    /// The path itself and every folder above it, as identities.
    private static func chain(_ path: String) -> [Ident] {
        var out: [Ident] = [], p = path
        while true {
            if let i = ident(p) { out.append(i) }
            if p == "/" || p.isEmpty { break }
            p = (p as NSString).deletingLastPathComponent
        }
        return out
    }

    static var storeRoots: [String] {
        [realPath(CacheScanner.cacheRoot.path), realPath(OllamaStore.root.path)].filter { $0.count > 1 }
    }

    /// Why `path` can't be watched, or nil if it can. `others` = the other watched folders. Checked when a folder is
    /// added, at every scan, and right before a delete.
    static func problem(_ path: String, others: [String] = []) -> String? {
        guard path.hasPrefix("/"), path != "/" else { return "must be an absolute folder path, not /" }
        guard Deleter.isRealDirectory(path), realPath(path) == path, let me = ident(path) else {
            return "not a folder, or a symbolic link is on its path"
        }
        let mine = chain(path)                     // me and everything above me
        let home = realPath(FileManager.default.homeDirectoryForCurrentUser.path)
        if let h = ident(home), chain(home).contains(me) {
            return h == me ? "your home folder is too broad; pick the folder that holds the models"
                           : "it contains your home folder"
        }
        for sys in ["/System", "/Library", "/Applications", "/usr", "/bin", "/sbin", "\(home)/Library", "\(home)/Applications"] {
            if let s = ident(sys), mine.contains(s) { return "it is inside \(sys), a system folder" }
        }
        for top in ["/private", "/etc", "/var", "/opt", "/cores", "/Volumes", "/Users", "/private/var", "/private/tmp"] {
            if ident(top) == me { return "\(top) is too broad" }
        }
        for store in storeRoots {
            if let s = ident(store), mine.contains(s) { return "it is inside \(store), which the app already reads" }
            if chain(store).contains(me) { return "it contains \(store), which the app already reads" }
        }
        for o in others where o != path {
            if let oi = ident(o), mine.contains(oi) { return "it is inside \(o), which is already watched" }
            if chain(o).contains(me) { return "it contains \(o), which is already watched" }
        }
        return nil
    }

    /// `name-00001-of-00003.gguf` -> `name.gguf`; nil for anything else.
    static func splitBase(_ name: String) -> String? {
        guard let r = name.range(of: #"-\d{5}-of-\d{5}\.gguf$"#, options: [.regularExpression, .caseInsensitive]) else { return nil }
        return String(name[..<r.lowerBound]) + ".gguf"
    }

    // MARK: Scan

    static func scan(_ roots: [String]) -> Scan {
        var s = Scan()
        let protectedRoots = storeRoots + roots
        for root in roots {
            if let p = problem(root, others: roots) { s.problems.append("\(root): \(p)"); s.missing.append(root); continue }
            guard let dir = DirHandle.open(root), let rootSt = dir.ownStat(), let names = try? dir.names() else {
                s.problems.append("\(root): can't list it"); s.missing.append(root); continue
            }
            s.roots.append(root)
            var groups: [String: [String]] = [:]
            for n in names.sorted() {
                if n.hasPrefix(".mcc-staging-") { s.staging.append(root + "/" + n) }
                let hidden = n.hasPrefix(".")          // never listed, but links inside still count
                guard let st = dir.entryStat(n) else { continue }
                switch st.st_mode & S_IFMT {
                case S_IFDIR:
                    guard st.st_dev == rootSt.st_dev, let sub = dir.sub(n) else { continue }   // a mounted volume: not ours
                    if let m = folderModel(root: root, name: n, dir: sub, device: rootSt.st_dev,
                                           protectedRoots: protectedRoots, into: &s), !hidden { s.models.append(m) }
                case S_IFREG:
                    let ext = (n as NSString).pathExtension.lowercased()
                    if !hidden, looseExtensions.contains(ext) { groups[splitBase(n) ?? n, default: []].append(n) }
                case S_IFLNK:
                    recordLink(root + "/" + n, owner: root + "/" + n, protectedRoots: protectedRoots, into: &s)
                default:
                    continue
                }
            }
            for (base, members) in groups.sorted(by: { $0.key < $1.key }) {
                if let m = fileModel(root: root, dir: dir, base: base, members: members.sorted(), into: &s) { s.models.append(m) }
            }
        }
        return s
    }

    private struct Walk {
        var total: Int64 = 0, exclusive: Int64 = 0, weights: Int64 = 0
        var newestMtime: Date?, newestAtime: Date?
        var files = Set<String>(), links: [String] = []
        var notModel = false
        var problem: String?
        var unseen: String?          // part of the tree couldn't be walked: links there are unknown
        var capped = false
        var count = 0
    }

    /// Every entry under an open folder, through open folder handles only; links are recorded, never followed.
    /// A problem (unreadable part, mount, depth) is recorded but the walk goes on, so links further on are still
    /// seen; `linksIncomplete` says when part of it could not be seen at all.
    private static func walk(_ dir: DirHandle, path: String, device: dev_t, depth: Int, into w: inout Walk) {
        guard !w.capped else { return }
        // 62, not 64: a permanent delete's removeTree counts the entry itself as one more level.
        guard depth < 62 else { w.problem = w.problem ?? "folders nested more than 62 deep"; w.unseen = w.unseen ?? w.problem; return }
        guard let names = try? dir.names() else { w.problem = w.problem ?? "can't read \(path)"; w.unseen = w.unseen ?? "can't read \(path)"; return }
        for n in names {
            w.count += 1
            if w.count > maxFiles { w.problem = "more than \(maxFiles) files"; w.unseen = w.problem; w.capped = true; return }
            let p = path + "/" + n
            guard let st = dir.entryStat(n) else { w.problem = w.problem ?? "can't read \(p)"; w.unseen = w.unseen ?? "can't read \(p)"; continue }
            switch st.st_mode & S_IFMT {
            case S_IFDIR:
                if notModelMarkers.contains(n) || n.hasSuffix(".app") { w.notModel = true }
                guard st.st_dev == device else {
                    w.problem = w.problem ?? "another volume is mounted inside it (\(p))"; w.unseen = w.unseen ?? w.problem; continue
                }
                guard let sub = dir.sub(n) else { w.problem = w.problem ?? "can't open \(p)"; w.unseen = w.unseen ?? "can't open \(p)"; continue }
                walk(sub, path: p, device: device, depth: depth + 1, into: &w)
            case S_IFREG:
                let size = Int64(st.st_size)
                w.total += size
                if st.st_nlink == 1 { w.exclusive += size }
                if depth <= 2, weightExtensions.contains((n.lowercased() as NSString).pathExtension) { w.weights += size }
                w.files.insert(p)
                let m = Date(timeIntervalSince1970: TimeInterval(st.st_mtimespec.tv_sec))
                let a = Date(timeIntervalSince1970: TimeInterval(st.st_atimespec.tv_sec))
                w.newestMtime = max(w.newestMtime ?? m, m)
                w.newestAtime = max(w.newestAtime ?? a, a)
            case S_IFLNK:
                w.links.append(p)
            default:
                continue
            }
        }
    }

    private static func folderModel(root: String, name: String, dir: DirHandle, device: dev_t,
                                    protectedRoots: [String], into s: inout Scan) -> CachedModel? {
        let path = root + "/" + name
        var w = Walk()
        if name.hasSuffix(".app") { w.notModel = true }
        walk(dir, path: path, device: device, depth: 0, into: &w)
        // Links count whether or not this is a model: a link here into a store must still protect the store's file.
        for l in w.links { recordLink(l, owner: path, protectedRoots: protectedRoots, into: &s) }
        if let u = w.unseen, s.linksIncomplete == nil { s.linksIncomplete = "\(path): \(u)" }
        guard w.problem == nil, !w.notModel, w.weights >= minWeightBytes, w.weights * 2 >= w.total else { return nil }
        var m = CachedModel(id: "folder:" + path, kind: "folder",
                            name: (root as NSString).lastPathComponent + "/" + name, folder: URL(fileURLWithPath: path))
        m.store = .folder
        m.folderRoot = root
        m.folderMembers = [name]
        m.totalBytes = w.total
        m.exclusiveBytes = w.exclusive
        m.lastAccess = w.newestAtime
        m.downloaded = w.newestMtime
        s.files[m.id] = w.files
        return m
    }

    private static func fileModel(root: String, dir: DirHandle, base: String, members: [String], into s: inout Scan) -> CachedModel? {
        var m = CachedModel(id: "file:" + root + "/" + base, kind: "file",
                            name: (root as NSString).lastPathComponent + "/" + base,
                            folder: URL(fileURLWithPath: root + "/" + members[0]))
        m.store = .folder
        m.folderRoot = root
        m.folderMembers = members
        var files = Set<String>()
        for n in members {
            guard let st = dir.entryStat(n), (st.st_mode & S_IFMT) == S_IFREG else { continue }
            let size = Int64(st.st_size)
            m.totalBytes += size
            if st.st_nlink == 1 { m.exclusiveBytes += size }
            files.insert(root + "/" + n)
            let mt = Date(timeIntervalSince1970: TimeInterval(st.st_mtimespec.tv_sec))
            let at = Date(timeIntervalSince1970: TimeInterval(st.st_atimespec.tv_sec))
            m.downloaded = max(m.downloaded ?? mt, mt)
            m.lastAccess = max(m.lastAccess ?? at, at)
        }
        guard m.totalBytes >= minWeightBytes else { return nil }
        if let parts = members.first.flatMap(splitTotal), parts != members.count {
            m.deleteBlocked = "only \(members.count) of its \(parts) parts are here"
        }
        s.files[m.id] = files
        return m
    }

    /// Records what a link points at, if that is inside a store or a watched folder: one file, or every file under
    /// a folder (capped). Files are recorded by their real path, so links inside the target are resolved too.
    private static func recordLink(_ link: String, owner: String, protectedRoots: [String], into s: inout Scan) {
        let target = realPath(link)
        guard protectedRoots.contains(where: { target.hasPrefix($0 + "/") }) else { return }
        if Deleter.isRealFile(target) {
            s.linkTargets[target, default: []].insert(owner)
        } else if Deleter.isRealDirectory(target),
                  let en = FileManager.default.enumerator(atPath: target) {
            while let rel = en.nextObject() as? String {
                s.linkedFilesSeen += 1
                if s.linkedFilesSeen > maxLinkedFiles {
                    s.linksIncomplete = s.linksIncomplete ?? "links lead to more than \(maxLinkedFiles) files"
                    return
                }
                let real = realPath(target + "/" + rel)
                if Deleter.isRealFile(real) { s.linkTargets[real, default: []].insert(owner) }
            }
        }
    }

    /// "x-00001-of-00003.gguf" -> 3.
    private static func splitTotal(_ name: String) -> Int? {
        guard let r = name.range(of: #"-of-\d{5}\.gguf$"#, options: [.regularExpression, .caseInsensitive]) else { return nil }
        return Int(name[r].dropFirst(4).prefix(5))
    }

    // MARK: In use

    /// Whether a command line or launch agent names this model: its full path, or "<watched folder>/<entry>"
    /// (catches relative paths such as `../models/x`). A false match only locks the model, never deletes it.
    static func mentions(_ text: String, _ m: CachedModel) -> Bool {
        guard let root = m.folderRoot else { return false }
        let last = (root as NSString).lastPathComponent
        return m.folderMembers.contains { text.contains(root + "/" + $0) || text.contains(last + "/" + $0) }
    }

    /// A process working inside the model folder, or working in the watched folder (or a folder in it) and naming
    /// the entry by a relative path (`--model qwen3-8b`, `./qwen 3/`, `../qwen3-8b`), is using it. Substring
    /// matches: a false match only locks the model.
    static func usedFrom(cwd: String, args: String, _ m: CachedModel) -> Bool {
        guard let root = m.folderRoot else { return false }
        if m.kind == "folder", cwd == m.folder.path || cwd.hasPrefix(m.folder.path + "/") { return true }
        if cwd == root {
            return m.folderMembers.contains { n in
                [" ", "=", "./", "'", "\""].contains { args.contains($0 + n) }
            }
        }
        if cwd.hasPrefix(root + "/") { return m.folderMembers.contains { args.contains("../" + $0) } }
        return false
    }
}
