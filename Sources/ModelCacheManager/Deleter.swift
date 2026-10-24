import Foundation
import Darwin

enum DeleteError: LocalizedError {
    case locked(String), unsafe(String), gone(String), interrupted(String)
    var errorDescription: String? {
        switch self {
        case .interrupted(let r): return "Interrupted: \(r)"
        case .locked(let r): return "Not deleted: \(r)"
        case .unsafe(let r): return "Refused: \(r)"
        case .gone(let r): return "Skipped: \(r)"
        }
    }
}

struct DeleteOutcome {
    var freed: Int64            // bytes actually removed, not just what the scan predicted
    var trashLocation: String?  // where the Trash item landed (macOS may rename it on arrival)
}

enum Deleter {
    /// Hub cache repo folders look like `models--org--name` (also datasets / spaces).
    private static let repoFolderPattern = #"^(models|datasets|spaces)--[^/]+--[^/]+$"#

    static func isRealDirectory(_ path: String) -> Bool {
        var st = stat()
        return lstat(path, &st) == 0 && (st.st_mode & S_IFMT) == S_IFDIR
    }

    static func isRealFile(_ path: String) -> Bool {
        var st = stat()
        return lstat(path, &st) == 0 && (st.st_mode & S_IFMT) == S_IFREG
    }

    /// The repo folder must be a real directory directly inside the cache root,
    /// with no symlink anywhere on its path. Checked right before anything is moved.
    private static func verifiedFolder(_ m: CachedModel, root: String) throws -> String {
        let name = m.folder.lastPathComponent
        let path = root + "/" + name
        guard name.range(of: repoFolderPattern, options: .regularExpression) != nil,
              m.folder.path == path else {
            throw DeleteError.unsafe("\(m.id) is not a model folder directly inside the cache")
        }
        guard isRealDirectory(path), realPath(path) == path else {
            throw DeleteError.unsafe("\(name) is a symbolic link or not a folder")
        }
        return path
    }

    /// A shared blob may only be removed if it is a regular file (not a link) whose real
    /// location is exactly where we expect it, inside the cache's shared blob store.
    private static func isRemovableBlob(_ path: String, root: String) -> Bool {
        path.hasPrefix(root + "/blobs/") && realPath(path) == path && isRealFile(path)
    }

    /// Removes a model folder plus the shared-store blobs only it uses.
    /// To Trash: everything lands as ONE Trash item named after the model. If any step fails,
    /// everything already moved is put back and nothing is deleted.
    @discardableResult
    static func delete(_ m: CachedModel, toTrash: Bool) throws -> DeleteOutcome {
        if let r = m.inUseReason { throw DeleteError.locked(r) }
        if let r = m.deleteBlocked { throw DeleteError.unsafe(r) }
        if m.store == .ollama { return try deleteOllama(m, toTrash: toTrash) }
        if m.store == .folder { return try deleteFolder(m, toTrash: toTrash) }
        let root = realPath(CacheScanner.cacheRoot.path)
        guard root != "/", isRealDirectory(root) else { throw DeleteError.unsafe("the cache root is not a folder") }
        let folder = try verifiedFolder(m, root: root)
        let allBlobs = m.externalExclusiveFiles.map(\.path)
        let blobs = allBlobs.filter { isRemovableBlob($0, root: root) }
        let refused = allBlobs.filter { !blobs.contains($0) }.reduce(Int64(0)) { $0 + (fileStat($1)?.size ?? 0) }
        let freed = m.exclusiveBytes - refused

        // Each blob's folder is opened from the cache root down without following links, and the blob is
        // removed or moved by name inside it, so a folder swapped for a link after the checks can't redirect it.
        guard let rootDir = DirHandle.open(root) else { throw DeleteError.unsafe("couldn't open the cache root") }
        func blobParent(_ path: String) -> (dir: DirHandle, name: String)? {
            var parts = String(path.dropFirst(root.count + 1)).components(separatedBy: "/")
            let name = parts.removeLast()
            var dir = rootDir
            for p in parts { guard let next = dir.sub(p) else { return nil }; dir = next }
            return dir.fileSize(name) == nil ? nil : (dir, name)
        }

        let holderName = ".mcc-staging-" + UUID().uuidString
        let folderName = (folder as NSString).lastPathComponent

        guard toTrash else {
            // Move the folder out of the cache into a fresh staging folder, then remove it through open folder
            // handles only: a folder inside it swapped for a link mid-delete loses the link, never its target.
            let holder = try rootDir.makeFolder(holderName)
            do {
                _ = try verifiedFolder(m, root: root)    // re-check immediately before the move
                try rootDir.move(folderName, to: holder, as: folderName)
            } catch { rootDir.removeEmptyFolder(holderName); throw error }
            var removed: Int64
            do { removed = try holder.removeTree(folderName) } catch {
                // Out of the cache but not fully removed: say where the rest is (also listed as an interrupted delete).
                let why: String
                if case DeleteError.unsafe(let r) = error { why = r } else { why = error.localizedDescription }
                throw DeleteError.interrupted("\(why); what's left of \(m.id) is in \(root)/\(holderName)")
            }
            for b in blobs where isRemovableBlob(b, root: root) {
                if let (dir, name) = blobParent(b), let size = dir.freedSize(name), (try? dir.unlink(name)) != nil { removed += size }
            }
            rootDir.removeEmptyFolder(holderName)
            return DeleteOutcome(freed: removed, trashLocation: nil)
        }

        let itemName = trashName(m.name, suffix: " (model cache)")
        var undo: [() throws -> Void] = []          // moves back, newest first on rollback
        var made: [(parent: DirHandle, name: String)] = []
        func rollback() {
            var stranded = false
            for u in undo.reversed() { do { try u() } catch { stranded = true } }
            for f in made.reversed() { f.parent.removeEmptyFolder(f.name) }   // only ever removes EMPTY folders
            if stranded { Store.log("Could not fully undo a failed delete of \(m.id); its files are in \(root)/\(holderName)") }
        }

        do {
            let holder = try rootDir.makeFolder(holderName); made.append((rootDir, holderName))
            let item = try holder.makeFolder(itemName); made.append((holder, itemName))
            _ = try verifiedFolder(m, root: root)        // re-check immediately before the move
            try rootDir.move(folderName, to: item, as: folderName)
            undo.append { try item.move(folderName, to: rootDir, as: folderName) }
            if !blobs.isEmpty {
                let shared = try item.makeFolder("shared-blobs"); made.append((item, "shared-blobs"))
                for b in blobs where isRemovableBlob(b, root: root) {   // re-checked right before each move
                    guard let (dir, name) = blobParent(b) else { continue }
                    let flat = String(b.dropFirst(root.count + 1)).replacingOccurrences(of: "/", with: "_")
                    try dir.move(name, to: shared, as: flat)
                    undo.append { try shared.move(flat, to: dir, as: name) }
                }
            }
            let landed = try trash(root: root, holderName: holderName, holder: holder, itemName: itemName, item: item)
            rootDir.removeEmptyFolder(holderName)   // now empty; never a recursive delete
            return DeleteOutcome(freed: freed, trashLocation: landed)
        } catch {
            rollback()
            throw error
        }
    }

    /// The Trash only takes a path. Right before handing it over, the path must still lead to the staging
    /// folders we hold open (same device and inode), so a renamed holder with a link in its place can't
    /// send something else to the Trash.
    private static func trash(root: String, holderName: String, holder: DirHandle, itemName: String, item: DirHandle) throws -> String? {
        let holderPath = root + "/" + holderName, itemPath = holderPath + "/" + itemName
        guard holder.isStill(at: holderPath), item.isStill(at: itemPath) else {
            throw DeleteError.unsafe("the staging folder changed during the delete; nothing was moved to the Trash")
        }
        var landed: NSURL?
        try FileManager.default.trashItem(at: URL(fileURLWithPath: itemPath), resultingItemURL: &landed)
        return landed?.path
    }

    // MARK: Model folders

    /// Removes a model from a watched folder: the entries directly in that folder that make it up (a folder, a
    /// file, or the parts of a split GGUF). Same mechanics as a Hugging Face delete: the watched folder is opened
    /// with no link anywhere on its path, each entry is re-checked and then moved by name into a staging folder
    /// beside it, and removed (or sent to the Trash as one item) from there, never following a link. A Trash
    /// delete puts everything back if any step fails.
    private static func deleteFolder(_ m: CachedModel, toTrash: Bool) throws -> DeleteOutcome {
        guard let root = m.folderRoot, !m.folderMembers.isEmpty, m.kind == "folder" || m.kind == "file" else {
            throw DeleteError.unsafe("\(m.id) is not a model in a watched folder")
        }
        // Still a folder you watch, and still passing every check (a store may have moved under it since).
        let watched = Store.load().settings.modelFolders
        guard watched.contains(root) else { throw DeleteError.unsafe("\(root) is no longer a watched folder") }
        if let p = FolderStore.problem(root, others: watched) { throw DeleteError.unsafe("\(root): \(p)") }
        var rootSt = stat()
        guard lstat(root, &rootSt) == 0 else { throw DeleteError.unsafe("can't read \(root)") }
        func verify() throws {
            for n in m.folderMembers {
                let p = root + "/" + n
                var st = stat()
                guard !n.isEmpty, !n.contains("/"), !n.hasPrefix("."),
                      m.kind == "folder" ? isRealDirectory(p) : isRealFile(p), realPath(p) == p,
                      lstat(p, &st) == 0, st.st_dev == rootSt.st_dev else {
                    throw DeleteError.unsafe("\(n) is a symbolic link, missing, on another volume, or not what the scan found")
                }
            }
        }
        try verify()
        guard let rootDir = DirHandle.open(root) else { throw DeleteError.unsafe("couldn't open \(root)") }
        let holderName = ".mcc-staging-" + UUID().uuidString

        guard toTrash else {
            let holder = try rootDir.makeFolder(holderName)
            var moved: [String] = []
            do {
                try verify()    // re-check immediately before the move
                for n in m.folderMembers { try rootDir.move(n, to: holder, as: n); moved.append(n) }
            } catch {
                for n in moved.reversed() { try? holder.move(n, to: rootDir, as: n) }
                rootDir.removeEmptyFolder(holderName)
                throw error
            }
            var removed: Int64 = 0
            do { for n in moved { removed += try holder.removeTree(n) } } catch {
                let why: String
                if case DeleteError.unsafe(let r) = error { why = r } else { why = error.localizedDescription }
                throw DeleteError.interrupted("\(why); what's left of \(m.name) is in \(root)/\(holderName)")
            }
            rootDir.removeEmptyFolder(holderName)
            return DeleteOutcome(freed: removed, trashLocation: nil)
        }

        let itemName = trashName(m.name, suffix: " (model folder)")
        var undo: [() throws -> Void] = []
        var made: [(parent: DirHandle, name: String)] = []
        func rollback() {
            var stranded = false
            for u in undo.reversed() { do { try u() } catch { stranded = true } }
            for f in made.reversed() { f.parent.removeEmptyFolder(f.name) }   // only ever removes EMPTY folders
            if stranded { Store.log("Could not fully undo a failed delete of \(m.id); its files are in \(root)/\(holderName)") }
        }
        do {
            let holder = try rootDir.makeFolder(holderName); made.append((rootDir, holderName))
            let item = try holder.makeFolder(itemName); made.append((holder, itemName))
            try verify()        // re-check immediately before the move
            for n in m.folderMembers {
                try rootDir.move(n, to: item, as: n)
                undo.append { try item.move(n, to: rootDir, as: n) }
            }
            let landed = try trash(root: root, holderName: holderName, holder: holder, itemName: itemName, item: item)
            rootDir.removeEmptyFolder(holderName)
            return DeleteOutcome(freed: m.exclusiveBytes, trashLocation: landed)
        } catch {
            rollback()
            throw error
        }
    }

    // MARK: Ollama

    /// An Ollama manifest must be a regular file exactly at `manifests/<host>/<namespace>/<model>/<tag>`
    /// inside the store, with no symlink anywhere on its path. Checked right before anything is moved.
    private static func verifiedManifest(_ m: CachedModel, root: String) throws -> String {
        let path = m.folder.path
        let prefix = root + "/manifests/"
        let parts = path.hasPrefix(prefix) ? String(path.dropFirst(prefix.count)).components(separatedBy: "/") : []
        guard OllamaStore.isValidManifestPath(parts) else {
            throw DeleteError.unsafe("\(m.id) is not a manifest inside the Ollama store")
        }
        guard isRealFile(path), realPath(path) == path else {
            throw DeleteError.unsafe("\(m.id)'s manifest is a symbolic link or not a file")
        }
        return path
    }

    /// An Ollama blob may only be removed if it is a regular file (not a link) named `sha256-<hex>`
    /// directly in the store's `blobs/` folder.
    private static func isRemovableOllamaBlob(_ path: String, root: String) -> Bool {
        let dir = root + "/blobs/"
        guard path.hasPrefix(dir) else { return false }
        let name = String(path.dropFirst(dir.count))
        return name.range(of: #"^sha256-[0-9a-f]{64}$"#, options: .regularExpression) != nil
            && realPath(path) == path && isRealFile(path)
    }

    /// A Trash item name from a model name: no control characters or slashes, and short enough for the file system.
    static func trashName(_ name: String, suffix: String) -> String {
        let safe = name.unicodeScalars
            .map { CharacterSet.controlCharacters.contains($0) || $0 == "/" || $0 == ":" ? "-" : String($0) }
            .joined()
        return String(safe.prefix(120)) + suffix
    }

    /// Removes an Ollama model: its manifest plus the blobs nothing else references, always as files here
    /// (never through the Ollama server, which may be running on a different store holding a byte-identical
    /// copy). Every folder on the way is opened without following links and held open, so the delete can't be
    /// redirected outside the store after the checks. The Trash path stages everything first and puts it all
    /// back if any step fails, like a Hugging Face delete.
    private static func deleteOllama(_ m: CachedModel, toTrash: Bool) throws -> DeleteOutcome {
        let root = realPath(OllamaStore.root.path)
        guard OllamaStore.isPresent(root: root) else { throw DeleteError.unsafe("the Ollama store is not a folder") }
        let manifest = try verifiedManifest(m, root: root)

        // Re-read every manifest now: a pull since the scan may have started sharing one of these blobs.
        let refs = OllamaStore.references(root: root)
        if let why = refs.incomplete.first {
            throw DeleteError.unsafe("couldn't read all of the Ollama store (\(why)), so a layer shared with another model can't be ruled out")
        }
        guard let mine = refs.manifests.first(where: { $0.path == manifest }), mine.fileDigest == m.ollamaDigest else {
            throw DeleteError.gone("\(m.id) changed since the scan; refresh and try again")
        }
        if OllamaStore.downloadInProgress(root: root) {
            throw DeleteError.locked("an Ollama download is in progress; try again when it finishes")
        }
        var elsewhere = refs.unlisted
        for o in refs.manifests where o.path != manifest { elsewhere.formUnion(o.digests) }
        // The scan's exclusive list already leaves out blobs another HF repo or Ollama model uses.
        // A layer only this manifest uses must be removable with it. Otherwise refuse: deleting the manifest alone
        // would orphan the layer (Ollama prunes it on its next start) and a Trash restore would come back broken.
        for d in mine.digests.subtracting(elsewhere) {
            let p = OllamaStore.blobPath(d, root: root)
            var st = stat()
            if lstat(p, &st) == 0 && !isRemovableOllamaBlob(p, root: root) {
                throw DeleteError.unsafe("layer sha256-\(d.prefix(12))… of \(m.name) is a link, a relocated folder or oddly named, so it can't be removed with the model")
            }
        }
        let blobNames = m.externalExclusiveFiles.map(\.path).filter {
            isRemovableOllamaBlob($0, root: root) && mine.digests.contains(String($0.suffix(64))) && !elsewhere.contains(String($0.suffix(64)))
        }.map { ($0 as NSString).lastPathComponent }

        // Open the store folder by folder: root, manifests, host, namespace, model. No links anywhere.
        let parts = String(manifest.dropFirst(root.count + 1)).components(separatedBy: "/")   // manifests/<host>/<ns>/<model>/<tag>
        guard parts.count == 5, let rootDir = DirHandle.open(root) else { throw DeleteError.unsafe("couldn't open the Ollama store") }
        var chain = [rootDir]
        for p in parts.dropLast() {
            guard let next = chain.last!.sub(p) else { throw DeleteError.unsafe("\(m.id)'s folder changed or is a symbolic link") }
            chain.append(next)
        }
        let modelDir = chain.last!, tag = parts.last!
        guard let manifestSize = modelDir.fileSize(tag) else { throw DeleteError.unsafe("\(m.id)'s manifest is a symbolic link or not a file") }
        let blobsDir = blobNames.isEmpty ? nil : rootDir.sub("blobs")
        if !blobNames.isEmpty && blobsDir == nil { throw DeleteError.unsafe("the Ollama blobs folder is a symbolic link or missing") }

        /// Removes the now-empty model, namespace and host folders, as Ollama does; never `manifests/` itself.
        func pruneManifestFolders() {
            for i in stride(from: 3, through: 1, by: -1) {
                if !chain[i].removeEmptyFolder(parts[i]) { return }
            }
        }

        if !toTrash {
            try modelDir.unlink(tag)
            var freed = manifestSize
            for b in blobNames {
                guard let size = blobsDir!.freedSize(b) else { continue }
                if (try? blobsDir!.unlink(b)) != nil { freed += size }
            }
            pruneManifestFolders()
            return DeleteOutcome(freed: freed, trashLocation: nil)
        }

        // ONE Trash item laid out like the store (manifests/… and blobs/), so restoring is two folder moves.
        let holderName = ".mcc-staging-" + UUID().uuidString
        let itemName = trashName(m.name, suffix: " (ollama model)")
        var moved: [(from: DirHandle, name: String, to: DirHandle)] = []
        var made: [(parent: DirHandle, name: String)] = []      // folders we created, removed on rollback if empty
        func makeFolder(_ parent: DirHandle, _ name: String) throws -> DirHandle {
            let d = try parent.makeFolder(name)
            made.append((parent, name))
            return d
        }
        func rollback() {
            var stranded = false
            for mv in moved.reversed() {
                do { try mv.to.move(mv.name, to: mv.from, as: mv.name) } catch { stranded = true }
            }
            for f in made.reversed() { f.parent.removeEmptyFolder(f.name) }   // only ever removes EMPTY folders
            if stranded { Store.log("Could not fully undo a failed delete of \(m.id); its files are in \(root)/\(holderName)") }
        }

        do {
            let holder = try makeFolder(rootDir, holderName)
            let item = try makeFolder(holder, itemName)
            var staged = item
            for p in parts.dropLast() { staged = try makeFolder(staged, p) }   // manifests/<host>/<ns>/<model>
            let stagedBlobs = blobNames.isEmpty ? nil : try makeFolder(item, "blobs")
            var freed: Int64 = 0
            try modelDir.move(tag, to: staged, as: tag)
            moved.append((modelDir, tag, staged))
            freed += manifestSize
            for b in blobNames {
                guard let size = blobsDir!.fileSize(b) else { continue }
                try blobsDir!.move(b, to: stagedBlobs!, as: b)
                moved.append((blobsDir!, b, stagedBlobs!))
                freed += size
            }
            let landed = try trash(root: root, holderName: holderName, holder: holder, itemName: itemName, item: item)
            rootDir.removeEmptyFolder(holderName)   // now empty; never a recursive delete
            pruneManifestFolders()
            return DeleteOutcome(freed: freed, trashLocation: landed)
        } catch {
            rollback()
            throw error
        }
    }
}
