import Foundation

enum DeleteError: LocalizedError {
    case locked(String), outsideCache(String)
    var errorDescription: String? {
        switch self {
        case .locked(let r): return "Not deleted: \(r)"
        case .outsideCache(let p): return "Refused: \(p) is outside the model cache"
        }
    }
}

enum Deleter {
    /// Removes a model folder plus the shared-store blobs only it uses.
    /// To Trash: everything lands as ONE Trash item named after the model.
    @discardableResult
    static func delete(_ m: CachedModel, toTrash: Bool) throws -> Int64 {
        if let r = m.inUseReason { throw DeleteError.locked(r) }
        let fm = FileManager.default
        let root = URL(fileURLWithPath: realPath(CacheScanner.cacheRoot.path))
        let rootPrefix = root.path + "/"
        guard m.folder.path.hasPrefix(rootPrefix) else { throw DeleteError.outsideCache(m.folder.path) }
        let blobs = m.externalExclusiveFiles.filter { $0.path.hasPrefix(rootPrefix) }

        if toTrash {
            let holder = root.appendingPathComponent(".mcc-staging-\(UUID().uuidString)")
            let item = holder.appendingPathComponent("\(m.name.replacingOccurrences(of: "/", with: " - ")) (model cache)")
            try fm.createDirectory(at: item, withIntermediateDirectories: true)
            defer { try? fm.removeItem(at: holder) }
            try fm.moveItem(at: m.folder, to: item.appendingPathComponent(m.folder.lastPathComponent))
            if !blobs.isEmpty {
                let shared = item.appendingPathComponent("shared-blobs")
                try fm.createDirectory(at: shared, withIntermediateDirectories: true)
                for b in blobs {
                    let flat = String(b.path.dropFirst(rootPrefix.count)).replacingOccurrences(of: "/", with: "_")
                    try fm.moveItem(at: b, to: shared.appendingPathComponent(flat))
                }
            }
            try fm.trashItem(at: item, resultingItemURL: nil)
        } else {
            try fm.removeItem(at: m.folder)
            for b in blobs { try? fm.removeItem(at: b) }
        }
        return m.exclusiveBytes
    }
}
