import Foundation
import SQLite3

public struct PRSearchCheckpoint: Codable, Equatable, Sendable {
    public var page: Int
    public var offset: Int
    public var startedAt: Date
    public var complete: Bool
    public init(page: Int = 1, offset: Int = 0, startedAt: Date = Date(), complete: Bool = false) {
        self.page = page; self.offset = offset; self.startedAt = startedAt; self.complete = complete
    }
}

/// Synchronous operations keep persistence inside the engine's generation boundary.
public protocol PRSearchIndex: Sendable {
    func bind(account: AccountCandidate) throws
    func documents() throws -> [PRSearchDocument]
    func document(id: String) throws -> PRSearchDocument?
    func coverage(repository: String) throws -> [String: PRSearchCoverage]
    func save(_ document: PRSearchDocument) throws
    func retain(_ result: PRSearchResult, query: String) throws
    func matches(query: String) throws -> [PRSearchResult]
    func checkpoint(repository: String, query: String) throws -> PRSearchCheckpoint?
    func saveCheckpoint(_ checkpoint: PRSearchCheckpoint, repository: String, query: String) throws
    func submittedQuery() throws -> String?
    func saveSubmittedQuery(_ query: String) throws
    func hasEvictedHistory() throws -> Bool
    func remove(repository: String) throws
    func clear() throws
}

public enum PRSearchIndexError: Error, Sendable { case unavailable, lowDiskSpace }

/// All SQLite access, including close/unlink, is serialized by this lock.
public final class SQLitePRSearchIndex: PRSearchIndex, @unchecked Sendable {
    private let lock = NSRecursiveLock()
    private let directory: URL
    private let maximumDiffBytes: Int
    private let minimumFreeBytes: Int64
    private var db: OpaquePointer?
    private var accountID: String?
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    public init(directory: URL? = nil, maximumDiffBytes: Int = 1_073_741_824,
                minimumFreeBytes: Int64 = 128 * 1_024 * 1_024) {
        self.directory = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            // Preserve the pre-rename data directory for existing installations.
            .appendingPathComponent("GitHubBar/PRSearch", isDirectory: true)
        self.maximumDiffBytes = min(max(0, maximumDiffBytes), 1_073_741_824)
        self.minimumFreeBytes = minimumFreeBytes
    }

    deinit { if let db { sqlite3_close(db) } }

    public func bind(account: AccountCandidate) throws {
        try locked {
            let identity = account.id.lowercased()
            if accountID == identity, db != nil { return }
            if let db { sqlite3_close(db); self.db = nil }
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
            var excluded = directory
            var values = URLResourceValues(); values.isExcludedFromBackup = true
            try excluded.setResourceValues(values)
            let component = identity.utf8.map { String(format: "%02x", $0) }.joined()
            let accountDirectory = directory.appendingPathComponent(component, isDirectory: true)
            for old in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
                where old.lastPathComponent != component {
                try FileManager.default.removeItem(at: old)
            }
            try FileManager.default.createDirectory(at: accountDirectory, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            let file = accountDirectory.appendingPathComponent("search.sqlite")
            if !FileManager.default.fileExists(atPath: file.path) {
                guard FileManager.default.createFile(atPath: file.path, contents: nil,
                                                     attributes: [.posixPermissions: 0o600]) else {
                    throw PRSearchIndexError.unavailable
                }
            }
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
            guard sqlite3_open_v2(file.path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
                throw PRSearchIndexError.unavailable
            }
            accountID = identity
            sqlite3_busy_timeout(db, 5_000)
            try execute("PRAGMA journal_mode=WAL")
            try execute("PRAGMA secure_delete=ON")
            try execute("CREATE TABLE IF NOT EXISTS documents (id TEXT PRIMARY KEY, repo TEXT NOT NULL, metadata BLOB NOT NULL, diff BLOB, bytes INTEGER NOT NULL, touched REAL NOT NULL)")
            try execute("CREATE TABLE IF NOT EXISTS matches (id TEXT NOT NULL, query TEXT NOT NULL, value BLOB NOT NULL, PRIMARY KEY(id,query))")
            try execute("CREATE TABLE IF NOT EXISTS checkpoints (repo TEXT NOT NULL, query TEXT NOT NULL, value BLOB NOT NULL, PRIMARY KEY(repo,query))")
            try execute("CREATE TABLE IF NOT EXISTS settings (name TEXT PRIMARY KEY, value TEXT NOT NULL)")
            try protectFiles()
        }
    }

    public func documents() throws -> [PRSearchDocument] {
        try locked { try rows("SELECT metadata,diff FROM documents ORDER BY id").map(decodeDocument) }
    }

    public func document(id: String) throws -> PRSearchDocument? {
        try locked { try rows("SELECT metadata,diff FROM documents WHERE id=?", [Data(id.utf8)]).first.map(decodeDocument) }
    }

    public func coverage(repository: String) throws -> [String: PRSearchCoverage] {
        try locked {
            let metadata = try rows("SELECT metadata FROM documents WHERE repo=?", [Data(repository.lowercased().utf8)])
            return try Dictionary(uniqueKeysWithValues: metadata.map { row in
                let document = try decoder.decode(PRSearchDocument.self, from: row[0] ?? Data())
                return (document.id, document.coverage)
            })
        }
    }

    public func save(_ document: PRSearchDocument) throws {
        try locked {
            try checkSpace()
            let previous = try self.document(id: document.id)
            var metadata = document; metadata.files = nil
            let files = try document.files.map { try encoder.encode($0) }
            try execute("BEGIN IMMEDIATE")
            do {
                if let previous, previous.headSHA != document.headSHA || previous.baseSHA != document.baseSHA
                    || previous.pullRequest.updatedAt != document.pullRequest.updatedAt {
                    try execute("DELETE FROM matches WHERE id=?", [Data(document.id.utf8)])
                }
                try execute("INSERT OR REPLACE INTO documents VALUES (?,?,?,?,?,?)", [
                    Data(document.id.utf8), Data(document.pullRequest.repositoryNameWithOwner.lowercased().utf8),
                    try encoder.encode(metadata), files,
                    Data(String(files?.count ?? 0).utf8), Data(String(document.refreshedAt.timeIntervalSince1970).utf8)
                ])
                var total = try scalar("SELECT COALESCE(SUM(bytes),0) FROM documents")
                while total > maximumDiffBytes {
                    guard let oldest = try rows("SELECT id,bytes FROM documents WHERE diff IS NOT NULL ORDER BY touched,id LIMIT 1").first else { break }
                    try execute("UPDATE documents SET diff=NULL,bytes=0 WHERE id=?", [oldest[0]])
                    total -= Int(String(decoding: oldest[1] ?? Data(), as: UTF8.self)) ?? 0
                }
                try execute("COMMIT")
            } catch { try? execute("ROLLBACK"); throw error }
            try protectFiles()
        }
    }

    public func retain(_ result: PRSearchResult, query: String) throws {
        try locked {
            try checkSpace()
            try execute("INSERT OR REPLACE INTO matches VALUES (?,?,?)", [Data(result.id.utf8), Data(query.utf8), try encoder.encode(result)])
            try protectFiles()
        }
    }

    public func matches(query: String) throws -> [PRSearchResult] {
        try locked {
            try rows("SELECT value FROM matches WHERE query=? ORDER BY id", [Data(query.utf8)])
                .map { try decoder.decode(PRSearchResult.self, from: $0[0] ?? Data()) }
        }
    }

    public func checkpoint(repository: String, query: String) throws -> PRSearchCheckpoint? {
        try locked {
            try rows("SELECT value FROM checkpoints WHERE repo=? AND query=?", [Data(repository.lowercased().utf8), Data(query.utf8)]).first
                .map { try decoder.decode(PRSearchCheckpoint.self, from: $0[0] ?? Data()) }
        }
    }

    public func saveCheckpoint(_ checkpoint: PRSearchCheckpoint, repository: String, query: String) throws {
        try locked {
            try checkSpace()
            try execute("INSERT OR REPLACE INTO checkpoints VALUES (?,?,?)", [Data(repository.lowercased().utf8), Data(query.utf8), try encoder.encode(checkpoint)])
            try protectFiles()
        }
    }

    public func hasEvictedHistory() throws -> Bool {
        try locked { try scalar("SELECT COUNT(*) FROM documents WHERE diff IS NULL") > 0 }
    }

    public func submittedQuery() throws -> String? {
        try locked {
            try rows("SELECT value FROM settings WHERE name='query'").first
                .map { String(decoding: $0[0] ?? Data(), as: UTF8.self) }
        }
    }

    public func saveSubmittedQuery(_ query: String) throws {
        try locked {
            try checkSpace()
            try execute("INSERT OR REPLACE INTO settings VALUES ('query',?)", [Data(query.utf8)])
            try protectFiles()
        }
    }

    public func remove(repository: String) throws {
        try locked {
            let repo = Data(repository.lowercased().utf8)
            try execute("DELETE FROM matches WHERE id IN (SELECT id FROM documents WHERE repo=?)", [repo])
            try execute("DELETE FROM documents WHERE repo=?", [repo])
            try execute("DELETE FROM checkpoints WHERE repo=?", [repo])
            try execute("PRAGMA wal_checkpoint(TRUNCATE)")
        }
    }

    public func clear() throws {
        try locked {
            if let db { sqlite3_close(db); self.db = nil }
            accountID = nil
            if FileManager.default.fileExists(atPath: directory.path) { try FileManager.default.removeItem(at: directory) }
        }
    }

    private func decodeDocument(_ row: [Data?]) throws -> PRSearchDocument {
        var document = try decoder.decode(PRSearchDocument.self, from: row[0] ?? Data())
        if let files = row[1] { document.files = try decoder.decode([PRSearchFile].self, from: files) }
        return document
    }

    private func locked<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock(); defer { lock.unlock() }; return try body()
    }

    private func checkSpace() throws {
        let values = try directory.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        if let available = values.volumeAvailableCapacityForImportantUsage, available < minimumFreeBytes {
            throw PRSearchIndexError.lowDiskSpace
        }
    }

    private func protectFiles() throws {
        guard let enumerator = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: [.isDirectoryKey]) else { return }
        for case let url as URL in enumerator {
            let isDirectory = try url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true
            try FileManager.default.setAttributes([.posixPermissions: isDirectory ? 0o700 : 0o600], ofItemAtPath: url.path)
        }
    }

    private func scalar(_ sql: String) throws -> Int {
        let value = try rows(sql).first?.first ?? nil
        return Int(String(decoding: value ?? Data(), as: UTF8.self)) ?? 0
    }

    private func execute(_ sql: String, _ bindings: [Data?] = []) throws { _ = try rows(sql, bindings) }

    private func rows(_ sql: String, _ bindings: [Data?] = []) throws -> [[Data?]] {
        guard let db else { throw PRSearchIndexError.unavailable }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { throw PRSearchIndexError.unavailable }
        defer { sqlite3_finalize(statement) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (index, value) in bindings.enumerated() {
            if let value {
                _ = value.withUnsafeBytes { sqlite3_bind_text(statement, Int32(index + 1), $0.baseAddress?.assumingMemoryBound(to: CChar.self), Int32(value.count), transient) }
            } else { sqlite3_bind_null(statement, Int32(index + 1)) }
        }
        var result: [[Data?]] = []
        while true {
            let status = sqlite3_step(statement)
            if status == SQLITE_DONE { return result }
            guard status == SQLITE_ROW else {
                throw status == SQLITE_FULL ? PRSearchIndexError.lowDiskSpace : PRSearchIndexError.unavailable
            }
            result.append((0..<sqlite3_column_count(statement)).map { column in
                guard sqlite3_column_type(statement, column) != SQLITE_NULL else { return nil }
                return Data(bytes: sqlite3_column_blob(statement, column), count: Int(sqlite3_column_bytes(statement, column)))
            })
        }
    }
}
