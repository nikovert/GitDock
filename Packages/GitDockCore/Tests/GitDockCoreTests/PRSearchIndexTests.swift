import XCTest
@testable import GitDockCore

final class PRSearchIndexTests: XCTestCase {
    func testEvictionRetainsMetadataMatchesAndCheckpointAcrossRestart() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let account = AccountCandidate(login: "alice", hostname: "github.com")
        let index = SQLitePRSearchIndex(directory: directory, maximumDiffBytes: 1, minimumFreeBytes: 0)
        try index.bind(account: account)
        let document = searchDocument(number: 1, files: [PRSearchFile(path: "file", patch: "@@ -0,0 +1 @@\n+needle", additions: 1, deletions: 0)])
        try index.save(document)
        let match = PRSearchMatcher.match(document, query: PRSearchQuery("needle"))!
        try index.retain(match, query: "needle")
        try index.saveCheckpoint(PRSearchCheckpoint(page: 2, offset: 7, startedAt: Date(timeIntervalSince1970: 123), complete: false), repository: "org/repo", query: "needle")
        let restarted = SQLitePRSearchIndex(directory: directory, maximumDiffBytes: 1, minimumFreeBytes: 0)
        try restarted.bind(account: account)
        XCTAssertEqual(try restarted.documents().count, 1)
        XCTAssertNil(try restarted.documents().first?.files)
        XCTAssertEqual(try restarted.matches(query: "needle").map(\.id), ["R_repo#1"])
        XCTAssertEqual(try restarted.checkpoint(repository: "org/repo", query: "needle")?.offset, 7)
        XCTAssertTrue(try restarted.hasEvictedHistory())
    }

    func testRevisionChangeDropsOldMatchAndRepositoryRemovalPurgesContent() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let index = SQLitePRSearchIndex(directory: directory, minimumFreeBytes: 0)
        try index.bind(account: AccountCandidate(login: "alice", hostname: "github.com"))
        var document = searchDocument(number: 1, title: "needle")
        try index.save(document)
        try index.retain(PRSearchMatcher.match(document, query: PRSearchQuery("needle"))!, query: "needle")
        document.headSHA = "new-head"
        try index.save(document)
        XCTAssertTrue(try index.matches(query: "needle").isEmpty)
        try index.remove(repository: "org/repo")
        XCTAssertTrue(try index.documents().isEmpty)
    }

    func testPrivatePermissionsAndAccountSwitchAndClearRemoveSidecars() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let index = SQLitePRSearchIndex(directory: directory, minimumFreeBytes: 0)
        try index.bind(account: AccountCandidate(login: "alice", hostname: "github.com"))
        try index.save(searchDocument(number: 1, body: "private"))
        let enumerator = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: [.isDirectoryKey])!
        for case let url as URL in enumerator {
            let mode = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as! NSNumber
            XCTAssertEqual(mode.intValue & 0o077, 0, url.lastPathComponent)
        }
        try index.bind(account: AccountCandidate(login: "bob", hostname: "github.com"))
        XCTAssertTrue(try index.documents().isEmpty)
        try index.clear()
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
    }
}
