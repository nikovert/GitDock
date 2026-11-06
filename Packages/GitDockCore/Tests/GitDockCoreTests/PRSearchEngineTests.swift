import XCTest
@testable import GitDockCore

@MainActor
final class PRSearchEngineTests: XCTestCase {
    func testExtendedEnumerationFindsCodeOnlyMatchesBeyondFirstPageAndDeduplicatesActive() async throws {
        let fixture = try SearchEngineFixture()
        defer { fixture.cleanup() }
        await fixture.transport.installHistory()
        await fixture.engine.setContext(selectedLogin: "alice", currentPRs: [searchDocument(number: 1).pullRequest], repositories: ["org/repo"])
        await fixture.engine.setQuery("needle")
        let initialPaths = await fixture.transport.requestPaths()
        XCTAssertTrue(initialPaths.isEmpty)
        await fixture.engine.search()
        let state = await finished(fixture.engine)
        XCTAssertEqual(state.phase, .complete)
        XCTAssertEqual(state.inYourList.map(\.pullRequest.number), [1])
        XCTAssertEqual(Set(state.extendedResults.map(\.pullRequest.number)), [2, 3])
        XCTAssertEqual(Set(state.extendedResults.map(\.pullRequest.state)), [.closed, .merged])
        XCTAssertEqual(state.extendedResults.first?.source, .code)
        XCTAssertFalse(state.progress.moreHistory)
        let paths = await fixture.transport.requestPaths()
        XCTAssertTrue(paths.contains { $0.contains("state=all") && $0.contains("page=2") })
        XCTAssertFalse(paths.contains { $0.contains("/search/") })
    }

    func testAccountSwitchAndClearIgnoreLateNetworkResponse() async throws {
        for clear in [false, true] {
            let fixture = try SearchEngineFixture()
            defer { fixture.cleanup() }
            await fixture.transport.installHistory()
            await fixture.transport.holdNextDetail()
            await fixture.engine.setContext(selectedLogin: "alice", currentPRs: [searchDocument(number: 1).pullRequest], repositories: ["org/repo"])
            await fixture.engine.setQuery("needle")
            await fixture.engine.search()
            await fixture.transport.waitUntilHeld()
            if clear { await fixture.engine.clearCache() }
            else { await fixture.engine.setContext(selectedLogin: "bob", currentPRs: [], repositories: []) }
            await fixture.transport.release()
            try await Task.sleep(for: .milliseconds(30))
            let state = await current(fixture.engine)
            XCTAssertTrue(state.inYourList.isEmpty)
            XCTAssertTrue(state.extendedResults.isEmpty)
            if !clear { XCTAssertTrue(try fixture.index.documents().isEmpty) }
            else { XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.directory.path)) }
        }
    }

    func testRevisionChangeDiscardsMixedDiffAndReportsPartial() async throws {
        let fixture = try SearchEngineFixture()
        defer { fixture.cleanup() }
        await fixture.transport.installHistory()
        await fixture.transport.changeRevisionAfterFiles()
        await fixture.engine.setContext(selectedLogin: "alice", currentPRs: [searchDocument(number: 1).pullRequest], repositories: [])
        await fixture.engine.setQuery("needle")
        await fixture.engine.search(extended: false)
        let state = await finished(fixture.engine)
        XCTAssertTrue(state.inYourList.isEmpty)
        XCTAssertEqual(state.progress.partial, 1)
        XCTAssertTrue(state.message?.contains("partial") == true)
    }

    func testEmptyQueryDoesNotFetchAndOfflineCacheDoesNotDisplay() async throws {
        let fixture = try SearchEngineFixture()
        defer { fixture.cleanup() }
        await fixture.engine.setContext(selectedLogin: "alice", currentPRs: [], repositories: ["org/repo"])
        try fixture.index.save(searchDocument(number: 42, title: "needle"))
        await fixture.engine.search()
        let paths = await fixture.transport.requestPaths()
        XCTAssertTrue(paths.isEmpty)
        await fixture.engine.setQuery("needle")
        let beforeSearch = await current(fixture.engine)
        XCTAssertTrue(beforeSearch.extendedResults.isEmpty)
        await fixture.engine.search()
        let state = await finished(fixture.engine)
        XCTAssertTrue(state.extendedResults.isEmpty)
        XCTAssertEqual(state.phase, .failed)
    }

    func testResumeRefreshesEditsBehindCreationOrderCheckpoint() async throws {
        let fixture = try SearchEngineFixture()
        defer { fixture.cleanup() }
        await fixture.transport.installHistory()
        await fixture.engine.setContext(selectedLogin: "alice", currentPRs: [], repositories: ["org/repo"])
        try fixture.index.saveCheckpoint(PRSearchCheckpoint(page: 2, startedAt: Date(timeIntervalSince1970: 0)), repository: "org/repo", query: "needle")
        await fixture.engine.setQuery("needle")
        await fixture.engine.search()
        let state = await finished(fixture.engine)
        XCTAssertEqual(Set(state.extendedResults.map(\.pullRequest.number)), [1, 2, 3])
        let paths = await fixture.transport.requestPaths()
        XCTAssertTrue(paths.contains { $0.contains("sort=updated") })
    }

    func testRestartRestoresSubmittedQueryButDoesNotFetchOrShowPrivateCache() async throws {
        let fixture = try SearchEngineFixture()
        defer { fixture.cleanup() }
        await fixture.transport.installHistory()
        await fixture.engine.setContext(selectedLogin: "alice", currentPRs: [], repositories: ["org/repo"])
        await fixture.engine.setQuery("needle")
        await fixture.engine.search()
        _ = await finished(fixture.engine)
        let freshTransport = SearchFixtureTransport()
        let restarted = PRSearchEngine(accountConnection: SearchFixtureConnection(), transport: freshTransport, index: fixture.index)
        await restarted.setContext(selectedLogin: "alice", currentPRs: [], repositories: ["org/repo"])
        let state = await current(restarted)
        XCTAssertEqual(state.query, "needle")
        XCTAssertEqual(state.submittedQuery, "needle")
        XCTAssertEqual(state.phase, .paused)
        XCTAssertTrue(state.extendedResults.isEmpty)
        let paths = await freshTransport.requestPaths()
        XCTAssertTrue(paths.isEmpty)
    }

    func testInitialUnresolvedAccountPreservesCheckpointUntilAccountIsResolved() async throws {
        let fixture = try SearchEngineFixture()
        defer { fixture.cleanup() }
        try fixture.index.bind(account: AccountCandidate(login: "alice", hostname: "github.com"))
        try fixture.index.saveSubmittedQuery("saved search")
        try fixture.index.saveCheckpoint(PRSearchCheckpoint(page: 4), repository: "org/repo", query: "saved search")

        await fixture.engine.setContext(selectedLogin: nil, currentPRs: [], repositories: [])
        let unresolved = await current(fixture.engine)
        XCTAssertTrue(unresolved.extendedResults.isEmpty)
        XCTAssertNil(unresolved.submittedQuery)
        await fixture.engine.setContext(selectedLogin: "alice", currentPRs: [], repositories: ["org/repo"])
        let restored = await current(fixture.engine)
        XCTAssertEqual(restored.submittedQuery, "saved search")
        XCTAssertEqual(try fixture.index.checkpoint(repository: "org/repo", query: "saved search")?.page, 4)

        await fixture.engine.setContext(selectedLogin: nil, currentPRs: [], repositories: [])
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.directory.path))
    }

    func testResumeRestoresPartialCoverageForUnchangedNonmatchingPRBeforeCheckpoint() async throws {
        let fixture = try SearchEngineFixture()
        defer { fixture.cleanup() }
        await fixture.transport.installHistory()
        try fixture.index.bind(account: AccountCandidate(login: "alice", hostname: "github.com"))
        var old = searchDocument(number: 1)
        old.coverage = PRSearchCoverage(fileListComplete: true, codeComplete: false,
                                       reasons: ["Missing patch"])
        try fixture.index.save(old)
        try fixture.index.saveCheckpoint(PRSearchCheckpoint(page: 1, offset: 1, startedAt: .now),
                                         repository: "org/repo", query: "needle")
        await fixture.engine.setContext(selectedLogin: "alice", currentPRs: [], repositories: ["org/repo"])
        await fixture.engine.setQuery("needle")
        await fixture.engine.search()
        let state = await finished(fixture.engine)
        XCTAssertEqual(state.phase, .complete)
        XCTAssertEqual(state.progress.indexed, 3)
        XCTAssertEqual(state.progress.partial, 1)
        XCTAssertTrue(state.message?.contains("partial") == true)
    }

    func testTypingAfterClearCacheDoesNotOpenClosedDatabase() async throws {
        let fixture = try SearchEngineFixture()
        defer { fixture.cleanup() }
        await fixture.engine.setContext(selectedLogin: "alice", currentPRs: [], repositories: ["org/repo"])
        await fixture.engine.clearCache()
        await fixture.engine.setQuery("new query")
        let state = await current(fixture.engine)
        XCTAssertEqual(state.phase, .idle)
        XCTAssertNil(state.message)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.directory.path))
    }

    func testThrottlingRetainsResultsButAmbiguous403SuppressesThem() async throws {
        for throttled in [false, true] {
            let fixture = try SearchEngineFixture()
            defer { fixture.cleanup() }
            await fixture.transport.installHistory()
            await fixture.engine.setContext(selectedLogin: "alice", currentPRs: [], repositories: ["org/repo"])
            await fixture.engine.setQuery("needle")
            await fixture.engine.search()
            let initial = await finished(fixture.engine)
            XCTAssertEqual(initial.extendedResults.count, 3)
            await fixture.transport.failNextRequest(status: 403, headers: throttled ? ["x-ratelimit-remaining": "0"] : [:])
            await fixture.engine.search()
            let state = await finished(fixture.engine)
            XCTAssertEqual(state.phase, throttled ? .rateLimited : .connectionRequired)
            XCTAssertEqual(state.extendedResults.count, throttled ? 3 : 0)
            XCTAssertTrue(state.progress.moreHistory)
        }
    }

    func testPauseQueryAndRepositoryChangesRejectLateResponses() async throws {
        for action in ["pause", "query", "repository"] {
            let fixture = try SearchEngineFixture()
            defer { fixture.cleanup() }
            await fixture.transport.installHistory()
            await fixture.transport.holdNextDetail()
            await fixture.engine.setContext(selectedLogin: "alice", currentPRs: [], repositories: ["org/repo"])
            await fixture.engine.setQuery("needle")
            await fixture.engine.search()
            await fixture.transport.waitUntilHeld()
            switch action {
            case "pause": await fixture.engine.pause()
            case "query": await fixture.engine.setQuery("unrelated")
            default: await fixture.engine.setContext(selectedLogin: "alice", currentPRs: [], repositories: [])
            }
            await fixture.transport.release()
            try await Task.sleep(for: .milliseconds(20))
            let state = await current(fixture.engine)
            XCTAssertTrue(state.extendedResults.isEmpty)
            XCTAssertTrue(try fixture.index.documents().isEmpty)
            XCTAssertEqual(state.phase, action == "pause" ? .paused : .idle)
        }
    }

    func testOmittedPatchKeepsPathMatchButMarksCodePartial() async throws {
        let fixture = try SearchEngineFixture()
        defer { fixture.cleanup() }
        await fixture.transport.installHistory()
        await fixture.transport.omitPatches()
        await fixture.engine.setContext(selectedLogin: "alice", currentPRs: [searchDocument(number: 1).pullRequest], repositories: [])
        await fixture.engine.setQuery("new.swift")
        await fixture.engine.search(extended: false)
        let state = await finished(fixture.engine)
        XCTAssertEqual(state.inYourList.count, 1)
        XCTAssertEqual(state.inYourList.first?.source, .file)
        XCTAssertEqual(state.inYourList.first?.coverage.fileListComplete, true)
        XCTAssertEqual(state.inYourList.first?.coverage.codeComplete, false)
        XCTAssertEqual(state.progress.partial, 1)
    }

    func testLowDiskPausesWithoutDiscardingCurrentResults() async throws {
        let fixture = try SearchEngineFixture(minimumFreeBytes: .max)
        defer { fixture.cleanup() }
        await fixture.transport.installHistory()
        await fixture.engine.setContext(selectedLogin: "alice", currentPRs: [searchDocument(number: 1, title: "needle").pullRequest], repositories: [])
        await fixture.engine.setQuery("needle")
        await fixture.engine.search(extended: false)
        let state = await finished(fixture.engine)
        XCTAssertEqual(state.phase, .paused)
        XCTAssertEqual(state.inYourList.count, 1)
        XCTAssertTrue(state.message?.contains("Low disk") == true)
    }

    func testWorkloadHeadChangeImmediatelyInvalidatesPreviouslyMatchedCode() async throws {
        let fixture = try SearchEngineFixture()
        defer { fixture.cleanup() }
        await fixture.transport.installHistory()
        let original = searchDocument(number: 1).pullRequest
        await fixture.engine.setContext(selectedLogin: "alice", currentPRs: [original], repositories: [])
        await fixture.engine.setQuery("needle")
        await fixture.engine.search(extended: false)
        let initial = await finished(fixture.engine)
        XCTAssertEqual(initial.inYourList.count, 1)
        let changed = PullRequestPresentation(id: original.id, repositoryID: original.repositoryID,
            repositoryNameWithOwner: original.repositoryNameWithOwner, number: 1, title: original.title,
            url: original.url, isDraft: false, updatedAt: Date(), reviewers: [], headSHA: "new-head")
        await fixture.engine.setContext(selectedLogin: "alice", currentPRs: [changed], repositories: [])
        let state = await current(fixture.engine)
        XCTAssertTrue(state.inYourList.isEmpty)
    }

    func testChangedFilesPaginationIncludesCodeOnlyMatchOnSecondPage() async throws {
        let fixture = try SearchEngineFixture()
        defer { fixture.cleanup() }
        await fixture.transport.installHistory()
        await fixture.transport.paginateFiles()
        await fixture.engine.setContext(selectedLogin: "alice", currentPRs: [searchDocument(number: 1).pullRequest], repositories: [])
        await fixture.engine.setQuery("needle")
        await fixture.engine.search(extended: false)
        let state = await finished(fixture.engine)
        XCTAssertEqual(state.inYourList.first?.path, "second.swift")
        XCTAssertEqual(state.inYourList.first?.coverage.codeComplete, true)
        let paths = await fixture.transport.requestPaths()
        XCTAssertTrue(paths.contains { $0.contains("/files?") && $0.hasSuffix("page=2") })
    }

    private func current(_ engine: PRSearchEngine) async -> PRSearchState {
        var iterator = await engine.states().makeAsyncIterator()
        return await iterator.next()!
    }

    private func finished(_ engine: PRSearchEngine) async -> PRSearchState {
        for _ in 0..<500 {
            let state = await current(engine)
            if state.phase != .validating && state.phase != .indexing { return state }
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Search did not settle")
        return await current(engine)
    }
}

private struct SearchEngineFixture {
    let directory: URL
    let index: SQLitePRSearchIndex
    let transport: SearchFixtureTransport
    let engine: PRSearchEngine
    init(minimumFreeBytes: Int64 = 0) throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        index = SQLitePRSearchIndex(directory: directory, minimumFreeBytes: minimumFreeBytes)
        transport = SearchFixtureTransport()
        engine = PRSearchEngine(accountConnection: SearchFixtureConnection(), transport: transport, index: index)
    }
    func cleanup() { try? FileManager.default.removeItem(at: directory) }
}

private struct SearchFixtureConnection: AccountConnection {
    func inspect(selectedLogin: String?) async -> AccountConnectionResult {
        guard let selectedLogin else { return .connectionRequired }
        return .connected(ResolvedAccount(login: selectedLogin, hostname: "github.com", scopes: ["repo"], accessCoverage: AccessCoverage(isComplete: true), accessToken: GitHubAccessToken("\(selectedLogin)-token")))
    }
}

private actor SearchFixtureTransport: PRSearchTransport {
    private var installed = false
    private var paths: [String] = []
    private var held: CheckedContinuation<Void, Never>?
    private var holdDetail = false
    private var revisionChanges = false
    private var fetchedFiles = false
    private var nextFailure: GitHubTransportResponse?
    private var patchesOmitted = false
    private var filesPaginated = false
    func installHistory() { installed = true }
    func requestPaths() -> [String] { paths }
    func holdNextDetail() { holdDetail = true }
    func changeRevisionAfterFiles() { revisionChanges = true }
    func omitPatches() { patchesOmitted = true }
    func paginateFiles() { filesPaginated = true }
    func failNextRequest(status: Int, headers: [String: String]) {
        nextFailure = GitHubTransportResponse(statusCode: status, headers: headers, data: Data())
    }
    func waitUntilHeld() async {
        while held == nil { await Task.yield() }
    }
    func release() { held?.resume(); held = nil }

    func get(path: String, account: ResolvedAccount) async throws -> GitHubTransportResponse {
        paths.append(path)
        if let failure = nextFailure { nextFailure = nil; return failure }
        guard installed else { throw URLError(.notConnectedToInternet) }
        if path.contains("/files?") {
            fetchedFiles = true
            if filesPaginated {
                let first = path.hasSuffix("page=1")
                return response("[{\"filename\":\"\(first ? "first" : "second").swift\",\"additions\":1,\"deletions\":0,\"patch\":\"@@ -0,0 +1 @@\\n+\(first ? "unrelated" : "needle")\"}]",
                    headers: first ? ["link": "<https://api.github.com/next>; rel=\"next\""] : [:])
            }
            if patchesOmitted { return response("[{\"filename\":\"new.swift\",\"additions\":1,\"deletions\":1}]") }
            return response("[{\"filename\":\"new.swift\",\"previous_filename\":\"old.swift\",\"additions\":1,\"deletions\":1,\"patch\":\"@@ -1 +1 @@\\n-old code\\n+needle\"}]")
        }
        if path.contains("/pulls?") {
            let page = URLComponents(string: "https://api.github.com" + path)?.queryItems?.first { $0.name == "page" }?.value
            return page == "1"
                ? response("[\(pull(1))]", headers: ["link": "<https://api.github.com/next>; rel=\"next\""])
                : response("[\(pull(2)),\(pull(3))]")
        }
        if holdDetail { holdDetail = false; await withCheckedContinuation { held = $0 } }
        let number = Int(path.split(separator: "/").last ?? "") ?? 1
        return response(pull(number, head: revisionChanges && fetchedFiles ? "changed" : "head"))
    }

    private func response(_ json: String, headers: [String: String] = [:]) -> GitHubTransportResponse {
        GitHubTransportResponse(statusCode: 200, headers: headers, data: Data(json.utf8))
    }
    private func pull(_ number: Int, head: String = "head") -> String {
        """
        {"node_id":"PR_\(number)","number":\(number),"title":"Routine update","body":"No text candidate",
        "html_url":"https://github.com/org/repo/pull/\(number)","draft":false,"state":"\(number == 1 ? "open" : "closed")",
        "merged_at":\(number == 3 ? "\"2026-10-20T00:00:00Z\"" : "null"),"user":{"login":"author","avatar_url":null},
        "updated_at":"2026-10-21T00:00:00Z","changed_files":\(filesPaginated ? 2 : 1),
        "base":{"sha":"base","repo":{"node_id":"R_repo","full_name":"org/repo"}},"head":{"sha":"\(head)","repo":null}}
        """
    }
}
