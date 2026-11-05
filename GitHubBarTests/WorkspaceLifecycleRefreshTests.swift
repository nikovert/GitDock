import XCTest
@testable import GitHubBarCore
@testable import GitHubBar

@MainActor
final class WorkspaceLifecycleRefreshTests: XCTestCase {
    func testOnlySuccessfulDistinctRefreshesTriggerCleanup() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("lifecycle-refresh-\(UUID())")
        let suite = "LifecycleRefresh.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { try? FileManager.default.removeItem(at: directory); defaults.removePersistentDomain(forName: suite) }
        let service = RefreshCleanupFixture()
        let store = LocalWorkspaceStore(directoryURL: directory)
        let model = WorkspaceModel(store: store, sessions: AgentSessionManager(store: store, tmuxURL: nil),
            defaults: defaults, cleanupService: service)
        await model.reload()
        var state = AppPresentationState.empty
        state.accountConnection = .connected(login: "tester", accessCoverage: .init(isComplete: true))
        state.lastUpdatedAt = Date(timeIntervalSince1970: 100)
        state.refreshHealth = .restoredSnapshot
        model.updateWorkload(state)
        await model.cleanup.pendingTask?.value
        var calls = await service.previews
        XCTAssertEqual(calls, 0)
        state.refreshHealth = .fresh
        model.updateWorkload(state)
        await model.cleanup.pendingTask?.value
        calls = await service.previews
        XCTAssertEqual(calls, 1)
        state.repositoryScope = .pinned
        model.updateWorkload(state)
        await model.cleanup.pendingTask?.value
        calls = await service.previews
        XCTAssertEqual(calls, 1)
        state.lastUpdatedAt = Date(timeIntervalSince1970: 200)
        state.refreshHealth = .failed(message: "Offline")
        model.updateWorkload(state)
        await model.cleanup.pendingTask?.value
        calls = await service.previews
        XCTAssertEqual(calls, 1)
        state.refreshHealth = .partial(message: "Reviewer information incomplete")
        model.updateWorkload(state)
        await model.cleanup.pendingTask?.value
        calls = await service.previews
        XCTAssertEqual(calls, 2)
    }
}

private actor RefreshCleanupFixture: WorktreeCleanupServicing {
    var previews = 0
    func preview(accountLogin: String) async throws -> [WorktreeCleanupCandidate] { previews += 1; return [] }
    func execute(_ approved: [WorktreeCleanupCandidate], accountLogin: String) async -> [WorktreeCleanupResult] { [] }
}
