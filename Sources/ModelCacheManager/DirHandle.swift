import Foundation
import Darwin

/// An open folder. Deletes and moves work on names relative to folders opened one level at a time with
/// O_NOFOLLOW, so a folder swapped for a symbolic link after the checks can't redirect them outside the store.
/// A name here is always a single path component: never empty, never containing "/", never "." or "..".
final class DirHandle {
    let fd: Int32

    private init(_ fd: Int32) { self.fd = fd }
    deinit { close(fd) }

    private static func isPlainName(_ name: String) -> Bool {
        !name.isEmpty && name != "." && name != ".." && !name.contains("/") && !name.contains("\0")
    }

    /// A folder by absolute path, refusing a symbolic link anywhere on the path.
    static func open(_ path: String) -> DirHandle? {
        let fd = Darwin.open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW_ANY | O_CLOEXEC)
        return fd >= 0 ? DirHandle(fd) : nil
    }

    /// The folder `name` inside this one; nil if it is missing, not a folder, or a symbolic link.
    func sub(_ name: String) -> DirHandle? {
        guard Self.isPlainName(name) else { return nil }
        let fd = openat(self.fd, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        return fd >= 0 ? DirHandle(fd) : nil
    }

    /// Size of `name` if it is a regular file (not a link) in this folder.
    func fileSize(_ name: String) -> Int64? { fileStat(name).map { Int64($0.st_size) } }

    /// What removing `name` frees: its size, or 0 if another hard link keeps the data. nil if not a regular file.
    func freedSize(_ name: String) -> Int64? { fileStat(name).map { $0.st_nlink > 1 ? 0 : Int64($0.st_size) } }

    private func fileStat(_ name: String) -> stat? {
        guard Self.isPlainName(name) else { return nil }
        var st = stat()
        guard fstatat(fd, name, &st, AT_SYMLINK_NOFOLLOW) == 0, (st.st_mode & S_IFMT) == S_IFREG else { return nil }
        return st
    }

    /// The folder at `path` (not following a final link) is still this open folder: same device and inode.
    func isStill(at path: String) -> Bool {
        var a = stat(), b = stat()
        return fstat(fd, &a) == 0 && lstat(path, &b) == 0 && a.st_dev == b.st_dev && a.st_ino == b.st_ino
    }

    /// Removes the file `name`. If it was swapped for a link, the link goes, never its target.
    func unlink(_ name: String) throws {
        guard Self.isPlainName(name), unlinkat(fd, name, 0) == 0 else { throw Self.error("remove", name) }
    }

    /// Removes the folder `name` only if it is empty (and a real folder).
    @discardableResult
    func removeEmptyFolder(_ name: String) -> Bool {
        Self.isPlainName(name) && unlinkat(fd, name, AT_REMOVEDIR) == 0
    }

    /// Creates the folder `name` (it must not exist yet) and opens it.
    func makeFolder(_ name: String) throws -> DirHandle {
        guard Self.isPlainName(name), mkdirat(fd, name, 0o700) == 0, let d = sub(name) else { throw Self.error("create", name) }
        return d
    }

    /// Moves `name` into `dest` as `newName`, never replacing anything there. A link is moved as a link.
    func move(_ name: String, to dest: DirHandle, as newName: String) throws {
        guard Self.isPlainName(name), Self.isPlainName(newName) else { throw Self.error("move", name) }
        if renameatx_np(fd, name, dest.fd, newName, UInt32(RENAME_EXCL)) == 0 { return }
        // exFAT and some network volumes don't support RENAME_EXCL: check the target is free, then a plain rename.
        guard errno == ENOTSUP || errno == EINVAL else { throw Self.error("move", name) }
        var st = stat()
        guard fstatat(dest.fd, newName, &st, AT_SYMLINK_NOFOLLOW) != 0, errno == ENOENT,
              renameat(fd, name, dest.fd, newName) == 0 else { throw Self.error("move", name) }
    }

    /// Removes `name` and everything under it without ever following a link: each folder is opened with
    /// O_NOFOLLOW from its already-open parent, and links are removed as links. Returns the bytes freed.
    @discardableResult
    func removeTree(_ name: String, depth: Int = 0) throws -> Int64 {
        guard Self.isPlainName(name) else { throw Self.error("remove", name) }
        guard depth < 64 else { throw DeleteError.unsafe("folders nested more than 64 deep under \(name)") }
        var st = stat()
        guard fstatat(fd, name, &st, AT_SYMLINK_NOFOLLOW) == 0 else {
            // Already gone: on exFAT/FAT, removing "x" also removes its "._x" metadata file listed alongside it.
            if errno == ENOENT { return 0 }
            throw Self.error("inspect", name)
        }
        guard (st.st_mode & S_IFMT) == S_IFDIR, let dir = sub(name) else {
            // A file or a link (also a folder swapped for a link since the check): remove that entry only.
            let freed = (st.st_mode & S_IFMT) == S_IFREG && st.st_nlink == 1 ? Int64(st.st_size) : 0
            if unlinkat(fd, name, 0) != 0 && errno != ENOENT { throw Self.error("remove", name) }
            return freed
        }
        var mine = stat()
        guard fstat(fd, &mine) == 0, mine.st_dev == st.st_dev else {
            throw DeleteError.unsafe("\(name) is another volume mounted inside the model; unmount it first")
        }
        var freed: Int64 = 0
        for child in try dir.names() { freed += try dir.removeTree(child, depth: depth + 1) }
        guard unlinkat(fd, name, AT_REMOVEDIR) == 0 else { throw Self.error("remove", name) }
        return freed
    }

    /// The entries of this folder (not "." or "..").
    func names() throws -> [String] {
        let copy = dup(fd)
        guard copy >= 0, let d = fdopendir(copy) else { if copy >= 0 { close(copy) }; throw Self.error("list", ".") }
        defer { closedir(d) }
        rewinddir(d)
        var out: [String] = []
        while let e = readdir(d) {
            let n = withUnsafeBytes(of: e.pointee.d_name) { raw in
                String(decoding: raw.prefix(Int(e.pointee.d_namlen)), as: UTF8.self)
            }
            if n != "." && n != ".." { out.append(n) }
        }
        return out
    }

    private static func error(_ verb: String, _ name: String) -> Error {
        DeleteError.unsafe("couldn't \(verb) \(name): \(String(cString: strerror(errno)))")
    }
}
