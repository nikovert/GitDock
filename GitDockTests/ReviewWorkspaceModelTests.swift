import XCTest
import GitDockCore
@testable import GitDock

@MainActor
final class ReviewWorkspaceModelTests: XCTestCase {
    func testIncompleteDiffRetainsEditorAndCompleteDiffAllowsDraft() async throws {
        let fixture = try makeFixture()
        defer { fixture.defaults.removePersistentDomain(forName: fixture.name) }
        let service = DeferredReviewService()
        let model = ReviewWorkspaceModel(service: service, local: fixture.state)
        let key = try PullRequestKey(url: URL(string: "https://github.com/acme/app/pull/1")!)
        model.select(key, account: "alice")
        await service.waitFor(1)
        await service.finish(key, account: "alice", complete: false)
        await model.loadTask?.value
        model.selection = ReviewLineSelection(path: "file", line: 1, side: "RIGHT", text: "value")
        model.inlineBody = "Check this value"
        model.addInlineDraft()
        XCTAssertTrue(model.draft.comments.isEmpty)
        XCTAssertEqual(model.inlineBody, "Check this value")
        model.refresh()
        await service.waitFor(2)
        await service.finish(key, account: "alice", complete: true)
        await model.loadTask?.value
        model.selection = ReviewLineSelection(path: "file", line: 1, side: "RIGHT", text: "value")
        model.addInlineDraft()
        XCTAssertEqual(model.draft.comments.map(\.body), ["Check this value"])
        XCTAssertEqual(model.inlineBody, "")
    }

    func testCapturedSubmissionCannotApproveRefreshedHeadOrDifferentPR() async throws {
        let fixture = try makeFixture()
        defer { fixture.defaults.removePersistentDomain(forName: fixture.name) }
        let service = DeferredReviewService()
        let model = ReviewWorkspaceModel(service: service, local: fixture.state)
        let key = try PullRequestKey(url: URL(string: "https://github.com/acme/app/pull/1")!)
        model.select(key, account: "alice")
        await service.waitFor(1)
        await service.finish(key, account: "alice", head: "aaa")
        await model.loadTask?.value
        let captured = try XCTUnwrap(model.identity)
        model.refresh()
        await service.waitFor(2)
        await service.finish(key, account: "alice", head: "bbb")
        await model.loadTask?.value
        model.submit(event: .approve, target: captured)
        await model.submitTask?.value
        let afterRefresh = await service.submissionCount
        XCTAssertEqual(afterRefresh, 0)
        let other = try PullRequestKey(url: URL(string: "https://github.com/acme/app/pull/2")!)
        model.select(other, account: "alice")
        await service.waitFor(3)
        await service.finish(other, account: "alice", head: "aaa")
        await model.loadTask?.value
        model.submit(event: .approve, target: captured)
        await model.submitTask?.value
        let afterNavigation = await service.submissionCount
        XCTAssertEqual(afterNavigation, 0)
        XCTAssertNotNil(model.errorMessage)
    }

    func testUnavailableStorageDoesNotClearInlineEditorOrClaimReviewed() async throws {
        let fixture = try makeFixture()
        defer { fixture.defaults.removePersistentDomain(forName: fixture.name) }
        fixture.defaults.set(Data("invalid JSON".utf8), forKey: ReviewWorkspaceState.storageKey)
        let local = ReviewWorkspaceState(defaults: fixture.defaults)
        let service = DeferredReviewService()
        let model = ReviewWorkspaceModel(service: service, local: local)
        let key = try PullRequestKey(url: URL(string: "https://github.com/acme/app/pull/1")!)
        model.select(key, account: "alice")
        await service.waitFor(1)
        await service.finish(key, account: "alice")
        await model.loadTask?.value
        model.selection = ReviewLineSelection(path: "file", line: 1, side: "RIGHT", text: "value")
        model.inlineBody = "Do not lose this comment"
        model.addInlineDraft()
        XCTAssertEqual(model.inlineBody, "Do not lose this comment")
        XCTAssertNotNil(model.selection)
        model.markReviewed()
        XCTAssertNil(model.notice)
        XCTAssertNil(model.baseline)
    }

    func testLargeConversationIsBoundedBeforeSendingWithoutErasingSavedHistory() async throws {
        let fixture = try makeFixture()
        defer { fixture.defaults.removePersistentDomain(forName: fixture.name) }
        let service = DeferredReviewService()
        let chat = DeferredChatService()
        let model = ReviewWorkspaceModel(service: service, chatService: chat, local: fixture.state)
        let key = try PullRequestKey(url: URL(string: "https://github.com/acme/app/pull/1")!)
        model.select(key, account: "alice")
        await service.waitFor(1)
        await service.finish(key, account: "alice")
        await model.loadTask?.value
        model.editDraft { draft in
            draft.messages = (0..<20).map { _ in WorkspaceChatMessage(role: "assistant", text: String(repeating: "x", count: 100_000)) }
        }
        model.question = "What should I check next?"
        model.sendQuestion(configuration: ReviewChatConfiguration(), policy: "Advisory")
        await chat.waitForRequest()
        let received = await chat.receivedRequest()
        let request = try XCTUnwrap(received)
        XCTAssertLessThanOrEqual(try JSONEncoder().encode(request).count, 750_000)
        XCTAssertEqual(model.draft.messages.count, 21)
        await chat.finish()
        await model.chatTask?.value
    }

    func testComparisonRetryKeepsReviewedBaselineAfterLoadFailure() async throws {
        let fixture = try makeFixture()
        defer { fixture.defaults.removePersistentDomain(forName: fixture.name) }
        let service = DeferredReviewService()
        let model = ReviewWorkspaceModel(service: service, local: fixture.state)
        let key = try PullRequestKey(url: URL(string: "https://github.com/acme/app/pull/1")!)
        model.select(key, account: "alice")
        await service.waitFor(1)
        await service.finish(key, account: "alice")
        await model.loadTask?.value
        model.markReviewed()
        model.compareSinceLastReview(true)
        await service.waitFor(2)
        await service.fail(key, account: "alice")
        await model.loadTask?.value
        model.refresh()
        await service.waitFor(3)
        let comparisons = await service.comparisons
        XCTAssertEqual(comparisons.compactMap { $0 }, ["aaa", "aaa"])
        await service.finish(key, account: "alice")
        await model.loadTask?.value
    }

    func testFailedSubmissionPreservesDraftAndDoesNotMarkReviewed() async throws {
        let fixture = try makeFixture()
        defer { fixture.defaults.removePersistentDomain(forName: fixture.name) }
        let service = DeferredReviewService()
        let model = ReviewWorkspaceModel(service: service, local: fixture.state)
        let key = try PullRequestKey(url: URL(string: "https://github.com/acme/app/pull/1")!)
        model.select(key, account: "alice")
        await service.waitFor(1)
        await service.finish(key, account: "alice")
        await model.loadTask?.value
        model.editDraft { $0.body = "Please check the fallback" }
        await service.rejectSubmissions()
        model.submit(event: .comment, target: try XCTUnwrap(model.identity))
        await model.submitTask?.value
        XCTAssertEqual(model.draft.body, "Please check the fallback")
        XCTAssertNil(model.baseline)
        XCTAssertNotNil(model.errorMessage)
    }

    func testChatReplyIsPreservedWhenReviewIsSubmitting() async throws {
        let fixture = try makeFixture()
        defer { fixture.defaults.removePersistentDomain(forName: fixture.name) }
        let service = DeferredReviewService()
        let chat = DeferredChatService()
        let model = ReviewWorkspaceModel(service: service, chatService: chat, local: fixture.state)
        let key = try PullRequestKey(url: URL(string: "https://github.com/acme/app/pull/1")!)
        model.select(key, account: "alice")
        await service.waitFor(1)
        await service.finish(key, account: "alice")
        await model.loadTask?.value
        model.editDraft { $0.body = "Looks good" }
        model.question = "Any risks?"
        model.sendQuestion(configuration: ReviewChatConfiguration(), policy: "Advisory")
        await chat.waitForRequest()
        await service.holdSubmissions()
        model.submit(event: .comment, target: try XCTUnwrap(model.identity))
        await service.waitForSubmission()
        await chat.finish()
        await model.chatTask?.value
        XCTAssertEqual(model.draft.messages.last?.text, "Check missing inputs.")
        await service.finishSubmission()
        await model.submitTask?.value
        XCTAssertEqual(model.draft.messages.last?.text, "Check missing inputs.")
        XCTAssertEqual(model.draft.body, "")
    }

    func testChatReplyAfterAccountSwitchIsDiscarded() async throws {
        let fixture = try makeFixture()
        defer { fixture.defaults.removePersistentDomain(forName: fixture.name) }
        let service = DeferredReviewService()
        let chat = DeferredChatService()
        let model = ReviewWorkspaceModel(service: service, chatService: chat, local: fixture.state)
        let key = try PullRequestKey(url: URL(string: "https://github.com/acme/app/pull/1")!)
        model.select(key, account: "alice")
        await service.waitFor(1)
        await service.finish(key, account: "alice")
        await model.loadTask?.value
        let oldIdentity = try XCTUnwrap(model.identity)
        model.question = "Any risks?"
        model.sendQuestion(configuration: ReviewChatConfiguration(), policy: "Advisory")
        let oldTask = model.chatTask
        await chat.waitForRequest()
        model.select(key, account: "bob")
        await service.waitFor(2)
        await service.finish(key, account: "bob")
        await model.loadTask?.value
        await chat.finish()
        await oldTask?.value
        XCTAssertTrue(model.draft.messages.isEmpty)
        XCTAssertEqual(fixture.state.draft(for: oldIdentity).messages.map(\.role), ["user"])
    }

    func testLateLoadCannotReplaceNewAccountOrSelection() async throws {
        let fixture = try makeFixture()
        defer { fixture.defaults.removePersistentDomain(forName: fixture.name) }
        let service = DeferredReviewService()
        let model = ReviewWorkspaceModel(service: service, local: fixture.state)
        let first = try PullRequestKey(url: URL(string: "https://github.com/acme/app/pull/1")!)
        let second = try PullRequestKey(url: URL(string: "https://github.com/acme/app/pull/2")!)
        model.select(first, account: "alice")
        let oldTask = model.loadTask
        await service.waitFor(1)
        model.select(second, account: "bob")
        await service.waitFor(2)
        await service.finish(second, account: "bob")
        await model.loadTask?.value
        XCTAssertEqual(model.snapshot?.key, second)
        await service.finish(first, account: "alice")
        await oldTask?.value
        XCTAssertEqual(model.snapshot?.key, second)
        XCTAssertEqual(model.identity?.account, "bob")
        model.select(nil, account: nil)
        XCTAssertNil(model.snapshot)
    }

    func testHeadChangeRetainsOlderDraftAndStartsSeparateCurrentDraft() async throws {
        let fixture = try makeFixture()
        defer { fixture.defaults.removePersistentDomain(forName: fixture.name) }
        let service = DeferredReviewService()
        let model = ReviewWorkspaceModel(service: service, local: fixture.state)
        let key = try PullRequestKey(url: URL(string: "https://github.com/acme/app/pull/1")!)
        model.select(key, account: "alice")
        await service.waitFor(1)
        await service.finish(key, account: "alice", head: "aaa")
        await model.loadTask?.value
        model.editDraft { $0.body = "Comment on original code" }
        model.select(key, account: "alice", force: true)
        await service.waitFor(2)
        await service.finish(key, account: "alice", head: "bbb")
        await model.loadTask?.value
        XCTAssertEqual(model.draft.body, "")
        let current = try XCTUnwrap(model.identity)
        XCTAssertEqual(fixture.state.previousDraftHeads(current), ["aaa"])
        XCTAssertEqual(fixture.state.draft(for: ReviewIdentity(account: "alice", prURL: key.url.absoluteString, headSHA: "aaa", baseSHA: "base")).body, "Comment on original code")
    }

    func testSingleDraftSubmissionLeavesOtherCommentsAndSummaryUntouched() async throws {
        let fixture = try makeFixture()
        defer { fixture.defaults.removePersistentDomain(forName: fixture.name) }
        let service = DeferredReviewService()
        let model = ReviewWorkspaceModel(service: service, local: fixture.state)
        let key = try PullRequestKey(url: URL(string: "https://github.com/acme/app/pull/1")!)
        model.select(key, account: "alice")
        await service.waitFor(1); await service.finish(key, account: "alice"); await model.loadTask?.value
        let one = WorkspaceInlineDraft(path: "file", line: 1, side: "LEFT", body: "First")
        let two = WorkspaceInlineDraft(path: "file", line: 1, side: "RIGHT", body: "Second")
        model.editDraft { $0.body = "Summary still being written"; $0.comments = [one, two] }
        model.submitDraft(one.id, target: try XCTUnwrap(model.identity))
        await model.submitTask?.value
        let posted = await service.submittedComments
        let body = await service.submittedBody
        let event = await service.submittedEvent
        XCTAssertEqual(posted.map(\.body), ["First"])
        XCTAssertEqual(body, "")
        XCTAssertEqual(event, .comment)
        XCTAssertEqual(model.draft.comments, [two])
        XCTAssertEqual(model.draft.body, "Summary still being written")
    }

    func testEditsDuringBatchSubmissionSurviveConfirmedSuccess() async throws {
        let fixture = try makeFixture()
        defer { fixture.defaults.removePersistentDomain(forName: fixture.name) }
        let service = DeferredReviewService()
        let model = ReviewWorkspaceModel(service: service, local: fixture.state)
        let key = try PullRequestKey(url: URL(string: "https://github.com/acme/app/pull/1")!)
        model.select(key, account: "alice")
        await service.waitFor(1); await service.finish(key, account: "alice"); await model.loadTask?.value
        let one = WorkspaceInlineDraft(path: "file", line: 1, side: "LEFT", body: "First")
        let two = WorkspaceInlineDraft(path: "file", line: 1, side: "RIGHT", body: "Second")
        model.editDraft { $0.body = "Original summary"; $0.comments = [one, two] }
        await service.holdSubmissions()
        model.submit(event: .comment, target: try XCTUnwrap(model.identity))
        await service.waitForSubmission()
        XCTAssertTrue(model.editDraft { $0.body = "New summary"; $0.comments[0].body = "Edited while posting" })
        await service.finishSubmission(); await model.submitTask?.value
        XCTAssertEqual(model.draft.body, "New summary")
        XCTAssertEqual(model.draft.comments.count, 1)
        XCTAssertEqual(model.draft.comments.first?.id, one.id)
        XCTAssertEqual(model.draft.comments.first?.body, "Edited while posting")
    }

    func testCapturedSubmissionCannotPostAfterAccountChange() async throws {
        let fixture = try makeFixture()
        defer { fixture.defaults.removePersistentDomain(forName: fixture.name) }
        let service = DeferredReviewService()
        let model = ReviewWorkspaceModel(service: service, local: fixture.state)
        let key = try PullRequestKey(url: URL(string: "https://github.com/acme/app/pull/1")!)
        model.select(key, account: "alice")
        await service.waitFor(1); await service.finish(key, account: "alice"); await model.loadTask?.value
        let captured = try XCTUnwrap(model.identity)
        model.select(key, account: "bob")
        await service.waitFor(2); await service.finish(key, account: "bob"); await model.loadTask?.value
        model.submit(event: .approve, target: captured)
        let count = await service.submissionCount
        XCTAssertEqual(count, 0)
        XCTAssertNotNil(model.errorMessage)
    }

    func testSubmissionStatusDoesNotFollowNavigationToAnotherPR() async throws {
        let fixture = try makeFixture()
        defer { fixture.defaults.removePersistentDomain(forName: fixture.name) }
        let service = DeferredReviewService()
        let model = ReviewWorkspaceModel(service: service, local: fixture.state)
        let first = try PullRequestKey(url: URL(string: "https://github.com/acme/app/pull/1")!)
        let second = try PullRequestKey(url: URL(string: "https://github.com/acme/app/pull/2")!)
        model.select(first, account: "alice")
        await service.waitFor(1); await service.finish(first, account: "alice"); await model.loadTask?.value
        model.editDraft { $0.body = "Looks good" }
        await service.holdSubmissions()
        model.submit(event: .comment, target: try XCTUnwrap(model.identity))
        await service.waitForSubmission()
        XCTAssertNotNil(model.submissionMessage)
        model.select(second, account: "alice")
        await service.waitFor(2); await service.finish(second, account: "alice"); await model.loadTask?.value
        await service.finishSubmission(); await model.submitTask?.value
        XCTAssertNil(model.submissionMessage)
    }

    func testRepeatedCitationNavigationIssuesNewScrollRequestAndRejectsUnavailableSides() async throws {
        let fixture = try makeFixture()
        defer { fixture.defaults.removePersistentDomain(forName: fixture.name) }
        let service = DeferredReviewService()
        let model = ReviewWorkspaceModel(service: service, local: fixture.state)
        let key = try PullRequestKey(url: URL(string: "https://github.com/acme/app/pull/1")!)
        model.select(key, account: "alice")
        await service.waitFor(1); await service.finish(key, account: "alice"); await model.loadTask?.value
        let citation = ReviewChatCitation(path: "file", line: 1, side: "LEFT")
        model.follow(citation)
        let first = model.navigationRequest
        XCTAssertEqual(model.selection?.side, "LEFT")
        model.follow(citation)
        XCTAssertGreaterThan(model.navigationRequest, first)
        let count = model.navigationRequest
        model.follow(ReviewChatCitation(path: "file", line: 1, side: "UNKNOWN"))
        XCTAssertEqual(model.navigationRequest, count)
        XCTAssertNotNil(model.errorMessage)
    }

    private func makeFixture() throws -> (name: String, defaults: UserDefaults, state: ReviewWorkspaceState) {
        let name = "ReviewModel-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        return (name, defaults, ReviewWorkspaceState(defaults: defaults))
    }
}

private actor DeferredReviewService: PRReviewServicing {
    var calls = 0
    var comparisons: [String?] = []
    var pending: [String: CheckedContinuation<PRReviewSnapshot, any Error>] = [:]
    var rejects = false
    var submissionCount = 0
    var submittedComments: [PRReviewDraftComment] = []
    var submittedBody = ""
    var submittedEvent: PRReviewEvent?
    var holds = false
    var submission: CheckedContinuation<Void, Never>?
    func rejectSubmissions() { rejects = true }
    func holdSubmissions() { holds = true }
    func waitForSubmission() async { while submission == nil { await Task.yield() } }
    func finishSubmission() { submission?.resume(); submission = nil }
    func load(key: PullRequestKey, accountLogin: String, sinceSHA: String?) async throws -> PRReviewSnapshot {
        calls += 1
        comparisons.append(sinceSHA)
        return try await withCheckedThrowingContinuation { pending[accountLogin + key.description] = $0 }
    }
    func waitFor(_ count: Int) async { while calls < count { await Task.yield() } }
    func fail(_ key: PullRequestKey, account: String) {
        pending.removeValue(forKey: account + key.description)?.resume(throwing: PRReviewError.invalidResponse)
    }
    func finish(_ key: PullRequestKey, account: String, head: String = "aaa", complete: Bool = true) {
        pending.removeValue(forKey: account + key.description)?.resume(returning: PRReviewSnapshot(
            key: key, title: "Review me", body: "A useful change", author: "author",
            createdAt: .now, updatedAt: .now, headSHA: head, baseSHA: "base",
            files: [PRSearchFile(path: "file", patch: "@@ -1 +1 @@\n-old\n+value", additions: 1, deletions: 1)],
            notices: [], comments: [], checksSummary: "Unknown", comparisonBaseSHA: nil, fileListComplete: complete))
    }
    func submit(key: PullRequestKey, accountLogin: String, headSHA: String, baseSHA: String, event: PRReviewEvent,
                body: String, comments: [PRReviewDraftComment]) async throws -> PRReviewSubmissionReceipt {
        submissionCount += 1
        submittedComments = comments; submittedBody = body; submittedEvent = event
        if rejects { throw PRReviewError.revisionChanged }
        if holds { await withCheckedContinuation { submission = $0 } }
        return PRReviewSubmissionReceipt(id: 42, headSHA: headSHA, event: event)
    }
}

private actor DeferredChatService: ReviewChatServicing {
    var request: ReviewChatRequest?
    var continuation: CheckedContinuation<ReviewChatResponse, any Error>?
    func send(_ request: ReviewChatRequest, configuration: ReviewChatConfiguration) async throws -> ReviewChatResponse {
        self.request = request
        return try await withCheckedThrowingContinuation { continuation = $0 }
    }
    func waitForRequest() async { while continuation == nil { await Task.yield() } }
    func receivedRequest() -> ReviewChatRequest? { request }
    func finish() {
        guard let request else { return }
        continuation?.resume(returning: ReviewChatResponse(prURL: request.prURL, headSHA: request.headSHA,
            answer: "Check missing inputs.", citations: []))
        continuation = nil
    }
}
