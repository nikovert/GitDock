import XCTest
@testable import GitDockCore
@testable import GitDock

@MainActor
final class StaleDraftCleanupModelTests: XCTestCase {
    func testProductionAuthorIDsReachTheQueueThroughTheRealService() async {
        let row = draftUIRow()
        XCTAssertEqual(row.author?.id, "user:tester")
        let model = StaleDraftCleanupModel(service: StaleDraftCleanupService(
            connection: DraftProjectionConnection(), transport: DraftProjectionTransport()))
        model.updateContext(accountLogin: "tester", workload: [row])
        model.scan()
        await model.pendingTask?.value
        XCTAssertEqual(model.phase, .reviewing)
        XCTAssertEqual(model.candidates.map(\.key.number), [1])
        XCTAssertTrue(model.selected.isEmpty)
    }

    func testScanSelectAndCancelNeverClosesDrafts() async {
        let service = DraftUIService()
        let model = StaleDraftCleanupModel(service: service)
        model.updateContext(accountLogin: "tester", workload: [])
        model.scan()
        await model.pendingTask?.value
        XCTAssertEqual(model.phase, .reviewing)
        XCTAssertTrue(model.selected.isEmpty)
        model.confirmSelected()
        model.select("acme/widget#1", enabled: true)
        model.confirmSelected()
        model.cancel()
        let calls = await service.closedIDs
        XCTAssertTrue(calls.isEmpty, "Selection alone is not confirmation")
    }

    func testExplicitConfirmationClosesOnlySelectedEligibleRowsAndRefreshes() async {
        let service = DraftUIService()
        let model = StaleDraftCleanupModel(service: service)
        var refreshed = 0
        model.onClosed = { refreshed += 1 }
        model.updateContext(accountLogin: "tester", workload: [])
        model.scan()
        await model.pendingTask?.value
        model.select("acme/widget#1", enabled: true)
        model.select("acme/widget#3", enabled: true)
        XCTAssertEqual(model.selected, ["acme/widget#1"])
        model.requestConfirmation()
        model.confirmSelected()
        await model.pendingTask?.value
        XCTAssertEqual(model.results.map(\.candidate.key.number), [1])
        XCTAssertEqual(model.phase, .results)
        XCTAssertEqual(refreshed, 1)
        XCTAssertTrue(model.hasConfirmedCloses)
        XCTAssertFalse(model.confirmationRequested)
    }

    func testAccountScopeAndThresholdChangesInvalidateSelectionAndConfirmation() async {
        for change in ["account", "scope", "threshold"] {
            let service = DraftUIService()
            let model = StaleDraftCleanupModel(service: service)
            model.updateContext(accountLogin: "tester", workload: [])
            model.scan()
            await model.pendingTask?.value
            model.select("acme/widget#1", enabled: true)
            model.requestConfirmation()
            switch change {
            case "account": model.updateContext(accountLogin: "other", workload: [])
            case "scope": model.updateContext(accountLogin: "tester", workload: [draftUIRow()])
            default: model.setInactiveDays(45)
            }
            model.confirmSelected()
            let calls = await service.closedIDs
            XCTAssertTrue(calls.isEmpty)
            XCTAssertTrue(model.selected.isEmpty)
            XCTAssertFalse(model.confirmationRequested)
        }
    }

    func testUnconfirmedWriteStaysVisibleAndCannotRetryWithoutScanning() async {
        let service = DraftUIService(outcome: .unconfirmed)
        let model = StaleDraftCleanupModel(service: service)
        var refreshed = false
        model.onClosed = { refreshed = true }
        model.updateContext(accountLogin: "tester", workload: [])
        model.scan()
        await model.pendingTask?.value
        model.select("acme/widget#1", enabled: true)
        model.requestConfirmation(); model.confirmSelected()
        await model.pendingTask?.value
        XCTAssertEqual(model.results.first?.outcome, .unconfirmed)
        XCTAssertFalse(model.hasConfirmedCloses)
        XCTAssertFalse(refreshed)
        model.requestConfirmation(); model.confirmSelected()
        let calls = await service.closedIDs
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(model.results.count, 1)
    }

    func testInvalidThresholdDoesNotStartScan() async {
        let service = DraftUIService()
        let model = StaleDraftCleanupModel(service: service)
        model.updateContext(accountLogin: "tester", workload: [])
        model.setInactiveDays(0)
        model.scan()
        XCTAssertFalse(model.isBusy)
        XCTAssertNotNil(model.errorMessage)
        let scans = await service.scans
        XCTAssertEqual(scans, 0)
    }

    func testRefreshAfterCloseKeepsResultsForManualCleanupOffer() async {
        let model = StaleDraftCleanupModel(service: DraftUIService())
        model.updateContext(accountLogin: "tester", workload: [draftUIRow()])
        model.scan()
        await model.pendingTask?.value
        model.select("acme/widget#1", enabled: true)
        model.requestConfirmation(); model.confirmSelected()
        await model.pendingTask?.value
        model.updateContext(accountLogin: "tester", workload: [])
        XCTAssertEqual(model.phase, .results)
        XCTAssertTrue(model.hasConfirmedCloses)
        model.updateContext(accountLogin: "other", workload: [])
        XCTAssertFalse(model.hasConfirmedCloses)
    }

    func testAccountChangeDuringAwaitedCloseStopsRemainingDraftsAndRefreshesConfirmedWrite() async {
        let service = SuspendedDraftUIService()
        let model = StaleDraftCleanupModel(service: service)
        var refreshed = 0
        model.onClosed = { refreshed += 1 }
        model.updateContext(accountLogin: "tester", workload: [])
        model.scan()
        await model.pendingTask?.value
        model.select("acme/widget#1", enabled: true)
        model.select("acme/widget#2", enabled: true)
        model.requestConfirmation(); model.confirmSelected()
        let task = model.pendingTask
        await service.waitForClose()
        XCTAssertEqual(model.currentID, "acme/widget#1")
        model.updateContext(accountLogin: "other", workload: [])
        await service.release()
        await task?.value
        let calls = await service.closedIDs
        XCTAssertEqual(calls, ["acme/widget#1"])
        XCTAssertEqual(model.phase, .idle)
        XCTAssertTrue(model.results.isEmpty)
        XCTAssertEqual(refreshed, 1)
    }
}

private actor SuspendedDraftUIService: StaleDraftCleanupServicing {
    private var continuation: CheckedContinuation<Void, Never>?
    private var waiting: CheckedContinuation<Void, Never>?
    private(set) var closedIDs: [String] = []
    func preview(workload: [PullRequestPresentation], accountLogin: String, inactiveDays: Int) async throws -> [StaleDraftCleanupCandidate] {
        try await DraftUIService().preview(workload: workload, accountLogin: accountLogin, inactiveDays: inactiveDays)
    }
    func close(_ approved: StaleDraftCleanupCandidate, accountLogin: String) async -> StaleDraftCleanupResult {
        closedIDs.append(approved.id)
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            waiting?.resume(); waiting = nil
        }
        return .init(candidate: approved, outcome: .closed, message: "Fixture confirmed close")
    }
    func waitForClose() async {
        if continuation == nil { await withCheckedContinuation { waiting = $0 } }
    }
    func release() { continuation?.resume(); continuation = nil }
}

private actor DraftUIService: StaleDraftCleanupServicing {
    private(set) var closedIDs: [String] = []
    private(set) var scans = 0
    let outcome: StaleDraftCleanupResult.Outcome
    init(outcome: StaleDraftCleanupResult.Outcome = .closed) { self.outcome = outcome }
    func preview(workload: [PullRequestPresentation], accountLogin: String, inactiveDays: Int) async throws -> [StaleDraftCleanupCandidate] {
        scans += 1
        return (1...3).map { number in
            StaleDraftCleanupCandidate(key: try! PullRequestKey(url: URL(string: "https://github.com/acme/widget/pull/\(number)")!),
                nodeID: "PR_\(number)", accountLogin: accountLogin, title: "Old draft \(number)", authorLogin: accountLogin,
                headSHA: "abc", updatedAt: Date(timeIntervalSince1970: 1_000),
                previewedAt: Date(timeIntervalSince1970: 10_000_000), inactiveDays: inactiveDays, viewerCanClose: number != 3)
        }
    }
    func close(_ approved: StaleDraftCleanupCandidate, accountLogin: String) async -> StaleDraftCleanupResult {
        closedIDs.append(approved.id)
        return .init(candidate: approved, outcome: outcome, message: "Fixture result")
    }
}

private func draftUIRow() -> PullRequestPresentation {
    .init(id: "PR_1", repositoryID: "R", repositoryNameWithOwner: "acme/widget", number: 1,
          title: "Old draft", url: URL(string: "https://github.com/acme/widget/pull/1")!, isDraft: true,
          author: .init(id: "user:tester", displayName: "tester", avatarURL: nil),
          updatedAt: Date(timeIntervalSince1970: 1_000), reviewers: [], headSHA: "abc")
}

private struct DraftProjectionConnection: AccountConnection {
    func inspect(selectedLogin: String?) async -> AccountConnectionResult {
        .connected(.init(login: "tester", hostname: "github.com", scopes: [], accessCoverage: .init(isComplete: true),
                         accessToken: GitHubAccessToken("fixture")))
    }
}

private struct DraftProjectionTransport: GitHubTransport {
    func execute(body: Data, accessToken: GitHubAccessToken) async throws -> GitHubTransportResponse {
        .init(statusCode: 200, headers: [:], data: Data(#"{"data":{"viewer":{"login":"tester"},"repository":{"pullRequest":{"id":"PR_1","url":"https://github.com/acme/widget/pull/1","title":"Old draft","author":{"login":"tester"},"state":"OPEN","isDraft":true,"headRefOid":"abc","updatedAt":"1970-01-01T00:16:40Z","viewerCanClose":true}}}}"#.utf8))
    }
}
