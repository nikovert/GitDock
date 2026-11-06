import CryptoKit
import Darwin
import Foundation

/// Attests filesystem bytes against original Git blobs, independently of filters and index/stat caches.
/// Symlinks are read as links; traversal never descends through a symlink into another tree.
struct WorktreeCleanupContent {
    private struct Entry { let mode: String; let oid: String }
    private static let maximumEntries = 200_000
    private static let maximumFileBytes = 512 * 1_024 * 1_024
    private static let maximumTotalBytes = 2 * 1_024 * 1_024 * 1_024

    static func verify(path root: String, rawTree: String) throws {
        guard rawTree.utf8.count <= 64 * 1_024 * 1_024,
              rawTree.isEmpty || rawTree.hasSuffix("\0") else { throw blocked("Git tree exceeds its verification limit or is incomplete.") }
        var expected: [String: Entry] = [:]
        var directories = Set<String>()
        for record in rawTree.split(separator: "\0") {
            try Task.checkCancellation()
            guard expected.count < maximumEntries, let separator = record.firstIndex(of: "\t") else {
                throw blocked("Git tree exceeds its verification limit or is malformed.")
            }
            let fields = record[..<separator].split(separator: " ").map(String.init)
            let name = String(record[record.index(after: separator)...])
            let components = name.split(separator: "/", omittingEmptySubsequences: false)
            guard fields.count == 3, fields[1] == "blob", ["100644", "100755", "120000"].contains(fields[0]),
                  fields[2].count == 40, fields[2].allSatisfy(\.isHexDigit), !name.contains("\u{FFFD}"),
                  components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." && $0.lowercased() != ".git" }),
                  expected[name] == nil else { throw blocked("Unsupported tracked file, submodule, or ambiguous Git path.") }
            expected[name] = Entry(mode: fields[0], oid: fields[2])
            for count in 1..<components.count { directories.insert(components.prefix(count).joined(separator: "/")) }
        }
        var seen = Set<String>()
        var pending = [""]
        var totalBytes = 0
        var count = 0
        while let relative = pending.popLast() {
            try Task.checkCancellation()
            let parent = relative.isEmpty ? root : root + "/" + relative
            for name in try FileManager.default.contentsOfDirectory(atPath: parent) {
                if relative.isEmpty && name == ".git" { continue }
                count += 1
                guard count <= maximumEntries else { throw blocked("Worktree exceeds the 200,000-entry verification limit.") }
                let path = relative.isEmpty ? name : relative + "/" + name
                let absolute = root + "/" + path
                var info = stat()
                guard lstat(absolute, &info) == 0, info.st_uid == getuid() else {
                    throw blocked("Worktree ownership or contents changed during verification.")
                }
                if info.st_mode & S_IFMT == S_IFDIR {
                    guard directories.contains(path) else { throw blocked("An extra local directory must be preserved.") }
                    pending.append(path)
                    continue
                }
                guard let entry = expected[path], seen.insert(path).inserted else {
                    throw blocked("Untracked or ignored local contents must be preserved.")
                }
                let oid: String
                if entry.mode == "120000" {
                    guard info.st_mode & S_IFMT == S_IFLNK else { throw blocked("A tracked symlink's local type changed.") }
                    var target = [UInt8](repeating: 0, count: 16 * 1_024)
                    let bytes = readlink(absolute, &target, target.count)
                    guard bytes >= 0, bytes < target.count, totalBytes <= maximumTotalBytes - bytes else {
                        throw blocked("A symlink or worktree exceeds its verification limit.")
                    }
                    totalBytes += bytes
                    oid = blobOID(Data(target.prefix(bytes)))
                    var after = stat()
                    guard lstat(absolute, &after) == 0, unchanged(info, after) else { throw blocked("A symlink changed during verification.") }
                } else {
                    guard info.st_mode & S_IFMT == S_IFREG,
                          info.st_mode & 0o111 == (entry.mode == "100755" ? 0o111 : 0) else {
                        throw blocked("A tracked file's local type or executable mode changed.")
                    }
                    oid = try regularBlobOID(absolute, info: info, totalBytes: &totalBytes)
                }
                guard oid == entry.oid else { throw blocked("Actual tracked bytes differ from the original Git HEAD; local contents must be preserved.") }
            }
        }
        guard seen.count == expected.count else { throw blocked("Tracked files are missing or changed.") }
    }

    private static func regularBlobOID(_ path: String, info: stat, totalBytes: inout Int) throws -> String {
        guard info.st_size >= 0, info.st_size <= maximumFileBytes else { throw blocked("A file exceeds the 512 MiB verification limit.") }
        let descriptor = open(path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard descriptor >= 0 else { throw blocked("A tracked file could not be opened safely.") }
        defer { close(descriptor) }
        var opened = stat()
        guard fstat(descriptor, &opened) == 0, unchanged(info, opened) else { throw blocked("A tracked file changed before verification.") }
        var hasher = Insecure.SHA1()
        hasher.update(data: Data("blob \(info.st_size)\0".utf8))
        var buffer = [UInt8](repeating: 0, count: 64 * 1_024)
        var readBytes = 0
        while true {
            try Task.checkCancellation()
            let bytes = Darwin.read(descriptor, &buffer, buffer.count)
            if bytes == 0 { break }
            if bytes < 0 && errno == EINTR { continue }
            guard bytes > 0, totalBytes <= maximumTotalBytes - bytes,
                  readBytes <= maximumFileBytes - bytes else { throw blocked("Worktree exceeds its 2 GiB verification limit.") }
            totalBytes += bytes
            readBytes += bytes
            hasher.update(data: Data(buffer.prefix(bytes)))
        }
        var after = stat()
        var atPath = stat()
        guard readBytes == info.st_size, fstat(descriptor, &after) == 0, unchanged(opened, after),
              lstat(path, &atPath) == 0, unchanged(after, atPath) else { throw blocked("A tracked file changed during verification.") }
        return hex(hasher.finalize())
    }

    private static func blobOID(_ bytes: Data) -> String {
        var hasher = Insecure.SHA1()
        hasher.update(data: Data("blob \(bytes.count)\0".utf8))
        hasher.update(data: bytes)
        return hex(hasher.finalize())
    }

    private static func hex(_ digest: Insecure.SHA1.Digest) -> String { digest.map { String(format: "%02x", $0) }.joined() }

    private static func unchanged(_ lhs: stat, _ rhs: stat) -> Bool {
        lhs.st_dev == rhs.st_dev && lhs.st_ino == rhs.st_ino && lhs.st_mode == rhs.st_mode && lhs.st_uid == rhs.st_uid &&
            lhs.st_size == rhs.st_size && lhs.st_mtimespec.tv_sec == rhs.st_mtimespec.tv_sec &&
            lhs.st_mtimespec.tv_nsec == rhs.st_mtimespec.tv_nsec && lhs.st_ctimespec.tv_sec == rhs.st_ctimespec.tv_sec &&
            lhs.st_ctimespec.tv_nsec == rhs.st_ctimespec.tv_nsec
    }

    private static func blocked(_ message: String) -> CleanupBlocked { CleanupBlocked(message) }
}
