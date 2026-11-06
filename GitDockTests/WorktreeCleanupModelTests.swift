import XCTest
@testable import GitDockCore
@testable import GitDock

@MainActor
final class WorktreeCleanupModelTests: XCTestCase {
    func testBusyScanCannotExecuteOrPublishAfterAccountChange() async {
        let service = SuspendedCleanupUIService()
        let model = WorktreeCleanupModel(service: service)
        model.updateAccount("tester")
        model.scan()
        let pending = model.pendingTask
        XCTAssertTrue(model.isBusy)
        model.confirmAll()
        model.updateAccount("other")
        await service.release()
        await pending?.value
        XCTAssertTrue(model.candidates.isEmpty)
        XCTAssertFalse(model.isBusy)
        let calls = await service.executions
        XCTAssertEqual(calls, 0)
    }

    func testScanAndCancelNeverExecuteCleanup() async {
        let service = CleanupUIService()
        let model = WorktreeCleanupModel(service: service)
        model.updateAccount("tester")
        model.scan()
        await model.pendingTask?.value
        XCTAssertEqual(model.candidates.count, 3)
        XCTAssertEqual(model.phase, .choice)
        XCTAssertTrue(model.selected.isEmpty)
        model.cancel()
        let calls = await service.executions
        XCTAssertTrue(calls.isEmpty)
    }

    func testBulkConfirmationExecutesOnlyEligibleRowsAndReloadsBoard() async {
        let service = CleanupUIService()
        let model = WorktreeCleanupModel(service: service)
        var reloaded = false
        model.onCompletion = { reloaded = true }
        model.updateAccount("tester")
        model.scan()
        await model.pendingTask?.value
        model.confirmAll()
        await model.pendingTask?.value
        XCTAssertEqual(model.results.map(\.path), ["/worktrees/one", "/worktrees/two"])
        XCTAssertEqual(model.phase, .results)
        XCTAssertTrue(reloaded)
    }

    func testIndividualSelectionCannotIncludeBlockedRows() async {
        let model = WorktreeCleanupModel(service: CleanupUIService())
        model.updateAccount("tester")
        model.scan()
        await model.pendingTask?.value
        model.reviewIndividually()
        XCTAssertEqual(model.phase, .reviewing)
        XCTAssertTrue(model.selected.isEmpty)
        model.select("/worktrees/two", enabled: true)
        model.select("/worktrees/blocked", enabled: true)
        model.confirmSelected()
        await model.pendingTask?.value
        XCTAssertEqual(model.results.map(\.path), ["/worktrees/two"])
    }

    func testAccountOrConfigurationChangeInvalidatesPreview() async {
        for accountChange in [true, false] {
            let service = CleanupUIService()
            let model = WorktreeCleanupModel(service: service)
            model.updateAccount("tester")
            model.updateConfiguration(WorkspaceConfiguration())
            model.scan()
            await model.pendingTask?.value
            if accountChange { model.updateAccount("other") }
            else { model.updateConfiguration(WorkspaceConfiguration(worktreeRoot: "/different")) }
            model.confirmAll()
            await model.pendingTask?.value
            let calls = await service.executions
            XCTAssertTrue(calls.isEmpty)
            XCTAssertTrue(model.candidates.isEmpty)
        }
    }

    func testFailedRowsRemainVisibleAndRetryRequiresRescan() async {
        let model = WorktreeCleanupModel(service: CleanupUIService(fail: true))
        model.updateAccount("tester")
        model.scan()
        await model.pendingTask?.value
        model.confirmAll()
        await model.pendingTask?.value
        XCTAssertEqual(model.results.map(\.outcome), [.failed, .failed])
        model.scan()
        await model.pendingTask?.value
        XCTAssertEqual(model.phase, .choice)
        XCTAssertTrue(model.selected.isEmpty)
    }
}

private actor SuspendedCleanupUIService: WorktreeCleanupServicing {
    var released = false
    var executions = 0
    func release() { released = true }
    func preview(accountLogin: String) async throws -> [WorktreeCleanupCandidate] {
        while !released { await Task.yield() }
        return try await CleanupUIService().preview(accountLogin: accountLogin)
    }
    func execute(_ approved: [WorktreeCleanupCandidate], accountLogin: String) async -> [WorktreeCleanupResult] {
        executions += 1; return []
    }
}

actor CleanupUIService: WorktreeCleanupServicing {
    let fail: Bool
    private(set) var executions: [[String]] = []
    init(fail: Bool = false) { self.fail = fail }
    func preview(accountLogin: String) async throws -> [WorktreeCleanupCandidate] {
        [candidate("one"), candidate("two"), candidate("blocked", reason: "Untracked files must be preserved.")]
    }
    func execute(_ approved: [WorktreeCleanupCandidate], accountLogin: String) async -> [WorktreeCleanupResult] {
        executions.append(approved.map(\.id))
        return approved.map { WorktreeCleanupResult(path: $0.path, outcome: fail ? .failed : .removed,
            message: fail ? "Removal refused; worktree retained." : "Removed; branch and notes retained.") }
    }
    private func candidate(_ suffix: String, reason: String? = nil) -> WorktreeCleanupCandidate {
        let key = try! PullRequestKey(url: URL(string: "https://github.com/example/project/pull/42")!)
        let link = AgentSessionLink(subject: .pullRequest(key), agent: .codex,
            worktreePath: "/worktrees/" + suffix, tmuxSessionName: "githubbar-codex-example", managedWorktree: true)
        return WorktreeCleanupCandidate(path: "/worktrees/" + suffix, sessions: [link],
            title: "Improve measurement stability and preserve fallback behavior when inputs arrive late",
            headSHA: String(repeating: "a", count: 40), skipReason: reason,
            liveSessions: ["githubbar-codex-example": WorktreeCleanupSessionIdentity(id: "$1",
                serverPID: 123, serverStartedAt: 1_700_000_000, sessionCreatedAt: 1_700_000_001)],
            accountLogin: "tester", configuration: WorkspaceConfiguration(), pullRequests: [
                WorktreeCleanupPRSummary(key: key,
                    title: "Improve measurement stability and preserve fallback behavior when inputs arrive late",
                    body: "Preserve the last valid measurement when sensor input is missing. This keeps the controller stable while fresh readings arrive.")
            ])
    }
}
