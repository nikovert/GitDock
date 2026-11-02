import GitHubBarCore
import XCTest
@testable import GitHubBar

final class ReviewPublicationPlanTests: XCTestCase {
    func testGeneralDraftPublicationPreservesUnavailableOriginalLocation() {
        let draft = WorkspaceGeneralDraft(body: "Handle the fallback", anchorDescription: "old.swift:70 · LEFT — no current diff anchor")
        XCTAssertTrue(draft.publicationBody.contains("old.swift:70"))
        XCTAssertTrue(draft.publicationBody.contains("Handle the fallback"))
        XCTAssertEqual(draft.body, "Handle the fallback")
    }

    func testLargeGeneralAndInlineDraftsFitGitHubLimitsAndDecisionComesLast() throws {
        var draft = WorkspaceReviewDraft()
        draft.body = "Please address these findings"
        draft.generalComments = (0..<20).map { WorkspaceGeneralDraft(body: "Finding \($0): " + String(repeating: "x", count: 10_000)) }
        draft.comments = (0..<205).map { WorkspaceInlineDraft(path: "file.swift", line: $0 + 1, side: "RIGHT", body: "Inline \($0)") }
        let plan = try ReviewPublicationPlan.make(draft: draft, event: .requestChanges)
        XCTAssertGreaterThan(plan.count, 1)
        XCTAssertEqual(plan.flatMap(\.comments), draft.comments)
        XCTAssertEqual(plan.flatMap(\.generalComments), draft.generalComments)
        XCTAssertTrue(plan.allSatisfy { $0.body.utf8.count <= 65_536 && $0.comments.count <= 100 })
        XCTAssertTrue(plan.dropLast().allSatisfy { $0.event == .comment })
        XCTAssertEqual(plan.last?.event, .requestChanges)
        XCTAssertTrue(plan.last?.body.hasPrefix(draft.body) == true)
        XCTAssertEqual(plan.filter(\.includesSummary).count, 1)
    }

    func testRequestChangesRequiresUserSummaryEvenWithGeneralFindings() {
        var draft = WorkspaceReviewDraft()
        draft.generalComments = [WorkspaceGeneralDraft(body: "An agent finding")]
        XCTAssertThrowsError(try ReviewPublicationPlan.make(draft: draft, event: .requestChanges))
    }

    func testOneOversizedCommentRejectsBeforeAnyPublicationPlan() {
        var draft = WorkspaceReviewDraft()
        draft.generalComments = [WorkspaceGeneralDraft(body: String(repeating: "x", count: 65_537))]
        XCTAssertThrowsError(try ReviewPublicationPlan.make(draft: draft, event: .comment))
    }

    func testSingleGeneralSelectionLeavesSummaryAndOtherDraftsOutOfPlan() throws {
        var draft = WorkspaceReviewDraft()
        draft.body = "Private unfinished summary"
        let one = WorkspaceGeneralDraft(body: "Selected finding")
        draft.generalComments = [one, WorkspaceGeneralDraft(body: "Other finding")]
        draft.comments = [WorkspaceInlineDraft(path: "file.swift", line: 1, side: "RIGHT", body: "Inline")]
        let plan = try ReviewPublicationPlan.make(draft: draft, event: .comment, selectedDraftIDs: [one.id])
        XCTAssertEqual(plan.count, 1)
        XCTAssertEqual(plan[0].body, one.body)
        XCTAssertFalse(plan[0].includesSummary)
        XCTAssertTrue(plan[0].comments.isEmpty)
        XCTAssertEqual(plan[0].generalComments, [one])
    }
}
