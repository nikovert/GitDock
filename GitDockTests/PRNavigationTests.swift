import AppKit
import GitDockCore
import XCTest
import SwiftUI
@testable import GitDockCore
@testable import GitDock

@MainActor
final class PRNavigationTests: XCTestCase {
    func testStatusItemUsesAnchoredTransientPopover() throws {
        let fixture = fixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let controller = menu(workspace: fixture.model, actions: AppActions())
        defer { NSStatusBar.system.removeStatusItem(controller.statusItem) }
        XCTAssertNil(controller.statusItem.menu)
        XCTAssertEqual(controller.popover.behavior, .transient)
        XCTAssertNotNil(controller.popover.contentViewController)
        XCTAssertNotNil(controller.statusItem.button?.action)
    }

    func testWorkspaceRefreshRetainsPopoverHostingTree() throws {
        let fixture = fixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let controller = menu(workspace: fixture.model, actions: AppActions())
        defer { NSStatusBar.system.removeStatusItem(controller.statusItem) }
        let content = try XCTUnwrap(controller.popover.contentViewController)
        controller.rebuildStatusMenu()
        controller.setRegisteredShortcut(.openMenu)
        XCTAssertTrue(controller.popover.contentViewController === content,
                      "Workload refresh must preserve SwiftUI scroll and stack expansion state")
    }

    func testNativePopoverToggleRetainsContentAndEscapeDismisses() async throws {
        let fixture = fixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let controller = menu(workspace: fixture.model, actions: AppActions())
        defer {
            controller.closeMenu()
            controller.appModel.stop()
            NSStatusBar.system.removeStatusItem(controller.statusItem)
        }
        let content = try XCTUnwrap(controller.popover.contentViewController)
        // Test hosts can receive zero-height status-item scene windows when the menu bar is hidden.
        // Use a visible native anchor to exercise presentation independently of system bar visibility.
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 500, height: 300),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let anchor = NSButton(frame: NSRect(x: 200, y: 200, width: 30, height: 24))
        window.contentView?.addSubview(anchor)
        window.makeKeyAndOrderFront(nil)
        defer { window.close() }
        func show() {
            controller.showMenu()
            if controller.statusItem.button?.window?.frame.height == 0 {
                // A zero-height system scene cannot anchor a popover. Use the same popover and
                // delegate lifecycle with our visible window for native presentation.
                controller.popover.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .minY)
                controller.popover.contentViewController?.view.window?.makeKey()
            }
        }
        show()
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertTrue(controller.popover.isShown)
        controller.appModel.start()
        controller.appModel.send(.manualRefresh)
        for _ in 0..<100 {
            if case .connectionRequired = controller.appModel.state.accountConnection { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        guard case .connectionRequired = controller.appModel.state.accountConnection else {
            XCTFail("The in-memory unavailable account fixture should publish the refresh result")
            return
        }
        XCTAssertTrue(controller.popover.contentViewController === content)
        XCTAssertTrue(controller.popover.isShown, "Refresh result publication must not dismiss the open popover")
        controller.toggleMenu()
        XCTAssertFalse(controller.popover.isShown)
        show()
        XCTAssertTrue(controller.popover.isShown)
        let popoverWindow = try XCTUnwrap(content.view.window)
        let escape = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: popoverWindow.windowNumber, context: nil,
            characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53))
        NSApp.sendEvent(escape)
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertFalse(controller.popover.isShown)
    }

    func testExternalSearchSelectionHydratesBoardAndSurvivesReload() async throws {
        let fixture = fixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let pr = pullRequest()
        fixture.model.openPullRequest(pr)
        await fixture.model.reload()
        let subject = try XCTUnwrap(fixture.model.selectedSubject)
        XCTAssertEqual(subject, .pullRequest(try PullRequestKey(url: pr.url)))
        let rows = fixture.model.pullRequests(in: .empty)
        let details = try XCTUnwrap(BoardSubjectDetails.resolve(subject: subject, pullRequests: rows, stacks: []))
        XCTAssertEqual(details.primary.title, "External PR with useful metadata")
        XCTAssertEqual(details.primary.author?.displayName, "Alice")
        XCTAssertEqual(details.primary.requestedReviewers?.map(\.displayName), ["Bob"])
        XCTAssertEqual(details.primary.state, .merged)
        XCTAssertEqual(details.primary.headSHA, "head-42")
        XCTAssertEqual(rows.count, 1)
        var workload = AppPresentationState.empty
        workload.needsYourReview = [pr]
        XCTAssertEqual(fixture.model.pullRequests(in: workload).count, 1)
    }

    func testSearchRowPrimaryAndSecondaryClicksHaveSeparateRoutes() async throws {
        var opened: [PullRequestPresentation] = []
        var urls: [URL] = []
        let pr = pullRequest()
        let result = PRSearchResult(pullRequest: pr, source: .title, excerpt: "Matched title",
            path: nil, lineKind: nil, coverage: PRSearchCoverage(), score: 1)
        let host = NSHostingView(rootView: PRSearchResultRow(result: result,
            openPullRequest: { opened.append($0) }, openGitHub: { urls.append($0) }))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 220),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.close() }
        host.frame = NSRect(x: 0, y: 0, width: 700, height: 220)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        try await Task.sleep(for: .milliseconds(50))
        host.layoutSubtreeIfNeeded()
        func send(_ type: NSEvent.EventType) {
            let point = host.convert(NSPoint(x: 100, y: host.bounds.midY), to: nil)
            let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                context: nil, eventNumber: 1, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0)!
            NSApp.sendEvent(event)
        }
        send(.leftMouseDown)
        send(.leftMouseUp)
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertEqual(opened, [pr])
        XCTAssertTrue(urls.isEmpty)
        send(.rightMouseDown)
        send(.rightMouseUp)
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertEqual(opened, [pr])
        XCTAssertEqual(urls, [pr.url])
    }

    func testAccountSwitchClearsExternalSelectionAndMetadata() throws {
        let fixture = fixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        var state = AppPresentationState.empty
        state.accountConnection = .connected(login: "first", accessCoverage: AccessCoverage(isComplete: true))
        fixture.model.updateWorkload(state)
        fixture.model.openPullRequest(pullRequest())
        XCTAssertEqual(fixture.model.pullRequests(in: state).count, 1)
        state.accountConnection = .connected(login: "second", accessCoverage: AccessCoverage(isComplete: true))
        fixture.model.updateWorkload(state)
        XCTAssertNil(fixture.model.selectedSubject)
        XCTAssertTrue(fixture.model.pullRequests(in: state).isEmpty)
    }

    func testStackEntriesAreGroupedWithoutHidingMembers() {
        let pr = pullRequest(stack: true)
        let stack = PullRequestStack(id: "stack", number: 42, pullRequests: [pr])
        let entries = WorkloadSection.entries(pullRequests: [pr, pr], stacks: [stack])
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries.first?.pullRequest, pr)
        XCTAssertEqual(entries.first?.stack?.pullRequests, [pr])
    }

    func testPopoverRowPrimaryAndSecondaryClicksHaveSeparateRoutes() async throws {
        var opened: [PullRequestPresentation] = []
        var urls: [URL] = []
        let pr = pullRequest()
        let host = NSHostingView(rootView: PullRequestRow(pullRequest: pr, showsRepository: true,
            actions: AppActions(openPullRequest: { opened.append($0) }, openGitHub: { urls.append($0) })))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 440, height: 100),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.close() }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        try await Task.sleep(for: .milliseconds(50))
        host.layoutSubtreeIfNeeded()
        func send(_ type: NSEvent.EventType) {
            let point = host.convert(NSPoint(x: 100, y: host.bounds.midY), to: nil)
            let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                context: nil, eventNumber: 1, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0)!
            NSApp.sendEvent(event)
        }
        send(.leftMouseDown)
        send(.leftMouseUp)
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertEqual(opened, [pr])
        XCTAssertTrue(urls.isEmpty)
        send(.rightMouseDown)
        send(.rightMouseUp)
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertEqual(opened, [pr])
        XCTAssertEqual(urls, [pr.url])
    }

    private func menu(workspace: WorkspaceModel, actions: AppActions, stack: Bool = false) -> StatusItemController {
        var state = AppPresentationState.empty
        state.accountConnection = .connected(login: "reviewer", accessCoverage: AccessCoverage(isComplete: true))
        state.needsYourReview = [pullRequest(stack: stack)]
        if stack { state.pullRequestStacks = [PullRequestStack(id: "stack", number: 42, pullRequests: state.needsYourReview)] }
        return StatusItemController(
            appModel: AppModel(engine: WorkloadEngine(initialState: state), initialState: state),
            actions: actions, workspaceModel: workspace, avatarImageCache: AvatarImageCache()
        )
    }

    private func mouseEvent(_ type: NSEvent.EventType) -> NSEvent {
        NSEvent.mouseEvent(with: type, location: .zero, modifierFlags: [], timestamp: 0,
                          windowNumber: 0, context: nil, eventNumber: 1, clickCount: 1, pressure: 1)!
    }

    private func fixture() -> (directory: URL, model: WorkspaceModel) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("pr-navigation-\(UUID())")
        let store = LocalWorkspaceStore(directoryURL: directory)
        return (directory, WorkspaceModel(store: store,
            sessions: AgentSessionManager(store: store, tmuxURL: nil),
            reviewStore: AgentReviewStore(directoryURL: directory)))
    }

    private func pullRequest(stack: Bool = false) -> PullRequestPresentation {
        PullRequestPresentation(id: "external", repositoryID: "repo", repositoryNameWithOwner: "example/repo",
            number: 42, title: "External PR with useful metadata", url: URL(string: "https://github.com/example/repo/pull/42")!,
            isDraft: false, state: .merged,
            author: PullRequestAuthorPresentation(id: "author", displayName: "Alice", avatarURL: nil),
            reviewDecision: .approved,
            stackMembership: stack ? PullRequestStackMembership(id: "stack", number: 42, size: 1, position: 1) : nil,
            updatedAt: Date(timeIntervalSince1970: 100),
            requestedReviewers: [ReviewerPresentation(id: "reviewer", displayName: "Bob", avatarURL: nil, kind: .person)],
            reviewers: [], headSHA: "head-42")
    }
}
