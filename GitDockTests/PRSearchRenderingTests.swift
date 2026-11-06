import AppKit
import SwiftUI
import XCTest
@testable import GitDockCore
@testable import GitDock

@MainActor
final class PRSearchRenderingTests: XCTestCase {
    func testSearchRendersLongResultsAndCoverageInBothAppearances() async throws {
        let service = RenderSearchService()
        let model = PRSearchModel(service: service)
        var workload = AppPresentationState.empty
        workload.accountConnection = .connected(login: "reviewer", accessCoverage: AccessCoverage(isComplete: true))
        workload.availableRepositories = [RepositoryChoice(id: "repo", nameWithOwner: "example/project")]
        model.updateWorkload(workload)
        model.setQuery("controller")
        model.setExtended(true)
        await model.pendingCommand?.value
        for _ in 0..<100 where model.state.inYourList.isEmpty {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(model.state.inYourList.count, 1)
        let directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent(".build/ui-previews")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            let view = NSHostingView(rootView: PRSearchView(model: model))
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 900),
                                  styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.appearance = NSAppearance(named: appearance)
            window.contentView = view
            view.frame = NSRect(x: 0, y: 0, width: 900, height: 900)
            view.layoutSubtreeIfNeeded()
            let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
            view.cacheDisplay(in: view.bounds, to: bitmap)
            let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
            try png.write(to: directory.appendingPathComponent("search-\(name).png"))
            window.close()
        }
        model.close()
    }
}

private actor RenderSearchService: PRSearchServing {
    private var queryText = ""
    private var continuation: AsyncStream<PRSearchState>.Continuation?
    func states() -> AsyncStream<PRSearchState> {
        let (stream, continuation) = AsyncStream.makeStream(of: PRSearchState.self)
        self.continuation = continuation
        continuation.yield(snapshot())
        return stream
    }
    private func snapshot() -> PRSearchState {
        var state = PRSearchState()
        state.query = queryText
        state.phase = .paused
        state.progress.discovered = 412
        state.progress.indexed = 286
        state.progress.partial = 8
        state.message = "Paused. Remaining history has not been searched; missing patches limit code coverage."
        state.inYourList = [result(number: 24, title: "Improve controller stability when measurements arrive late and preserve fallback behavior", source: .code)]
        state.extendedResults = [result(number: 7, title: "Document the controller configuration", source: .description)]
        return state
    }
    func configure(login: String?, current: [PullRequestPresentation], repositories: [String]) {}
    func query(_ value: String) { queryText = value; continuation?.yield(snapshot()) }
    func search(extended: Bool) {}
    func pause() {}
    func clear() {}

    private func result(number: Int, title: String, source: PRSearchSource) -> PRSearchResult {
        PRSearchResult(pullRequest: PullRequestPresentation(
            id: "pr-\(number)", repositoryID: "repo", repositoryNameWithOwner: "example/project",
            number: number, title: title, url: URL(string: "https://github.com/example/project/pull/\(number)")!,
            isDraft: false, state: number == 7 ? .merged : .open,
            author: PullRequestAuthorPresentation(id: "colleague", displayName: "colleague", avatarURL: nil),
            updatedAt: .now, reviewers: []), source: source,
            excerpt: "controller = Controller(config: configuration, fallback: .lastKnownGood)",
            path: source == .code ? "Sources/Control/Controller.swift" : nil,
            lineKind: source == .code ? .added : nil,
            coverage: PRSearchCoverage(fileListComplete: true, codeComplete: false, reasons: ["One patch was omitted by GitHub"]),
            score: 1_100)
    }
}
