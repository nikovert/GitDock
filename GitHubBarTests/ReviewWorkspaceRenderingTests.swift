import AppKit
import SwiftUI
import XCTest
import GitHubBarCore
@testable import GitHubBar

@MainActor
final class ReviewWorkspaceRenderingTests: XCTestCase {
    func testManagementAndReviewRenderInBothAppearancesAndMinimumWidth() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("workspace-render-\(UUID())")
        let suite = "workspace-render-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: directory) }
        let store = LocalWorkspaceStore(directoryURL: directory)
        let workspace = WorkspaceModel(store: store, sessions: AgentSessionManager(store: store, tmuxURL: nil),
            reviewStore: AgentReviewStore(directoryURL: directory), defaults: defaults)
        let key = try PullRequestKey(url: URL(string: "https://github.com/example/controllers/pull/184")!)
        let pr = PullRequestPresentation(id: "184", repositoryID: "repo", repositoryNameWithOwner: "example/controllers",
            number: 184, title: "Handle missing sensor inputs without losing the previous valid control state",
            url: key.url, isDraft: false,
            author: PullRequestAuthorPresentation(id: "alex", displayName: "alex", avatarURL: nil),
            reviewDecision: .reviewRequired, stackMembership: PullRequestStackMembership(id: "stack", number: 20, size: 2, position: 2), createdAt: .now.addingTimeInterval(-172800), updatedAt: .now.addingTimeInterval(-7200),
            requestedReviewers: [ReviewerPresentation(id: "tester", displayName: "tester", avatarURL: nil, kind: .person)],
            reviewers: [], headSHA: "abc123")
        var state = AppPresentationState.empty
        state.accountConnection = .connected(login: "tester", accessCoverage: AccessCoverage(isComplete: true))
        state.needsYourReview = [pr]
        let closed = PullRequestPresentation(id: "183", repositoryID: "repo", repositoryNameWithOwner: "example/controllers", number: 183,
            title: "Introduce controller state storage", url: URL(string: "https://github.com/example/controllers/pull/183")!, isDraft: false,
            state: .merged, stackMembership: PullRequestStackMembership(id: "stack", number: 20, size: 2, position: 1), updatedAt: .now, reviewers: [])
        state.pullRequestStacks = [PullRequestStack(id: "stack", number: 20, pullRequests: [pr, closed])]
        state.authoredPullRequests = [PullRequestPresentation(id: "201", repositoryID: "repo", repositoryNameWithOwner: "example/controllers", number: 201,
            title: "Add validation for sensor configuration", url: URL(string: "https://github.com/example/controllers/pull/201")!, isDraft: false,
            author: PullRequestAuthorPresentation(id: "tester", displayName: "tester", avatarURL: nil), reviewDecision: .approved,
            createdAt: .now.addingTimeInterval(-86400), updatedAt: .now.addingTimeInterval(-3600), reviewers: [])]
        workspace.updateWorkload(state)
        workspace.openPullRequest(pr)
        let app = AppModel(engine: WorkloadEngine(), initialState: state)
        let model = ReviewWorkspaceModel(service: RenderReviewService(key: key, title: pr.title),
            local: ReviewWorkspaceState(defaults: defaults))
        let output = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(".build/ui-previews")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        for (name, width, mode, tab, appearance) in [
            ("manage-light", 1380.0, ReviewWorkspaceMode.manage, ReviewWorkspaceTab.changes, NSAppearance.Name.aqua),
            ("manage-dark", 1380.0, .manage, .changes, .darkAqua),
            ("review-light", 1380.0, .review, .changes, .aqua),
            ("review-dark", 1380.0, .review, .changes, .darkAqua),
            ("review-minimum", 900.0, .review, .changes, .aqua),
            ("review-large", 1800.0, .review, .changes, .darkAqua),
            ("threads-light", 1380.0, .review, .threads, .aqua),
            ("threads-dark", 1380.0, .review, .threads, .darkAqua),
            ("manage-minimum", 900.0, .manage, .overview, .aqua),
        ] {
            let host = NSHostingView(rootView: ReviewWorkspaceView(workspace: workspace, appModel: app, review: model, layout: WorkspaceLayout(defaults: defaults)))
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 800),
                styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.appearance = NSAppearance(named: appearance)
            window.contentView = host
            window.makeKeyAndOrderFront(nil)
            try await Task.sleep(for: .milliseconds(100))
            await model.loadTask?.value
            model.mode = mode; model.tab = tab; model.queue = .all
            model.editDraft {
                $0.comments = [WorkspaceInlineDraft(path: "src/controllers/controller.py", line: 12, side: "RIGHT", body: "Could we include NaN in the fallback test too?")]
                $0.messages = [WorkspaceChatMessage(role: "assistant", text: "The fallback preserves the last valid output. Check **missing inputs** and test recovery.\n```python\nassert update(None) == previous_output\n```")]
            }
            model.splitDiff = name == "review-dark"
            try await Task.sleep(for: .milliseconds(50))
            host.layoutSubtreeIfNeeded()
            XCTAssertNotNil(model.snapshot)
            XCTAssertNil(model.errorMessage)
            let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
            try png.write(to: output.appendingPathComponent("workspace-\(name).png"))
            window.contentView = nil
            window.close()
        }
    }
}

private struct RenderReviewService: PRReviewServicing {
    let key: PullRequestKey
    let title: String
    func load(key: PullRequestKey, accountLogin: String, sinceSHA: String?) async throws -> PRReviewSnapshot {
        PRReviewSnapshot(key: key, title: title, body: "Preserve the previous output when a sensor reading is missing. Add coverage for fallback recovery.",
            author: "alex", createdAt: .now.addingTimeInterval(-172800), updatedAt: .now,
            headSHA: "abc123", baseSHA: "base", files: [
                PRSearchFile(path: "src/controllers/controller.py", patch: "@@ -10,4 +10,6 @@\n def update(value):\n-    output = float(value)\n+    if value is None:\n+        return previous_output\n+    output = float(value)\n     return output\n ", additions: 3, deletions: 1),
                PRSearchFile(path: "tests/test_controller.py", patch: "@@ -1 +1,2 @@\n test_valid_input()\n+test_missing_input()", additions: 1, deletions: 0)
            ], notices: [], comments: [PRReviewComment(id: "1", author: "sam", body: "Could we also cover a NaN input?", path: "src/controllers/controller.py", line: 12, side: .right),
                PRReviewComment(id: "reply", author: "alex", body: "Yes, I will add a test for NaN and recovery.", path: "src/controllers/controller.py", line: 12, replyToID: "1", side: .right),
                PRReviewComment(id: "old", author: "kim", body: "Earlier naming question", path: "src/controllers/controller.py", url: key.url, side: .right, isOutdated: true, originalLine: 10),
                PRReviewComment(id: "general", author: "sam", body: "The checks are passing. Thanks for adding the fallback.", url: key.url)],
            checksSummary: "Checks: 4 passed, 0 failed, 0 pending", comparisonBaseSHA: sinceSHA, fileListComplete: true)
    }
    func submit(key: PullRequestKey, accountLogin: String, headSHA: String, baseSHA: String, event: PRReviewEvent,
                body: String, comments: [PRReviewDraftComment]) async throws -> PRReviewSubmissionReceipt {
        XCTFail("Rendering must never submit a review")
        throw PRReviewError.submissionRejected
    }
}
