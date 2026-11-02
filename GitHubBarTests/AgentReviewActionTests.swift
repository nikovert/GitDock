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
        XCTAssertEqual(requests.first?.task, .worktreeReview)
        XCTAssertNotNil(requests.first?.repository)
        let discussions = await f.chat.discussions
        XCTAssertTrue(discussions.first?.contains("Published discussion") == true)
        XCTAssertTrue(discussions.first?.contains("file.swift") == true)
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

    func testWorktreeReviewReportsAllNativeFilesBeyondSnapshotAndPartialCoverage() async throws {
        let f = try fixture()
        defer { f.defaults.removePersistentDomain(forName: f.suite) }
        await open(f.model)
        let paths = ["file.swift"] + (1...16).map { "native-file-\($0).swift" }
        await f.worktrees.setPaths(paths)
        f.model.runAgentReview(configuration: configuration)
        await f.chat.waitFor(1)
        let requests = await f.chat.requests
        let directories = await f.chat.directories
        XCTAssertEqual(directories.first, requests.first?.repository?.worktreePath)
        await f.chat.finish(0, findings: [], coverage: ReviewCoverage(reviewedPaths: ["file.swift"], unreviewed: [], testsRun: [], limitations: []))
        await f.model.agentReviewTask?.value
        XCTAssertEqual(f.model.draft.lastAgentReview?.changedFileCount, 17)
        XCTAssertEqual(f.model.draft.lastAgentReview?.coverage?.unreviewed.count, 16)
        XCTAssertTrue(f.model.agentReviewMessage?.contains("Partial") == true)
        XCTAssertTrue(f.model.agentReviewMessage?.contains("1/17") == true)
        let releases = await f.worktrees.releases
        XCTAssertEqual(releases.count, 1)
    }

    func testWorktreeReviewPreservesAllFindingsOnlyAfterValidationAndFreshCommitCheck() async throws {
        let f = try fixture()
        defer { f.defaults.removePersistentDomain(forName: f.suite) }
        await open(f.model)
        f.model.runAgentReview(configuration: configuration)
        await f.chat.waitFor(1)
        f.model.editDraft { $0.body = "Edited during review" }
        await f.service.changeBase()
        await f.chat.finish(0, findings: [ReviewAgentFinding(body: "Stale finding")])
        await f.model.agentReviewTask?.value
        XCTAssertEqual(f.model.draft.body, "Edited during review")
        XCTAssertTrue(f.model.draft.generalComments.isEmpty)
        XCTAssertNotNil(f.model.agentReviewErrorMessage)
        let releases = await f.worktrees.releases
        XCTAssertEqual(releases.count, 1)
    }

    func testWorktreeValidationFailureAndMissingCoverageCannotMeanNoFindings() async throws {
        let f = try fixture()
        defer { f.defaults.removePersistentDomain(forName: f.suite) }
        await open(f.model)
        await f.worktrees.failValidation(true)
        f.model.runAgentReview(configuration: configuration)
        await f.chat.waitFor(1)
        await f.chat.finish(0, findings: [])
        await f.model.agentReviewTask?.value
        XCTAssertNotNil(f.model.agentReviewErrorMessage)
        XCTAssertNil(f.model.draft.lastAgentReview)
        await f.worktrees.failValidation(false)
        f.model.runAgentReview(configuration: configuration)
        await f.chat.waitFor(2)
        await f.chat.finish(1, findings: [], coverage: nil)
        await f.model.agentReviewTask?.value
        XCTAssertNotNil(f.model.agentReviewErrorMessage)
        XCTAssertNil(f.model.draft.lastAgentReview)
    }

    func testCommitChangeDuringCleanupRejectsFindingsBeforeImport() async throws {
        let f = try fixture()
        defer { f.defaults.removePersistentDomain(forName: f.suite) }
        await open(f.model)
        await f.worktrees.holdRelease()
        f.model.runAgentReview(configuration: configuration)
        await f.chat.waitFor(1)
        await f.chat.finish(0, findings: [ReviewAgentFinding(body: "Stale after cleanup")])
        await f.worktrees.waitForRelease()
        await f.service.changeBase()
        f.model.editDraft { $0.body = "Keep my edits" }
        await f.worktrees.finishRelease()
        await f.model.agentReviewTask?.value
        XCTAssertTrue(f.model.draft.generalComments.isEmpty)
        XCTAssertNil(f.model.draft.lastAgentReview)
        XCTAssertEqual(f.model.draft.body, "Keep my edits")
        XCTAssertNotNil(f.model.agentReviewErrorMessage)
    }

    func testCancellationDuringPreparationReleasesLateLeaseWithoutCallingProvider() async throws {
        let f = try fixture()
        defer { f.defaults.removePersistentDomain(forName: f.suite) }
        await open(f.model)
        await f.worktrees.holdPreparation()
        f.model.runAgentReview(configuration: configuration)
        await f.worktrees.waitForPreparation()
        let cancelled = f.model.agentReviewTask
        f.model.cancelAgentReview()
        await f.worktrees.finishPreparation()
        await cancelled?.value
        let requests = await f.chat.requests
        let releases = await f.worktrees.releases
        XCTAssertTrue(requests.isEmpty)
        XCTAssertEqual(releases.count, 1)
        XCTAssertNil(f.model.draft.lastAgentReview)
    }

    func testSetupFailureDoesNotFallBackToExcerptAndCustomProviderHasGuidance() async throws {
        let f = try fixture()
        defer { f.defaults.removePersistentDomain(forName: f.suite) }
        await open(f.model)
        await f.worktrees.failPreparation()
        f.model.runAgentReview(configuration: configuration)
        await f.model.agentReviewTask?.value
        XCTAssertTrue(f.model.agentReviewErrorMessage?.contains("checkout") == true)
        var custom = configuration; custom.provider = .custom
        f.model.runAgentReview(configuration: custom)
        await f.model.agentReviewTask?.value
        XCTAssertTrue(f.model.agentReviewErrorMessage?.contains("Codex or Claude") == true)
        let requests = await f.chat.requests
        XCTAssertTrue(requests.isEmpty)
    }

    func testCleanCoverageAndRetainedWorktreeWarningAreVisibleWithoutTouchingDrafts() async throws {
        let f = try fixture()
        defer { f.defaults.removePersistentDomain(forName: f.suite) }
        await open(f.model)
        await f.worktrees.retainWorktree()
        f.model.runAgentReview(configuration: configuration)
        await f.chat.waitFor(1)
        await f.chat.finish(0, findings: [])
        await f.model.agentReviewTask?.value
        XCTAssertTrue(f.model.agentReviewMessage?.contains("1/1") == true)
        XCTAssertTrue(f.model.agentReviewMessage?.contains("retained") == true)
        XCTAssertEqual(f.model.draft.lastAgentReview?.coverage?.reviewedPaths, ["file.swift"])
        XCTAssertFalse(f.model.draft.lastAgentReview?.contextIncomplete ?? true)
        XCTAssertEqual(f.model.draft.allDraftCount, 0)
    }

    func testReviewReceiptPreservesNoticesFromTheDiscussionSuppliedToTheAgent() async throws {
        let f = try fixture()
        defer { f.defaults.removePersistentDomain(forName: f.suite) }
        await f.service.setNotices(["Discussion fetch was incomplete"])
        await open(f.model)
        f.model.runAgentReview(configuration: configuration)
        await f.chat.waitFor(1)
        await f.service.setNotices([])
        await f.chat.finish(0, findings: [])
        await f.model.agentReviewTask?.value
        XCTAssertEqual(f.model.draft.lastAgentReview?.sourceNotices, ["Discussion fetch was incomplete"])
        XCTAssertFalse(f.model.draft.lastAgentReview?.contextIncomplete ?? true)
    }

    private let key = try! PullRequestKey(url: URL(string: "https://github.com/acme/app/pull/1")!)
    private var configuration: ReviewChatConfiguration { ReviewChatConfiguration(displayName: "Codex", executable: "/usr/bin/true", workingDirectory: "/tmp", provider: .codex) }
    private func open(_ model: ReviewWorkspaceModel) async { model.select(key, account: "alice"); await model.loadTask?.value }
    private func fixture() throws -> (suite: String, defaults: UserDefaults, model: ReviewWorkspaceModel, service: AgentActionPRService, chat: AgentActionChatService, worktrees: AgentActionWorktreeService) {
        let suite = "AgentReviewAction-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let service = AgentActionPRService()
        let chat = AgentActionChatService()
        let worktrees = AgentActionWorktreeService()
        return (suite, defaults, ReviewWorkspaceModel(service: service, chatService: chat, worktreeService: worktrees,
            local: ReviewWorkspaceState(defaults: defaults)), service, chat, worktrees)
    }
}

private actor AgentActionChatService: ReviewChatServicing {
    var requests: [ReviewChatRequest] = []
    var discussions: [String] = []
    var directories: [String] = []
    var pending: [Int: CheckedContinuation<ReviewChatResponse, any Error>] = [:]
    func send(_ request: ReviewChatRequest, configuration: ReviewChatConfiguration) async throws -> ReviewChatResponse {
        let index = requests.count
        requests.append(request)
        directories.append(configuration.workingDirectory)
        if let repository = request.repository {
            discussions.append((try? String(contentsOfFile: repository.contextDirectory + "/discussion.json", encoding: .utf8)) ?? "")
        }
        return try await withCheckedThrowingContinuation { pending[index] = $0 }
    }
    func waitFor(_ count: Int) async { while requests.count < count { await Task.yield() } }
    func finish(_ index: Int, findings: [ReviewAgentFinding]?, coverage: ReviewCoverage? = ReviewCoverage(reviewedPaths: ["file.swift"], unreviewed: [], testsRun: [], limitations: [])) {
        let request = requests[index]
        pending.removeValue(forKey: index)?.resume(returning: ReviewChatResponse(prURL: request.prURL, headSHA: request.headSHA, answer: "Agent reviewed the available changes", citations: [], findings: findings, coverage: coverage))
    }
    func fail(_ index: Int) { pending.removeValue(forKey: index)?.resume(throwing: ReviewChatError.processFailed(1)) }
}

private actor AgentActionPRService: PRReviewServicing {
    struct Submission: Sendable { let body: String; let comments: [PRReviewDraftComment] }
    var submissions: [Submission] = []
    private var holds = false
    private var base = String(repeating: "b", count: 40)
    private var notices: [String] = []
    private var failedWrite: Int?
    func failWrite(_ index: Int) { failedWrite = index }
    func changeBase() { base = String(repeating: "c", count: 40) }
    func setNotices(_ value: [String]) { notices = value }
    private var write: CheckedContinuation<Void, Never>?
    func hold() { holds = true }
    func waitForWrite() async { while write == nil { await Task.yield() } }
    func finishWrite() { write?.resume(); write = nil }
    func load(key: PullRequestKey, accountLogin: String, sinceSHA: String?) async throws -> PRReviewSnapshot {
        PRReviewSnapshot(key: key, title: "Review PR", body: "Useful change", author: "other", createdAt: nil, updatedAt: .now,
            headSHA: String(repeating: "a", count: 40), baseSHA: base, files: [PRSearchFile(path: "file.swift", patch: "@@ -1 +1 @@\n-old\n+new", additions: 1, deletions: 1)], notices: notices, comments: [PRReviewComment(id: "issue:1", author: "sam", body: "Published discussion")], checksSummary: "Unknown", fileListComplete: true)
    }
    func submit(key: PullRequestKey, accountLogin: String, headSHA: String, baseSHA: String, event: PRReviewEvent,
                body: String, comments: [PRReviewDraftComment]) async throws -> PRReviewSubmissionReceipt {
        submissions.append(Submission(body: body, comments: comments))
        if submissions.count == failedWrite { throw PRReviewError.submissionRejected }
        if holds { await withCheckedContinuation { write = $0 } }
        return PRReviewSubmissionReceipt(id: 42, headSHA: headSHA, event: event)
    }
}

private actor AgentActionWorktreeService: ReviewWorktreeServicing {
    var requests: [ReviewWorktreeRequest] = []
    var releases: [UUID] = []
    private var paths = ["file.swift"]
    private var invalid = false
    private var preparationFails = false
    private var retained = false
    private var holds = false
    private var preparing: CheckedContinuation<Void, Never>?
    private var holdingRelease = false
    private var releasing: CheckedContinuation<Void, Never>?
    func setPaths(_ paths: [String]) { self.paths = paths }
    func failValidation(_ value: Bool) { invalid = value }
    func failPreparation() { preparationFails = true }
    func retainWorktree() { retained = true }
    func holdPreparation() { holds = true }
    func waitForPreparation() async { while preparing == nil { await Task.yield() } }
    func finishPreparation() { preparing?.resume(); preparing = nil; holds = false }
    func holdRelease() { holdingRelease = true }
    func waitForRelease() async { while releasing == nil { await Task.yield() } }
    func finishRelease() { releasing?.resume(); releasing = nil; holdingRelease = false }
    func prepare(_ request: ReviewWorktreeRequest) async throws -> ReviewWorktreeLease {
        requests.append(request)
        if preparationFails { throw ReviewWorktreeError.failed("Configure a local checkout first") }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("app-review-\(UUID())")
        let worktree = root.appendingPathComponent("tree")
        let context = root.appendingPathComponent("context")
        try FileManager.default.createDirectory(at: worktree, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: context, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let lease = ReviewWorktreeLease(id: UUID(), key: request.key, accountLogin: request.accountLogin,
            headSHA: request.headSHA, baseSHA: request.baseSHA, mergeBaseSHA: request.baseSHA,
            worktreePath: worktree.path, contextDirectory: context.path, manifestPath: context.appendingPathComponent("manifest.json").path,
            changedPaths: paths)
        if holds { await withCheckedContinuation { preparing = $0 } }
        return lease
    }
    func validate(_ lease: ReviewWorktreeLease) async throws {
        if invalid { throw ReviewWorktreeError.failed("The review worktree changed") }
    }
    func release(_ lease: ReviewWorktreeLease) async -> String? {
        releases.append(lease.id)
        if holdingRelease { await withCheckedContinuation { releasing = $0 } }
        try? FileManager.default.removeItem(at: URL(fileURLWithPath: lease.contextDirectory).deletingLastPathComponent())
        return retained ? "Review worktree retained because local changes were detected" : nil
    }
}
