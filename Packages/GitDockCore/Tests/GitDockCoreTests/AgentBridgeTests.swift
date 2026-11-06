import Foundation
import XCTest
@testable import GitDockCore

final class AgentBridgeTests: XCTestCase, @unchecked Sendable {
    func testOlderAppSnapshotCannotOverwriteNewerWorkerMetadata() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = AgentReviewStore(directoryURL: directory)
        let board = LocalWorkspaceStore(directoryURL: directory)
        for command in [
            #"{"op":"sync","contexts":[{"pr_url":"https://github.com/acme/widget/pull/12","account_login":"niko","head_sha":"new","updated_at":200}]}"#,
            #"{"op":"sync","contexts":[{"pr_url":"https://github.com/acme/widget/pull/12","account_login":"niko","head_sha":"old","updated_at":100}]}"#
        ] { _ = try await store.execute(Data(command.utf8), workspace: board) }
        let loaded = try await store.load()
        XCTAssertEqual(loaded.contexts["https://github.com/acme/widget/pull/12"]?.headSHA, "new")
    }

    func testReadingStateExpiresInterruptedWorkerWithoutNeedingAnotherWorker() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = AgentReviewStore(directoryURL: directory)
        _ = try await store.update { document in
            document.enabled = true; document.accountLogin = "niko"
            let context = AgentPRContext(prURL: "https://github.com/acme/widget/pull/12", accountLogin: "niko")
            let old = Date(timeIntervalSince1970: 1000)
            _ = try document.enqueue(context: context, source: "board", now: old)
            _ = document.claim(workerID: "gone", board: .empty, now: old)
        }
        let loaded = try await store.load()
        XCTAssertEqual(loaded.jobs.first?.status, .failed)
        XCTAssertTrue(loaded.jobs.first?.error.contains("interrupted") == true)
    }

    func testBridgePersistsPolicyPatchesAndDoesNotEraseManualNotes() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = AgentReviewStore(directoryURL: directory)
        let board = LocalWorkspaceStore(directoryURL: directory)
        let pr = "https://github.com/acme/widget/pull/12"
        let subject = BoardSubject.pullRequest(try PullRequestKey(url: URL(string: pr)!))
        _ = try await board.update { $0.setEntry(BoardEntry(subject: subject, tagIDs: ["blocked"], note: "Keep me")) }
        for command in [
            #"{"op":"configure","enabled":true,"account_login":"niko"}"#,
            #"{"op":"policy","scope":"pr","pr_url":"https://github.com/acme/widget/pull/12","policy":{"comments":true,"replies":true}}"#,
            #"{"op":"policy","scope":"pr","pr_url":"https://github.com/acme/widget/pull/12","policy":{"replies":null}}"#,
            #"{"op":"priority","pr_url":"https://github.com/acme/widget/pull/12","priority":"high"}"#
        ] { _ = try await store.execute(Data(command.utf8), workspace: board) }
        let loaded = try await AgentReviewStore(directoryURL: directory).load()
        XCTAssertEqual(loaded.policyOverrides[pr]?.comments, true)
        XCTAssertNil(loaded.policyOverrides[pr]?.replies)
        let savedBoard = try await board.load()
        XCTAssertEqual(savedBoard.entry(for: subject)?.note, "Keep me")
        XCTAssertEqual(savedBoard.entry(for: subject)?.tagIDs, ["blocked"])
        XCTAssertEqual(savedBoard.entry(for: subject)?.priority, .high)
        _ = try await store.execute(Data(#"{"op":"priority","pr_url":"https://github.com/acme/widget/pull/12","priority":"none"}"#.utf8), workspace: board)
        let cleared = try await board.load()
        XCTAssertNil(cleared.entry(for: subject)?.priority)
    }

    func testIndependentStoreInstancesCannotClaimTheSameJob() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let a = AgentReviewStore(directoryURL: directory)
        let b = AgentReviewStore(directoryURL: directory)
        let board = LocalWorkspaceStore(directoryURL: directory)
        _ = try await a.execute(Data(#"{"op":"configure","enabled":true,"account_login":"niko"}"#.utf8), workspace: board)
        _ = try await a.execute(Data(#"{"op":"enqueue","source":"board","context":{"pr_url":"https://github.com/acme/widget/pull/12","author_login":"niko","account_login":"niko","head_sha":"abc"}}"#.utf8), workspace: board)
        async let first = a.execute(Data(#"{"op":"claim","worker_id":"one"}"#.utf8), workspace: board)
        async let second = b.execute(Data(#"{"op":"claim","worker_id":"two"}"#.utf8), workspace: board)
        let values = try await [first, second].map { String(decoding: $0, as: UTF8.self) }
        XCTAssertEqual(values.filter { $0 == "null" }.count, 1)
        let persisted = try await a.load()
        XCTAssertEqual(persisted.jobs.filter { $0.status == .running }.count, 1)
    }
}
