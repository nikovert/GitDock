import Foundation
import GitDockCore
import XCTest
@testable import GitDock

@MainActor
final class PRSearchModelTests: XCTestCase {
    func testRestoresSubmittedQueryWithoutStartingAScan() async {
        let service = SearchServiceSpy(restoredQuery: "previous search")
        let model = PRSearchModel(service: service)
        model.updateWorkload(connectedState("first"))
        await model.waitForPendingCommands()
        await eventually { model.query == "previous search" }
        let scans = await service.scans
        XCTAssertTrue(scans.isEmpty)
        XCTAssertEqual(model.state.phase, .paused)
    }

    func testTypingDoesNotStartNetworkScanAndSubmitUsesExplicitExtension() async {
        let service = SearchServiceSpy()
        let model = PRSearchModel(service: service)
        model.updateWorkload(connectedState("first"))
        model.setQuery("needle")
        await model.waitForPendingCommands()
        let before = await service.scans
        XCTAssertEqual(before, [])
        model.setExtended(true)
        model.submit()
        await model.waitForPendingCommands()
        let after = await service.scans
        XCTAssertEqual(after, [true])
    }

    func testAccountChangeHidesPublishedStateImmediatelyAndRejectsOldSubscription() async {
        let service = SearchServiceSpy()
        let model = PRSearchModel(service: service)
        model.updateWorkload(connectedState("first"))
        await model.waitForPendingCommands()
        await service.publish(message: "private account state")
        await eventually { model.state.message == "private account state" }
        let oldStream = await service.continuation

        model.updateWorkload(connectedState("second"))
        XCTAssertNil(model.state.message)
        var stale = PRSearchState()
        stale.message = "late old response"
        oldStream?.yield(stale)
        await model.waitForPendingCommands()
        await Task.yield()
        XCTAssertNotEqual(model.state.message, "late old response")
        XCTAssertEqual(model.accountLogin, "second")
    }

    func testRemovingRepositoryAndDisablingExtensionPauseWithoutSearching() async {
        let service = SearchServiceSpy()
        let model = PRSearchModel(service: service)
        model.updateWorkload(connectedState("first"))
        model.addRepository(" Acme/Extra ")
        XCTAssertEqual(model.repositories, ["acme/extra", "acme/repo"])
        model.removeRepository("acme/extra")
        model.setExtended(true)
        model.setExtended(false)
        model.close()
        await model.waitForPendingCommands()
        XCTAssertEqual(model.repositories, ["acme/repo"])
        let scans = await service.scans
        let pauses = await service.pauses
        XCTAssertTrue(scans.isEmpty)
        XCTAssertGreaterThanOrEqual(pauses, 2)
    }

    private func connectedState(_ login: String) -> AppPresentationState {
        var state = AppPresentationState.empty
        state.accountConnection = .connected(login: login, accessCoverage: AccessCoverage(isComplete: true))
        state.availableRepositories = [RepositoryChoice(id: "repo", nameWithOwner: "acme/repo")]
        return state
    }

    private func eventually(_ condition: @MainActor () -> Bool) async {
        for _ in 0..<100 {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Search presentation did not update")
    }
}

private actor SearchServiceSpy: PRSearchServing {
    var scans: [Bool] = []
    var pauses = 0
    private var state = PRSearchState()
    var continuation: AsyncStream<PRSearchState>.Continuation?
    private let restoredQuery: String?
    init(restoredQuery: String? = nil) { self.restoredQuery = restoredQuery }

    func states() -> AsyncStream<PRSearchState> {
        let (stream, continuation) = AsyncStream.makeStream(of: PRSearchState.self)
        self.continuation = continuation
        continuation.yield(state)
        return stream
    }
    func configure(login: String?, current: [PullRequestPresentation], repositories: [String]) {
        state = PRSearchState()
        if let restoredQuery {
            state.query = restoredQuery
            state.submittedQuery = restoredQuery
            state.phase = .paused
        }
    }
    func query(_ value: String) { state.query = value; continuation?.yield(state) }
    func search(extended: Bool) { scans.append(extended) }
    func pause() { pauses += 1 }
    func clear() { state = PRSearchState(); continuation?.yield(state) }
    func publish(message: String) { state.message = message; continuation?.yield(state) }
}

@MainActor
private extension PRSearchModel {
    func waitForPendingCommands() async { await pendingCommand?.value }
}
