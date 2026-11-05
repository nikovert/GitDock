import XCTest
@testable import GitHubBarCore
@testable import GitHubBar

@MainActor
final class AutomaticWorktreeCleanupTests: XCTestCase {
    func testCancellationStillRecordsCompletedRemovalsUnderOriginalAccount() async throws {
        for switchAccount in [false, true] {
            let suite = "CleanupCancellation.\(UUID())"
            let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
            defer { defaults.removePersistentDomain(forName: suite) }
            let service = AutomaticCleanupFixture(suspendedExecution: true)
            let model = WorktreeCleanupModel(service: service, defaults: defaults)
            model.updateAccount("tester")
            model.updateConfiguration(WorkspaceConfiguration())
            model.automaticRefreshCompleted(at: Date(timeIntervalSince1970: 100))
            while !(await service.executeEntered) { await Task.yield() }
            let pending = model.pendingTask
            if switchAccount { model.updateAccount("other") }
            else { model.automaticEnabled = false }
            await service.releaseExecution()
            await pending?.value
            XCTAssertEqual(model.phase, .idle)
            if switchAccount { XCTAssertTrue(model.activity.isEmpty) }
            let restored = WorktreeCleanupModel(service: service, defaults: defaults)
            restored.updateAccount("tester")
            XCTAssertEqual(restored.activity.first?.entries.filter { $0.outcome == "removed" }.map(\.path), ["/worktrees/clean"])
        }
    }
    func testStoppingAutomaticPreviewClearsBusyState() async {
        let service = AutomaticCleanupFixture(suspended: true)
        let model = WorktreeCleanupModel(service: service)
        model.updateAccount("tester")
        model.updateConfiguration(WorkspaceConfiguration())
        model.automaticRefreshCompleted(at: Date(timeIntervalSince1970: 100))
        while !(await service.previewEntered) { await Task.yield() }
        let pending = model.pendingTask
        model.stopAfterCurrent()
        await service.release()
        await pending?.value
        XCTAssertFalse(model.isBusy)
        XCTAssertFalse(model.isAutomaticRun)
        let calls = await service.executions
        XCTAssertTrue(calls.isEmpty)
    }

    func testCleanupActivityAndPolicyPersistWithoutCrossingAccounts() async throws {
        let suite = "AutomaticCleanup.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = WorktreeCleanupModel(service: AutomaticCleanupFixture(), defaults: defaults)
        model.updateAccount("tester")
        model.updateConfiguration(WorkspaceConfiguration())
        model.automaticRefreshCompleted(at: Date(timeIntervalSince1970: 100))
        await model.pendingTask?.value
        model.automaticEnabled = false
        let restored = WorktreeCleanupModel(service: AutomaticCleanupFixture(), defaults: defaults)
        restored.updateAccount("tester")
        XCTAssertFalse(restored.automaticEnabled)
        XCTAssertEqual(restored.activity.first?.entries.count, 3)
        restored.updateAccount("different")
        XCTAssertTrue(restored.activity.isEmpty)
    }
    func testSuccessfulRefreshExecutesOnlyStoppedManagedEligibleRowsOnce() async {
        let service = AutomaticCleanupFixture()
        let model = WorktreeCleanupModel(service: service)
        model.updateAccount("tester")
        model.updateConfiguration(WorkspaceConfiguration())
        let date = Date(timeIntervalSince1970: 100)
        model.automaticRefreshCompleted(at: date)
        await model.pendingTask?.value
        var calls = await service.executions
        XCTAssertEqual(calls, [["/worktrees/clean"]])
        model.automaticRefreshCompleted(at: date)
        await model.pendingTask?.value
        calls = await service.executions
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(model.results.filter { $0.outcome == .skipped }.count, 2)
    }

    func testDisabledPolicyAndManualReviewBlockAutomaticMutation() async {
        let service = AutomaticCleanupFixture()
        let model = WorktreeCleanupModel(service: service)
        model.updateAccount("tester")
        model.updateConfiguration(WorkspaceConfiguration())
        model.automaticEnabled = false
        model.automaticRefreshCompleted(at: Date(timeIntervalSince1970: 100))
        await model.pendingTask?.value
        var calls = await service.executions
        XCTAssertTrue(calls.isEmpty)
        model.automaticEnabled = true
        model.scan()
        await model.pendingTask?.value
        model.automaticRefreshCompleted(at: Date(timeIntervalSince1970: 200))
        await model.pendingTask?.value
        calls = await service.executions
        XCTAssertTrue(calls.isEmpty)
        XCTAssertEqual(model.phase, .choice)
    }

    func testAccountChangeWhileAutomaticPreviewIsPendingPreventsExecution() async {
        let service = AutomaticCleanupFixture(suspended: true)
        let model = WorktreeCleanupModel(service: service)
        model.updateAccount("tester")
        model.updateConfiguration(WorkspaceConfiguration())
        model.automaticRefreshCompleted(at: Date(timeIntervalSince1970: 100))
        let pending = model.pendingTask
        model.updateAccount("different")
        await service.release()
        await pending?.value
        let calls = await service.executions
        XCTAssertTrue(calls.isEmpty)
        XCTAssertTrue(model.results.isEmpty)
    }
}

private actor AutomaticCleanupFixture: WorktreeCleanupServicing {
    var executions: [[String]] = []
    var suspended: Bool
    var previewEntered = false
    var executeEntered = false
    var suspendedExecution: Bool
    init(suspended: Bool = false, suspendedExecution: Bool = false) {
        self.suspended = suspended; self.suspendedExecution = suspendedExecution
    }
    func release() { suspended = false }
    func releaseExecution() { suspendedExecution = false }
    func preview(accountLogin: String) async throws -> [WorktreeCleanupCandidate] {
        previewEntered = true
        while suspended { await Task.yield() }
        let key = try PullRequestKey(url: URL(string: "https://github.com/example/project/pull/42")!)
        return ["clean", "live", "dirty"].map { name in
            let link = AgentSessionLink(subject: .pullRequest(key), agent: .codex, worktreePath: "/worktrees/\(name)",
                tmuxSessionName: name == "live" ? "live" : nil, managedWorktree: true, state: .stopped)
            return WorktreeCleanupCandidate(path: link.worktreePath, sessions: [link], title: name,
                headSHA: String(repeating: "a", count: 40), skipReason: name == "dirty" ? "Local changes" : nil,
                liveSessions: name == "live" ? ["live": .init(id: "$1", serverPID: 1, serverStartedAt: 1, sessionCreatedAt: 1)] : [:],
                accountLogin: accountLogin, configuration: WorkspaceConfiguration())
        }
    }
    func execute(_ approved: [WorktreeCleanupCandidate], accountLogin: String) async -> [WorktreeCleanupResult] {
        executions.append(approved.map(\.path))
        executeEntered = true
        while suspendedExecution { await Task.yield() }
        return approved.map { .init(path: $0.path, outcome: .removed, message: "Removed") }
    }
    func execute(_ approved: [WorktreeCleanupCandidate], accountLogin: String, intent: WorktreeCleanupIntent) async -> [WorktreeCleanupResult] {
        await execute(approved, accountLogin: accountLogin)
    }
}
