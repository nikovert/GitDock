import Darwin
import Foundation

public enum LocalWorkspaceStoreError: Error, LocalizedError, Sendable {
    case corrupt
    case incompatibleVersion
    case lockUnavailable

    public var errorDescription: String? {
        switch self {
        case .corrupt:
            "Local workspace data is invalid. Back up workspace.json before repairing it."
        case .incompatibleVersion:
            "This workspace file uses an unsupported format. Update GitDock or restore a compatible backup."
        case .lockUnavailable:
            "Could not lock the local workspace. Check its folder permissions and try again."
        }
    }
}

public actor LocalWorkspaceStore {
    private let directoryURL: URL
    private let fileManager: FileManager

    public init(directoryURL: URL? = nil, fileManager: FileManager = .default) {
        self.fileManager = fileManager
        if let directoryURL {
            self.directoryURL = directoryURL
        } else {
            let support = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            // Preserve the pre-rename data directory for existing installations.
            self.directoryURL = support.appendingPathComponent("GitHubBar", isDirectory: true)
        }
    }

    public func load() throws -> LocalWorkspaceDocument {
        try withLock { try readUnlocked() }
    }

    public func save(_ document: LocalWorkspaceDocument) throws {
        try withLock { try writeUnlocked(document) }
    }

    @discardableResult
    public func update(_ transform: @Sendable (inout LocalWorkspaceDocument) throws -> Void) throws -> LocalWorkspaceDocument {
        try withLock {
            var document = try readUnlocked()
            try transform(&document)
            try writeUnlocked(document)
            return document
        }
    }

    private func readUnlocked() throws -> LocalWorkspaceDocument {
        let file = directoryURL.appendingPathComponent("workspace.json")
        guard fileManager.fileExists(atPath: file.path) else { return .empty }
        let data = try Data(contentsOf: file)
        guard let document = try? JSONDecoder().decode(LocalWorkspaceDocument.self, from: data) else {
            throw LocalWorkspaceStoreError.corrupt
        }
        guard document.schemaVersion == LocalWorkspaceDocument.currentSchemaVersion else {
            throw LocalWorkspaceStoreError.incompatibleVersion
        }
        return document
    }

    private func writeUnlocked(_ document: LocalWorkspaceDocument) throws {
        guard document.schemaVersion == LocalWorkspaceDocument.currentSchemaVersion else {
            throw LocalWorkspaceStoreError.incompatibleVersion
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(document)
        let file = directoryURL.appendingPathComponent("workspace.json")
        try data.write(to: file, options: .atomic)
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }

    private func withLock<T>(_ body: () throws -> T) throws -> T {
        try fileManager.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directoryURL.path)
        let lockPath = directoryURL.appendingPathComponent("workspace.lock").path
        let descriptor = Darwin.open(lockPath, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw LocalWorkspaceStoreError.lockUnavailable }
        defer { Darwin.close(descriptor) }
        guard flock(descriptor, LOCK_EX) == 0 else { throw LocalWorkspaceStoreError.lockUnavailable }
        defer { flock(descriptor, LOCK_UN) }
        return try body()
    }
}
