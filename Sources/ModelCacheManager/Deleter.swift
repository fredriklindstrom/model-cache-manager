import Foundation
import Darwin

enum DeleteError: LocalizedError {
    case locked(String), unsafe(String), gone(String)
    var errorDescription: String? {
        switch self {
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
        let fm = FileManager.default
        let root = realPath(CacheScanner.cacheRoot.path)
        guard root != "/", isRealDirectory(root) else { throw DeleteError.unsafe("the cache root is not a folder") }
        let folder = try verifiedFolder(m, root: root)
        let allBlobs = m.externalExclusiveFiles.map(\.path)
        let blobs = allBlobs.filter { isRemovableBlob($0, root: root) }
        let refused = allBlobs.filter { !blobs.contains($0) }.reduce(Int64(0)) { $0 + (fileStat($1)?.size ?? 0) }
        let freed = m.exclusiveBytes - refused

        guard toTrash else {
            try fm.removeItem(atPath: folder)   // removes links inside it, never their targets
            for b in blobs where isRemovableBlob(b, root: root) { try? fm.removeItem(atPath: b) }
            return DeleteOutcome(freed: freed, trashLocation: nil)
        }

        let holder = root + "/.mcc-staging-" + UUID().uuidString
        let safeName = m.name.unicodeScalars
            .map { CharacterSet.controlCharacters.contains($0) || $0 == "/" ? "-" : String($0) }
            .joined()
        let item = holder + "/" + safeName + " (model cache)"
        let shared = item + "/shared-blobs"
        try fm.createDirectory(atPath: item, withIntermediateDirectories: true)

        var moved: [(from: String, to: String)] = []
        func rollback() {
            var stranded = false
            for mv in moved.reversed() {
                do { try fm.moveItem(atPath: mv.to, toPath: mv.from) } catch { stranded = true }
            }
            rmdir(shared); rmdir(item); rmdir(holder)   // rmdir only removes EMPTY folders
            if stranded { Store.log("Could not fully undo a failed delete of \(m.id); its files are in \(holder)") }
        }

        do {
            let dest = item + "/" + (folder as NSString).lastPathComponent
            _ = try verifiedFolder(m, root: root)        // re-check immediately before the move
            try fm.moveItem(atPath: folder, toPath: dest)
            moved.append((folder, dest))
            if !blobs.isEmpty {
                try fm.createDirectory(atPath: shared, withIntermediateDirectories: true)
                for b in blobs where isRemovableBlob(b, root: root) {   // re-checked right before each move
                    let flat = String(b.dropFirst(root.count + 1)).replacingOccurrences(of: "/", with: "_")
                    try fm.moveItem(atPath: b, toPath: shared + "/" + flat)
                    moved.append((b, shared + "/" + flat))
                }
            }
            var landed: NSURL?
            try fm.trashItem(at: URL(fileURLWithPath: item), resultingItemURL: &landed)
            rmdir(holder)   // now empty; never a recursive delete
            return DeleteOutcome(freed: freed, trashLocation: landed?.path)
        } catch {
            rollback()
            throw error
        }
    }
}
