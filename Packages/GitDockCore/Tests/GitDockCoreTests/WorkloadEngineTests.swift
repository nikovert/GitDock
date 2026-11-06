import XCTest
@testable import GitDockCore

final class WorkloadEngineTests: XCTestCase {
    func testPartialRateLimitDefersQueuedAndSubsequentManualRefreshUntilReset() async throws {
        let clock = ManuallyAdvancingRefreshClock(now: Date(timeIntervalSince1970: 100))
        let client = SuspendedRefreshClient(partialFirstResult: true)
        let engine = WorkloadEngine(accountConnection: ConnectedTestAccountConnection(), workloadClient: client,
            settingsStore: InMemorySettingsStore(settings: AppSettings(refreshCadence: .manual)), clock: clock)
        let launch = Task { await engine.send(.launch) }
        await client.waitForStart()
        await engine.send(.manualRefresh)
        await client.release()
        await launch.value
        var count = await client.requestCount
        XCTAssertEqual(count, 1, "A queued click must respect the partial result's reset deadline")
        await engine.send(.manualRefresh)
        await engine.send(.manualRefresh)
        count = await client.requestCount
        XCTAssertEqual(count, 1, "Later clicks must coalesce while GitHub is rate limited")
        // Fail promptly on the old behavior instead of waiting for a retry it canceled.
        guard count == 1 else { return }
        for _ in 0..<1_000 where await clock.pendingSleepCount == 0 { await Task.yield() }
        let sleepers = await clock.pendingSleepCount
        XCTAssertEqual(sleepers, 1)
        await clock.advance(by: 599)
        count = await client.requestCount
        XCTAssertEqual(count, 1)
        await clock.advance(by: 1)
        for _ in 0..<1_000 where await client.requestCount < 2 { await Task.yield() }
        count = await client.requestCount
        XCTAssertEqual(count, 2, "One deferred refresh must run once the deadline passes")
    }

    func testManualRefreshDoesNotBypassKnownRateLimitReset() async throws {
        let client = RateLimitedRefreshClient()
        let engine = WorkloadEngine(accountConnection: ConnectedTestAccountConnection(), workloadClient: client)
        await engine.send(.launch)
        await engine.send(.manualRefresh)
        let count = await client.count
        XCTAssertEqual(count, 1)
        let state = try await currentState(of: engine)
        guard case .rateLimited = state.refreshHealth else { return XCTFail("Keep rate-limit feedback visible") }
    }
    func testManualClicksDuringRefreshCoalesceAndPublishFollowup() async throws {
        let client = SuspendedRefreshClient()
        let engine = WorkloadEngine(accountConnection: ConnectedTestAccountConnection(), workloadClient: client)
        let launch = Task { await engine.send(.launch) }
        await client.waitForStart()
        await engine.send(.manualRefresh)
        await engine.send(.manualRefresh)
        await engine.send(.manualRefresh)
        await engine.send(.setWorkloadSurfaceOpen(false))
        await client.release()
        await launch.value
        let count = await client.requestCount
        let state = try await currentState(of: engine)
        XCTAssertEqual(count, 2)
        XCTAssertEqual(state.lastUpdatedAt, Date(timeIntervalSince1970: 2))
        XCTAssertFalse(state.isRefreshing)
    }

    func testManualRefreshRecoversUnavailableConnection() async throws {
        let connection = RecoveringConnection()
        let client = ScopeFilteringWorkloadClient()
        let engine = WorkloadEngine(accountConnection: connection, workloadClient: client,
            settingsStore: InMemorySettingsStore(settings: AppSettings(selectedLogin: "chosen")))
        await engine.send(.launch)
        await engine.send(.manualRefresh)
        let state = try await currentState(of: engine)
        guard case let .connected(login, _) = state.accountConnection else {
            return XCTFail("Manual refresh should retry account resolution")
        }
        XCTAssertEqual(login, "chosen")
        XCTAssertEqual(state.reviewCount, 2)
    }

    func testAccountSwitchDiscardsOldRefreshAndUsesNewIdentity() async throws {
        let client = SuspendedRefreshClient()
        let engine = WorkloadEngine(accountConnection: ConnectedTestAccountConnection(), workloadClient: client)
        let launch = Task { await engine.send(.launch) }
        await client.waitForStart()
        await engine.send(.manualRefresh)
        await engine.send(.confirmAccount("new-account"))
        await client.release()
        await launch.value
        let state = try await currentState(of: engine)
        guard case let .connected(login, _) = state.accountConnection else { return XCTFail() }
        XCTAssertEqual(login, "new-account")
        XCTAssertEqual(state.lastUpdatedAt, Date(timeIntervalSince1970: 2))
        let logins = await client.logins
        XCTAssertEqual(logins, ["FranciscoMoretti", "new-account"])
    }

    func testReviewCountDisplayShowsTwoDigitsAndCapsThreeDigitVisualText() {
        XCTAssertNil(ReviewCountDisplay.text(for: 0))
        XCTAssertEqual(ReviewCountDisplay.text(for: 4), "4")
        XCTAssertEqual(ReviewCountDisplay.text(for: 20), "20")
        XCTAssertEqual(ReviewCountDisplay.text(for: 99), "99")
        XCTAssertEqual(ReviewCountDisplay.text(for: 100), "99")
    }

    func testSubscriberImmediatelyReceivesTruthfulEmptyPresentation() async throws {
        let engine = WorkloadEngine(initialState: .empty)
        let stream = await engine.states()
        var iterator = stream.makeAsyncIterator()

        let nextState = await iterator.next()
        let state = try XCTUnwrap(nextState)

        XCTAssertEqual(state, .empty)
        XCTAssertTrue(state.needsYourReview.isEmpty)
        XCTAssertTrue(state.authoredPullRequests.isEmpty)
        XCTAssertEqual(state.reviewCount, 0)
        XCTAssertEqual(state.reviewCountAccessibilityLabel, "No pull requests waiting for your review")
    }

    func testChangingRepositoryScopePublishesNewPresentation() async throws {
        let engine = WorkloadEngine(initialState: .empty)
        let stream = await engine.states()
        var iterator = stream.makeAsyncIterator()
        _ = await iterator.next()

        await engine.send(.selectRepositoryScope(.pinned))
        let nextState = await iterator.next()
        let state = try XCTUnwrap(nextState)

        XCTAssertEqual(state.repositoryScope, .pinned)
    }

    func testChangingRepositoryScopeFiltersCanonicalSnapshotWithoutReconciling() async throws {
        let workloadClient = ScopeFilteringWorkloadClient()
        let engine = WorkloadEngine(
            accountConnection: ConnectedTestAccountConnection(),
            workloadClient: workloadClient,
            settingsStore: InMemorySettingsStore(
                settings: AppSettings(
                    selectedLogin: "FranciscoMoretti",
                    pinnedRepositories: [
                        PinnedRepository(id: "REPO-A", nameWithOwner: "owner/a"),
                    ]
                )
            )
        )

        await engine.send(.launch)
        var requestCount = await workloadClient.requestCount
        XCTAssertEqual(requestCount, 1)

        await engine.send(.selectRepositoryScope(.pinned))
        var state = try await currentState(of: engine)
        XCTAssertEqual(state.needsYourReview.map(\.repositoryID), ["REPO-A"])
        XCTAssertEqual(state.reviewCount, 1)
        XCTAssertFalse(state.isRefreshing)
        requestCount = await workloadClient.requestCount
        XCTAssertEqual(requestCount, 1)

        await engine.send(.togglePinnedRepository(
            RepositoryChoice(id: "REPO-A", nameWithOwner: "owner/a")
        ))
        await engine.send(.togglePinnedRepository(
            RepositoryChoice(id: "REPO-B", nameWithOwner: "owner/b")
        ))
        state = try await currentState(of: engine)
        XCTAssertEqual(state.needsYourReview.map(\.repositoryID), ["REPO-B"])
        XCTAssertEqual(state.reviewCount, 1)
        XCTAssertFalse(state.isRefreshing)
        requestCount = await workloadClient.requestCount
        XCTAssertEqual(requestCount, 1)

        await engine.send(.selectRepositoryScope(.all))
        state = try await currentState(of: engine)
        XCTAssertEqual(state.needsYourReview.map(\.repositoryID), ["REPO-A", "REPO-B"])
        XCTAssertEqual(state.reviewCount, 2)
        XCTAssertFalse(state.isRefreshing)
        requestCount = await workloadClient.requestCount
        XCTAssertEqual(requestCount, 1)
    }

    func testConfirmingMonitoredAccountPersistsOnlyItsLogin() async throws {
        let settingsStore = InMemorySettingsStore()
        let engine = WorkloadEngine(
            accountConnection: TestAccountConnection(),
            settingsStore: settingsStore
        )
        let stream = await engine.states()
        var iterator = stream.makeAsyncIterator()
        _ = await iterator.next()

        await engine.send(.launch)
        _ = await iterator.next()
        let nextSelectionState = await iterator.next()
        let selectionState = try XCTUnwrap(nextSelectionState)
        guard case .selectionRequired = selectionState.accountConnection else {
            return XCTFail("Expected account selection")
        }

        await engine.send(.confirmAccount("FranciscoMoretti"))
        _ = await iterator.next()
        let nextConnectedState = await iterator.next()
        let connectedState = try XCTUnwrap(nextConnectedState)
        guard case let .connected(login, _) = connectedState.accountConnection else {
            return XCTFail("Expected connected account")
        }

        XCTAssertEqual(login, "FranciscoMoretti")
        let settings = await settingsStore.load()
        XCTAssertEqual(settings.selectedLogin, "FranciscoMoretti")
    }

    private func currentState(of engine: WorkloadEngine) async throws -> AppPresentationState {
        let stream = await engine.states()
        var iterator = stream.makeAsyncIterator()
        let nextState = await iterator.next()
        return try XCTUnwrap(nextState)
    }
}

private actor RecoveringConnection: AccountConnection {
    private var attempts = 0
    func inspect(selectedLogin: String?) async -> AccountConnectionResult {
        attempts += 1
        if attempts == 1 { return .connectionRequired }
        return await ConnectedTestAccountConnection().inspect(selectedLogin: selectedLogin)
    }
}

private actor RateLimitedRefreshClient: GitHubWorkloadClient {
    var count = 0
    func reconcile(account: ResolvedAccount) async -> WorkloadReconciliationResult {
        count += 1
        return .failed(.rateLimited, ReconciliationMetadata(queryCost: 0, remainingPoints: 0,
            resetAt: Date().addingTimeInterval(600), warnings: [], rateLimitEncountered: true))
    }
}

private actor SuspendedRefreshClient: GitHubWorkloadClient {
    let partialFirstResult: Bool
    init(partialFirstResult: Bool = false) { self.partialFirstResult = partialFirstResult }
    private(set) var requestCount = 0
    private(set) var logins: [String] = []
    private var gate: CheckedContinuation<Void, Never>?
    func waitForStart() async {
        while gate == nil { await Task.yield() }
    }
    func release() { gate?.resume(); gate = nil }
    func reconcile(account: ResolvedAccount) async -> WorkloadReconciliationResult {
        requestCount += 1
        let number = requestCount
        logins.append(account.login)
        if number == 1 { await withCheckedContinuation { gate = $0 } }
        if number == 1, partialFirstResult {
            return .partial(WorkloadSnapshot(hostname: account.hostname, accountLogin: account.login,
                capturedAt: Date(timeIntervalSince1970: 1), completeness: .partial,
                availableRepositories: [], needsYourReview: [], authoredPullRequests: []),
                ReconciliationMetadata(queryCost: 0, remainingPoints: 0,
                    resetAt: Date(timeIntervalSince1970: 700), warnings: [], rateLimitEncountered: true))
        }
        return .complete(WorkloadSnapshot(hostname: account.hostname, accountLogin: account.login,
            capturedAt: Date(timeIntervalSince1970: Double(number)), completeness: .complete,
            availableRepositories: [], needsYourReview: [], authoredPullRequests: []), .empty)
    }
}

private struct TestAccountConnection: AccountConnection {
    func inspect(selectedLogin: String?) async -> AccountConnectionResult {
        guard let selectedLogin else {
            return .selectionRequired([
                AccountCandidate(login: "FranciscoMoretti", hostname: "github.com"),
                AccountCandidate(login: "francisco-acme", hostname: "github.com"),
            ])
        }
        return .connected(
            ResolvedAccount(
                login: selectedLogin,
                hostname: "github.com",
                scopes: ["read:org", "repo"],
                accessCoverage: AccessCoverage(isComplete: true),
                accessToken: GitHubAccessToken("test-token")
            )
        )
    }
}

private struct ConnectedTestAccountConnection: AccountConnection {
    func inspect(selectedLogin: String?) async -> AccountConnectionResult {
        .connected(
            ResolvedAccount(
                login: selectedLogin ?? "FranciscoMoretti",
                hostname: "github.com",
                scopes: ["read:org", "repo"],
                accessCoverage: AccessCoverage(isComplete: true),
                accessToken: GitHubAccessToken("test-token")
            )
        )
    }
}

private actor ScopeFilteringWorkloadClient: GitHubWorkloadClient {
    private(set) var requestCount = 0

    func reconcile(account: ResolvedAccount) async -> WorkloadReconciliationResult {
        requestCount += 1
        return .complete(
            WorkloadSnapshot(
                hostname: account.hostname,
                accountLogin: account.login,
                capturedAt: Date(timeIntervalSince1970: 1_700_000_000),
                completeness: .complete,
                availableRepositories: [
                    RepositoryChoice(id: "REPO-A", nameWithOwner: "owner/a"),
                    RepositoryChoice(id: "REPO-B", nameWithOwner: "owner/b"),
                ],
                needsYourReview: [
                    pullRequest(id: "PR-A", repositoryID: "REPO-A", number: 1),
                    pullRequest(id: "PR-B", repositoryID: "REPO-B", number: 2),
                ],
                authoredPullRequests: []
            ),
            .empty
        )
    }

    private func pullRequest(
        id: String,
        repositoryID: String,
        number: Int
    ) -> PullRequestPresentation {
        PullRequestPresentation(
            id: id,
            repositoryID: repositoryID,
            repositoryNameWithOwner: "owner/\(repositoryID.lowercased())",
            number: number,
            title: "Pull request \(number)",
            url: URL(string: "https://github.com/owner/repo/pull/\(number)")!,
            isDraft: false,
            updatedAt: Date(timeIntervalSince1970: 1_700_000_000),
            reviewers: []
        )
    }
}
