import Foundation
import XCTest
@testable import GitDockCore

final class ReviewAgentTests: XCTestCase, @unchecked Sendable {
    func testOldDocumentRetainsQueueAndPoliciesWithoutInstallingAConnection() throws {
        let data = Data("""
        {"schema_version":1,"enabled":true,"account_login":"reviewer",
         "default_policy":{"comments":false},
         "policy_overrides":{"https://github.com/acme/widget/pull/1":{"fix_mode":"low_risk"}},
         "contexts":{},"jobs":[{"id":"old-job","context":{
           "pr_url":"https://github.com/acme/widget/pull/1","account_login":"reviewer"},
           "source":"board","requested_at":1000,"updated_at":1000,"status":"queued",
           "summary":"Keep result","error":"","head_sha":"old-head","focuses":[],
           "instructions":"Keep instructions"}]}
        """.utf8)
        let document = try AgentReviewStore.decoder.decode(AgentReviewDocument.self, from: data)
        XCTAssertTrue(document.enabled)
        XCTAssertEqual(document.defaultPolicy.comments, false)
        XCTAssertEqual(document.jobs.first?.id, "old-job")
        XCTAssertEqual(document.jobs.first?.instructions, "Keep instructions")
        XCTAssertEqual(document.policyOverrides["https://github.com/acme/widget/pull/1"]?.fixMode, .lowRisk)
        XCTAssertNil(document.reviewAgentConnection)
        XCTAssertEqual(document.priorityAuthors, [])
        XCTAssertEqual(try AgentReviewStore.decoder.decode(AgentReviewDocument.self,
            from: AgentReviewStore.encoder.encode(document)), document)
    }

    func testPriorityAuthorsAreExplicitAndManualAndSoleReviewerStillWin() throws {
        var context = AgentPRContext(prURL: "https://github.com/acme/widget/pull/1",
                                     authorLogin: "COLLEAGUE", accountLogin: "reviewer")
        XCTAssertEqual(context.priority(in: .empty).rank, 1)
        XCTAssertEqual(context.priority(in: .empty, priorityAuthors: ["colleague"]).rank, 2)
        context.requestedHumans = ["reviewer"]
        context.reviewersComplete = true
        XCTAssertEqual(context.priority(in: .empty, priorityAuthors: ["colleague"]).rank, 3)
        var board = LocalWorkspaceDocument.empty
        let subject = BoardSubject.pullRequest(try PullRequestKey(url: URL(string: context.prURL)!))
        board.setEntry(BoardEntry(subject: subject, priority: .low))
        XCTAssertEqual(context.priority(in: board, priorityAuthors: ["colleague"]).rank, 1)
    }

    func testArgumentsRemainLiteralAndInvalidJSONIsNotTreatedAsLines() throws {
        XCTAssertEqual(try ReviewAgentConnection.parseArguments(#"["a b","$(touch nope)",";",""]"#),
                       ["a b", "$(touch nope)", ";", ""])
        XCTAssertEqual(try ReviewAgentConnection.parseArguments("a b\n$(touch nope)\n;\n"),
                       ["a b", "$(touch nope)", ";"])
        XCTAssertThrowsError(try ReviewAgentConnection.parseArguments("[not json]"))
        XCTAssertThrowsError(try ReviewAgentConnection.parseArguments("[1]"))
        XCTAssertThrowsError(try ReviewAgentConnection.parseArguments("a\0b"))
    }

    func testInvalidManagedConfigurationAndExternalMode() throws {
        var connection = ReviewAgentConnection()
        XCTAssertNoThrow(try connection.validated())
        connection.mode = .managed
        XCTAssertThrowsError(try connection.validated())
        connection.executable = "relative/worker"
        XCTAssertThrowsError(try connection.validated())
        connection.executable = "/usr/bin/true"
        connection.workingDirectory = "/private/tmp"
        XCTAssertNoThrow(try connection.validated())
        connection.arguments = ["bad\0argument"]
        XCTAssertThrowsError(try connection.validated())
    }

    func testSavingConnectionPreservesJobsAndRejectsInvalidPriorityAuthors() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = AgentReviewStore(directoryURL: directory)
        _ = try await store.update { document in
            document.enabled = true
            document.accountLogin = "reviewer"
            _ = try document.enqueue(context: AgentPRContext(
                prURL: "https://github.com/acme/widget/pull/1", accountLogin: "reviewer"),
                source: "board", now: .now)
        }
        let saved = try await store.saveConnection(ReviewAgentConnection(), priorityAuthors: ["Colleague"])
        XCTAssertEqual(saved.jobs.count, 1)
        XCTAssertEqual(saved.priorityAuthors, ["colleague"])
        do {
            _ = try await store.saveConnection(ReviewAgentConnection(), priorityAuthors: ["bad/login"])
            XCTFail("Invalid author was accepted")
        } catch {}
        let loaded = try await store.load()
        XCTAssertEqual(loaded, saved)
    }

    func testBridgeConfiguredAuthorsAffectPresentationAndClaimOrdering() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = AgentReviewStore(directoryURL: directory)
        let board = LocalWorkspaceStore(directoryURL: directory)
        _ = try await store.execute(Data(#"{"op":"configure","account_login":"reviewer","enabled":true,"priority_authors":["COLLEAGUE"]}"#.utf8), workspace: board)
        _ = try await store.update { document in
            _ = try document.enqueue(context: AgentPRContext(prURL: "https://github.com/acme/widget/pull/1",
                authorLogin: "other", accountLogin: "reviewer"), source: "board", now: Date(timeIntervalSince1970: 1000))
            _ = try document.enqueue(context: AgentPRContext(prURL: "https://github.com/acme/widget/pull/2",
                authorLogin: "colleague", accountLogin: "reviewer"), source: "board", now: Date(timeIntervalSince1970: 2000))
        }
        let output = try await store.execute(Data(#"{"op":"show"}"#.utf8), workspace: board)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: output) as? [String: Any])
        let contexts = try XCTUnwrap(json["contexts"] as? [String: [String: Any]])
        XCTAssertEqual(contexts["https://github.com/acme/widget/pull/2"]?["priority_rank"] as? Int, 2)
        let claimed = try await store.execute(Data(#"{"op":"claim","worker_id":"test"}"#.utf8), workspace: board)
        let job = try AgentReviewStore.decoder.decode(AgentReviewJob.self, from: claimed)
        XCTAssertEqual(job.context.prURL, "https://github.com/acme/widget/pull/2")
    }
}
