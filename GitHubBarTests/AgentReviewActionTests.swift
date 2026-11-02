import Foundation
import GitHubBarCore
import XCTest
@testable import GitHubBar

@MainActor
final class AgentReviewActionTests: XCTestCase {
    func testReviewImportsFindingsAsLocalDraftsAndPreservesSummaryWithoutPosting() async throws {
        let f = try fixture()
        defer { f.defaults.removePersistentDomain(forName: f.suite) }
        await open(f.model)
        f.model.editDraft {
            $0.body = "My summary"
            $0.comments = [WorkspaceInlineDraft(path: "file.swift", line: 1, side: "RIGHT", body: "My existing comment")]
        }
        f.model.runAgentReview(configuration: configuration)
        await f.chat.waitFor(1)
        let requests = await f.chat.requests
        XCTAssertEqual(requests.first?.task, .review)
        XCTAssertTrue(requests.first?.context.contains("Published discussion") == true)
        XCTAssertTrue(requests.first?.context.contains("file.swift") == true)
        await f.chat.finish(0, findings: [
            ReviewAgentFinding(body: "Old side issue", path: "file.swift", line: 1, side: "LEFT"),
            ReviewAgentFinding(body: "New side issue", path: "file.swift", line: 1, side: "RIGHT"),
            ReviewAgentFinding(body: "Unavailable anchor", path: "old.swift", line: 90, side: "LEFT"),
            ReviewAgentFinding(body: "Add integration coverage")
        ])
        await f.model.agentReviewTask?.value
        XCTAssertEqual(f.model.draft.body, "My summary")
        XCTAssertEqual(f.model.draft.comments.map(\.body), ["My existing comment", "Old side issue", "New side issue"])
        XCTAssertEqual(f.model.draft.generalComments.map(\.body), ["Unavailable anchor", "Add integration coverage"])
        XCTAssertNotNil(f.model.draft.generalComments.first?.anchorDescription)
        XCTAssertEqual(f.model.draft.comments.last?.agentName, "Codex")
        XCTAssertEqual(f.model.draft.lastAgentReview?.findingCount, 4)
        XCTAssertFalse(f.model.reviewing)
        let writes = await f.service.submissions
        XCTAssertTrue(writes.isEmpty)
    }

    func testRerunningReviewDoesNotDuplicateUnchangedFindings() async throws {
        let f = try fixture()
        defer { f.defaults.removePersistentDomain(forName: f.suite) }
        await open(f.model)
        for index in 0..<2 {
            f.model.runAgentReview(configuration: configuration)
            await f.chat.waitFor(index + 1)
            let finding = ReviewAgentFinding(body: "Fix the fallback", path: "file.swift", line: 1, side: "RIGHT")
            await f.chat.finish(index, findings: [finding, finding])
            await f.model.agentReviewTask?.value
        }
        XCTAssertEqual(f.model.draft.comments.count, 1)
        XCTAssertTrue(f.model.draft.generalComments.isEmpty)
    }

    func testAccountNavigationAndCancellationDiscardLateFindings() async throws {
        let f = try fixture()
        defer { f.defaults.removePersistentDomain(forName: f.suite) }
        await open(f.model)
        f.model.runAgentReview(configuration: configuration)
        await f.chat.waitFor(1)
        let oldTask = f.model.agentReviewTask
        f.model.select(key, account: "bob")
        await f.model.loadTask?.value
        await f.chat.finish(0, findings: [ReviewAgentFinding(body: "Do not attach to Bob")])
        await oldTask?.value
        XCTAssertTrue(f.model.draft.generalComments.isEmpty)
        f.model.runAgentReview(configuration: configuration)
        await f.chat.waitFor(2)
        let cancelled = f.model.agentReviewTask
        f.model.cancelAgentReview()
        await f.chat.finish(1, findings: [ReviewAgentFinding(body: "Cancelled finding")])
        await cancelled?.value
        XCTAssertTrue(f.model.draft.generalComments.isEmpty)
        XCTAssertFalse(f.model.reviewing)
    }

    func testFailureAndMalformedReviewPreserveExistingDrafts() async throws {
        let f = try fixture()
        defer { f.defaults.removePersistentDomain(forName: f.suite) }
        await open(f.model)
        f.model.editDraft { $0.generalComments = [WorkspaceGeneralDraft(body: "Keep this draft")] }
        f.model.runAgentReview(configuration: configuration)
        await f.chat.waitFor(1)
        await f.chat.fail(0)
        await f.model.agentReviewTask?.value
        XCTAssertNotNil(f.model.agentReviewErrorMessage)
        XCTAssertEqual(f.model.draft.generalComments.map(\.body), ["Keep this draft"])
        f.model.runAgentReview(configuration: configuration)
        await f.chat.waitFor(2)
        await f.chat.finish(1, findings: nil)
        await f.model.agentReviewTask?.value
        XCTAssertNotNil(f.model.agentReviewErrorMessage)
        XCTAssertNil(f.model.draft.lastAgentReview)
        XCTAssertEqual(f.model.draft.generalComments.map(\.body), ["Keep this draft"])
    }

    func testNoFindingsRecordsReviewWithoutCreatingPublicationDrafts() async throws {
        let f = try fixture()
        defer { f.defaults.removePersistentDomain(forName: f.suite) }
        await open(f.model)
        f.model.runAgentReview(configuration: configuration)
        await f.chat.waitFor(1)
        await f.chat.finish(0, findings: [])
        await f.model.agentReviewTask?.value
        XCTAssertEqual(f.model.draft.allDraftCount, 0)
        XCTAssertEqual(f.model.draft.lastAgentReview?.findingCount, 0)
    }

    func testIndividualGeneralDraftPostingDoesNotPublishOtherDraftsOrSummary() async throws {
        let f = try fixture()
        defer { f.defaults.removePersistentDomain(forName: f.suite) }
        await open(f.model)
        let one = WorkspaceGeneralDraft(body: "First general finding", anchorDescription: "old.swift:90 · LEFT — anchor unavailable")
        let two = WorkspaceGeneralDraft(body: "Second general finding")
        f.model.editDraft {
            $0.body = "Unfinished summary"
            $0.generalComments = [one, two]
            $0.comments = [WorkspaceInlineDraft(path: "file.swift", line: 1, side: "RIGHT", body: "Inline finding")]
        }
        f.model.submitDraft(one.id, target: try XCTUnwrap(f.model.identity))
        await f.model.submitTask?.value
        let writes = await f.service.submissions
        XCTAssertEqual(writes.count, 1)
        XCTAssertEqual(writes[0].body, one.publicationBody)
        XCTAssertTrue(writes[0].comments.isEmpty)
        XCTAssertEqual(f.model.draft.body, "Unfinished summary")
        XCTAssertEqual(f.model.draft.generalComments, [two])
        XCTAssertEqual(f.model.draft.comments.count, 1)
        XCTAssertNil(f.model.baseline)
    }

    func testBatchPublishesGeneralAndInlineAndPreservesEditsDuringSubmission() async throws {
        let f = try fixture()
        defer { f.defaults.removePersistentDomain(forName: f.suite) }
        await open(f.model)
        let one = WorkspaceGeneralDraft(body: "First general finding")
        f.model.editDraft {
            $0.body = "Summary"
            $0.generalComments = [one]
            $0.comments = [WorkspaceInlineDraft(path: "file.swift", line: 1, side: "RIGHT", body: "Inline finding")]
        }
        await f.service.hold()
        f.model.submit(event: .comment, target: try XCTUnwrap(f.model.identity))
        await f.service.waitForWrite()
        f.model.editDraft { $0.generalComments[0].body = "Edited while posting" }
        await f.service.finishWrite()
        await f.model.submitTask?.value
        let writes = await f.service.submissions
        XCTAssertEqual(writes[0].body, "Summary\n\n---\n\nFirst general finding")
        XCTAssertEqual(writes[0].comments.map(\.body), ["Inline finding"])
        XCTAssertEqual(f.model.draft.body, "")
        XCTAssertTrue(f.model.draft.comments.isEmpty)
        XCTAssertEqual(f.model.draft.generalComments.first?.body, "Edited while posting")
    }

    func testLaterPublicationFailureKeepsOnlyUnconfirmedDraftsAndSummary() async throws {
        let f = try fixture()
        defer { f.defaults.removePersistentDomain(forName: f.suite) }
        await open(f.model)
        let comments = (0..<9).map { WorkspaceGeneralDraft(body: "Finding \($0) " + String(repeating: "x", count: 10_000)) }
        f.model.editDraft { $0.body = "My summary"; $0.generalComments = comments }
        await f.service.failWrite(2)
        f.model.submit(event: .comment, target: try XCTUnwrap(f.model.identity))
        await f.model.submitTask?.value
        let writes = await f.service.submissions
        XCTAssertEqual(writes.count, 2)
        XCTAssertTrue(writes.allSatisfy { $0.body.utf8.count <= 65_536 })
        XCTAssertFalse(f.model.draft.generalComments.contains { $0.id == comments[0].id })
        XCTAssertTrue(f.model.draft.generalComments.contains { $0.id == comments[8].id })
        XCTAssertEqual(f.model.draft.body, "My summary")
        XCTAssertNotNil(f.model.errorMessage)
        XCTAssertNil(f.model.baseline)
    }

    func testFixPreparationIncludesFreshPublishedCommentsAndAllLocalDrafts() async throws {
        let f = try fixture()
        defer { f.defaults.removePersistentDomain(forName: f.suite) }
        await open(f.model)
        f.model.editDraft {
            $0.body = "My summary"
            $0.generalComments = [WorkspaceGeneralDraft(body: "General local draft")]
            $0.comments = [WorkspaceInlineDraft(path: "file.swift", line: 1, side: "RIGHT", body: "Inline local draft")]
        }
        let request = try await f.model.prepareFixRequest(for: XCTUnwrap(f.model.identity), instructions: "Assess, fix, test, commit locally")
        XCTAssertTrue(request.comments.contains("Published discussion"))
        XCTAssertTrue(request.comments.contains("General local draft"))
        XCTAssertTrue(request.comments.contains("Inline local draft"))
        XCTAssertTrue(request.comments.contains("My summary"))
        XCTAssertEqual(request.instructions, "Assess, fix, test, commit locally")
        XCTAssertEqual(f.model.draft.allDraftCount, 2)
        let writes = await f.service.submissions
        XCTAssertTrue(writes.isEmpty)
    }

    func testFixPreparationRejectsChangedBaseBeforeLaunching() async throws {
        let f = try fixture()
        defer { f.defaults.removePersistentDomain(forName: f.suite) }
        await open(f.model)
        let target = try XCTUnwrap(f.model.identity)
        await f.service.changeBase()
        do {
            _ = try await f.model.prepareFixRequest(for: target, instructions: "Fix and commit")
            XCTFail("accepted a changed PR base")
        } catch { XCTAssertEqual(error as? PRReviewError, .revisionChanged) }
    }

    func testReviewContextStrictlyBoundsUTF8AndDisclosesTruncation() async throws {
        let f = try fixture()
        defer { f.defaults.removePersistentDomain(forName: f.suite) }
        await open(f.model)
        var draft = WorkspaceReviewDraft()
        draft.generalComments = [WorkspaceGeneralDraft(body: String(repeating: "🌿", count: 2_000))]
        let context = ReviewAgentContext.review(snapshot: try XCTUnwrap(f.model.snapshot), draft: draft, maximumBytes: 250)
        XCTAssertLessThanOrEqual(context.text.utf8.count, 250)
        XCTAssertTrue(context.incomplete)
        XCTAssertTrue(context.text.contains("CONTEXT IS INCOMPLETE"))
    }

    private let key = try! PullRequestKey(url: URL(string: "https://github.com/acme/app/pull/1")!)
    private var configuration: ReviewChatConfiguration { ReviewChatConfiguration(displayName: "Codex", executable: "/usr/bin/true", workingDirectory: "/tmp", provider: .codex) }
    private func open(_ model: ReviewWorkspaceModel) async { model.select(key, account: "alice"); await model.loadTask?.value }
    private func fixture() throws -> (suite: String, defaults: UserDefaults, model: ReviewWorkspaceModel, service: AgentActionPRService, chat: AgentActionChatService) {
        let suite = "AgentReviewAction-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let service = AgentActionPRService()
        let chat = AgentActionChatService()
        return (suite, defaults, ReviewWorkspaceModel(service: service, chatService: chat, local: ReviewWorkspaceState(defaults: defaults)), service, chat)
    }
}

private actor AgentActionChatService: ReviewChatServicing {
    var requests: [ReviewChatRequest] = []
    var pending: [Int: CheckedContinuation<ReviewChatResponse, any Error>] = [:]
    func send(_ request: ReviewChatRequest, configuration: ReviewChatConfiguration) async throws -> ReviewChatResponse {
        let index = requests.count
        requests.append(request)
        return try await withCheckedThrowingContinuation { pending[index] = $0 }
    }
    func waitFor(_ count: Int) async { while requests.count < count { await Task.yield() } }
    func finish(_ index: Int, findings: [ReviewAgentFinding]?) {
        let request = requests[index]
        pending.removeValue(forKey: index)?.resume(returning: ReviewChatResponse(prURL: request.prURL, headSHA: request.headSHA, answer: "Agent reviewed the available changes", citations: [], findings: findings))
    }
    func fail(_ index: Int) { pending.removeValue(forKey: index)?.resume(throwing: ReviewChatError.processFailed(1)) }
}

private actor AgentActionPRService: PRReviewServicing {
    struct Submission: Sendable { let body: String; let comments: [PRReviewDraftComment] }
    var submissions: [Submission] = []
    private var holds = false
    private var base = String(repeating: "b", count: 40)
    private var failedWrite: Int?
    func failWrite(_ index: Int) { failedWrite = index }
    func changeBase() { base = String(repeating: "c", count: 40) }
    private var write: CheckedContinuation<Void, Never>?
    func hold() { holds = true }
    func waitForWrite() async { while write == nil { await Task.yield() } }
    func finishWrite() { write?.resume(); write = nil }
    func load(key: PullRequestKey, accountLogin: String, sinceSHA: String?) async throws -> PRReviewSnapshot {
        PRReviewSnapshot(key: key, title: "Review PR", body: "Useful change", author: "other", createdAt: nil, updatedAt: .now,
            headSHA: String(repeating: "a", count: 40), baseSHA: base, files: [PRSearchFile(path: "file.swift", patch: "@@ -1 +1 @@\n-old\n+new", additions: 1, deletions: 1)], notices: [], comments: [PRReviewComment(id: "issue:1", author: "sam", body: "Published discussion")], checksSummary: "Unknown", fileListComplete: true)
    }
    func submit(key: PullRequestKey, accountLogin: String, headSHA: String, baseSHA: String, event: PRReviewEvent,
                body: String, comments: [PRReviewDraftComment]) async throws -> PRReviewSubmissionReceipt {
        submissions.append(Submission(body: body, comments: comments))
        if submissions.count == failedWrite { throw PRReviewError.submissionRejected }
        if holds { await withCheckedContinuation { write = $0 } }
        return PRReviewSubmissionReceipt(id: 42, headSHA: headSHA, event: event)
    }
}
