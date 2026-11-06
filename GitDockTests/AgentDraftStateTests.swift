import Foundation
import GitDockCore
import XCTest
@testable import GitDock

@MainActor
final class AgentDraftStateTests: XCTestCase {
    func testLegacyReceiptDoesNotClaimWholePRCoverage() throws {
        let data = Data(#"{"id":"00000000-0000-0000-0000-000000000001","provider":"Codex","completedAt":0,"summary":"No findings","findingCount":0,"contextIncomplete":false}"#.utf8)
        let receipt = try JSONDecoder().decode(WorkspaceAgentReviewReceipt.self, from: data)
        XCTAssertNil(receipt.coverage)
        XCTAssertTrue(receipt.coverageLabel.contains("coverage unavailable"))
        XCTAssertTrue(receipt.coverageLabel.contains("Excerpt"))
    }

    func testCoverageAndSkippedReasonsSurviveRestart() throws {
        let receipt = WorkspaceAgentReviewReceipt(id: UUID(), provider: "Claude", completedAt: .now,
            summary: "One file could not be inspected", findingCount: 0, contextIncomplete: true,
            coverage: ReviewCoverage(reviewedPaths: ["a.swift"], unreviewed: [ReviewUnreviewedFile(path: "b.bin", reason: "Binary baseline unavailable")], testsRun: [], limitations: []),
            changedFileCount: 2, mergeBaseSHA: "base", sourceNotices: ["Discussion unavailable"])
        let restored = try JSONDecoder().decode(WorkspaceAgentReviewReceipt.self, from: JSONEncoder().encode(receipt))
        XCTAssertEqual(restored, receipt)
        XCTAssertTrue(restored.coverageLabel.contains("1/2"))
        XCTAssertTrue(restored.coverageLabel.contains("Partial"))
    }

    func testLegacyDraftDecodesWithNoGeneralCommentsAndKeepsUserContent() throws {
        let data = Data(#"{"body":"My summary","comments":[],"viewedFiles":["file.swift"],"messages":[]}"#.utf8)
        let value = try JSONDecoder().decode(WorkspaceReviewDraft.self, from: data)
        XCTAssertEqual(value.body, "My summary")
        XCTAssertEqual(value.viewedFiles, ["file.swift"])
        XCTAssertTrue(value.generalComments.isEmpty)
        XCTAssertNil(value.lastAgentReview)
    }

    func testGeneralAndInlineDraftsRetainAgentProvenanceAcrossRestart() throws {
        let suite = "AgentDraftState-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let identity = ReviewIdentity(account: "alice", prURL: "https://github.com/acme/app/pull/1", headSHA: "head", baseSHA: "base")
        let run = UUID()
        var draft = WorkspaceReviewDraft()
        draft.generalComments = [WorkspaceGeneralDraft(body: "Add recovery coverage", agentName: "Codex", reviewRunID: run)]
        draft.comments = [WorkspaceInlineDraft(path: "file.swift", line: 1, side: "LEFT", body: "Handle nil", agentName: "Codex", reviewRunID: run)]
        let store = ReviewWorkspaceState(defaults: defaults)
        XCTAssertTrue(store.save(draft, for: identity))
        let reopened = ReviewWorkspaceState(defaults: defaults).draft(for: identity)
        XCTAssertEqual(reopened.generalComments, draft.generalComments)
        XCTAssertEqual(reopened.comments, draft.comments)
        XCTAssertTrue(reopened.hasUnsubmittedComments)
        XCTAssertEqual(reopened.allDraftCount, 2)
    }

    func testBatchBodyCombinesUserSummaryAndGeneralDraftsWithoutChangingThem() {
        var draft = WorkspaceReviewDraft()
        draft.body = "My summary"
        draft.generalComments = [WorkspaceGeneralDraft(body: "First finding"), WorkspaceGeneralDraft(body: "Second finding")]
        XCTAssertEqual(draft.publicationBody, "My summary\n\n---\n\nFirst finding\n\n---\n\nSecond finding")
        XCTAssertEqual(draft.body, "My summary")
        XCTAssertEqual(draft.generalComments.map(\.body), ["First finding", "Second finding"])
    }
}
