import Foundation
import XCTest
@testable import GitDockCore

final class AgentReviewTests: XCTestCase {
    private let pr = "https://github.com/acme/widget/pull/12"

    private func context(author: String = "alice", humans: [String] = ["reviewer"], teams: Int = 0) -> AgentPRContext {
        AgentPRContext(prURL: pr, authorLogin: author, accountLogin: "reviewer", headSHA: "abc",
                       requestedHumans: humans, requestedTeamCount: teams, reviewersComplete: true)
    }

    func testSoleHumanRequestOutranksConfiguredAuthorButNotWithOutstandingTeam() {
        let board = LocalWorkspaceDocument.empty
        XCTAssertEqual(context().priority(in: board).rank, 3)
        XCTAssertEqual(context(teams: 1).priority(in: board).rank, 1)
        XCTAssertEqual(context(author: "colleague", humans: ["reviewer", "bob"]).priority(in: board, priorityAuthors: ["colleague"]).rank, 2)
        XCTAssertEqual(context(author: "colleague", humans: []).priority(in: board).rank, 1)
    }

    func testExplicitLowOverridesSoleReviewerAndClearingRestoresAutomatic() throws {
        var board = LocalWorkspaceDocument.empty
        let subject = BoardSubject.pullRequest(try PullRequestKey(url: URL(string: pr)!))
        board.setEntry(BoardEntry(subject: subject, priority: .low, note: "Keep this note"))
        XCTAssertEqual(context().priority(in: board).rank, 1)
        var entry = board.entry(for: subject)!
        entry.priority = nil
        board.setEntry(entry)
        XCTAssertEqual(context().priority(in: board).rank, 3)
    }

    func testDefaultsAndOtherAuthorRequiresExplicitPRFixPermission() {
        var document = AgentReviewDocument()
        XCTAssertEqual(document.effectivePolicy(for: context()).fixMode, .off)
        XCTAssertFalse(document.effectivePolicy(for: context()).comments!)
        XCTAssertTrue(document.effectivePolicy(for: context(author: "reviewer")).comments!)
        XCTAssertFalse(document.effectivePolicy(for: context(author: "reviewer")).replies!)
        document.defaultPolicy.fixMode = .all
        XCTAssertEqual(document.effectivePolicy(for: context()).fixMode, .off)
        XCTAssertEqual(document.effectivePolicy(for: context(author: "reviewer")).fixMode, .all)
        document.policyOverrides[pr] = AgentReviewPolicy(fixMode: .lowRisk, replies: true)
        XCTAssertEqual(document.effectivePolicy(for: context()).fixMode, .lowRisk)
        XCTAssertTrue(document.effectivePolicy(for: context()).replies!)
        XCTAssertFalse(document.effectivePolicy(for: context()).comments!)
    }

    func testQueueDeduplicatesActiveRequestsAndAllowsRereview() throws {
        var doc = AgentReviewDocument()
        doc.enabled = true
        doc.accountLogin = "reviewer"
        let first = try doc.enqueue(context: context(), source: "board", now: Date())
        let duplicate = try doc.enqueue(context: context(), source: "slack", now: Date())
        XCTAssertEqual(first.id, duplicate.id)
        doc.jobs[0].status = .completed
        XCTAssertNotEqual(try doc.enqueue(context: context(), source: "board", now: Date()).id, first.id)
    }

    func testExpiredWorkerIsNotReplayedAndDifferentOwnerCannotUpdate() throws {
        var doc = AgentReviewDocument()
        doc.enabled = true
        doc.accountLogin = "reviewer"
        let now = Date(timeIntervalSince1970: 1000)
        _ = try doc.enqueue(context: context(), source: "board", now: now)
        let job = try XCTUnwrap(doc.claim(workerID: "one", board: .empty, now: now))
        XCTAssertNil(doc.claim(workerID: "two", board: .empty, now: now))
        XCTAssertThrowsError(try doc.updateJob(id: job.id, workerID: "two", now: now) { $0.status = .completed })
        XCTAssertNil(doc.claim(workerID: "two", board: .empty, now: now.addingTimeInterval(181)))
        XCTAssertEqual(doc.jobs[0].status, .failed)
    }

    func testDisabledIntegrationAndMismatchedAccountRejectQueue() {
        var doc = AgentReviewDocument()
        XCTAssertThrowsError(try doc.enqueue(context: context(), source: "board", now: Date()))
        doc.enabled = true
        doc.accountLogin = "someone-else"
        XCTAssertThrowsError(try doc.enqueue(context: context(), source: "board", now: Date()))
    }

    func testReviewBecomesStaleOnlyWhenHeadChanges() throws {
        var doc = AgentReviewDocument()
        doc.enabled = true; doc.accountLogin = "reviewer"
        var job = try doc.enqueue(context: context(), source: "board", now: Date())
        job.status = .completed
        XCTAssertEqual(job.displayStatus(currentSHA: "abc"), "Completed")
        XCTAssertEqual(job.displayStatus(currentSHA: "def"), "Stale — new commits")
    }

    func testIncompleteReviewRosterDoesNotClaimYouAreBlocking() {
        var pr = context()
        pr.reviewersComplete = false
        XCTAssertEqual(pr.priority(in: .empty).rank, 1)
    }

    func testExplicitRerequestAfterWorkerExpiryCreatesNewJob() throws {
        var doc = AgentReviewDocument()
        doc.enabled = true; doc.accountLogin = "reviewer"
        let now = Date(timeIntervalSince1970: 1000)
        let original = try doc.enqueue(context: context(), source: "board", now: now)
        _ = doc.claim(workerID: "gone", board: .empty, now: now)
        let requested = try doc.enqueue(context: context(), source: "board", now: now.addingTimeInterval(181))
        XCTAssertNotEqual(requested.id, original.id)
        XCTAssertEqual(doc.jobs[0].status, .failed)
        XCTAssertEqual(requested.status, .queued)
    }

    func testPRPolicyOverridesStackWithoutGrantingOtherAuthorFixesFromStack() {
        var doc = AgentReviewDocument()
        var pr = context()
        pr.stackURL = "https://github.com/acme/widget/pull/1"
        doc.policyOverrides["stack:" + pr.stackURL!] = AgentReviewPolicy(fixMode: .all, comments: true, replies: true)
        XCTAssertEqual(doc.effectivePolicy(for: pr).fixMode, .off)
        XCTAssertEqual(doc.effectivePolicy(for: pr).comments, true)
        doc.policyOverrides[pr.prURL] = AgentReviewPolicy(comments: false)
        XCTAssertEqual(doc.effectivePolicy(for: pr).comments, false)
        XCTAssertEqual(doc.effectivePolicy(for: pr).replies, true)
    }
}
