import AppKit
import GitDockCore
import SwiftUI

@MainActor
final class PRSearchWindowController: NSObject, NSWindowDelegate {
    private let model: PRSearchModel
    private var window: NSWindow?
    private let openPullRequest: (PullRequestPresentation) -> Void

    init(model: PRSearchModel, openPullRequest: @escaping (PullRequestPresentation) -> Void) {
        self.model = model
        self.openPullRequest = openPullRequest
    }

    func show() {
        if window == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 900, height: 760),
                styleMask: [.titled, .closable, .miniaturizable, .resizable],
                backing: .buffered, defer: false
            )
            window.title = "Search PRs — GitDock"
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.contentMinSize = NSSize(width: 720, height: 560)
            window.contentView = NSHostingView(rootView: PRSearchView(model: model, openPullRequest: openPullRequest))
            window.center()
            self.window = window
        }
        model.focusRequest = UUID()
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowWillClose(_ notification: Notification) { model.close() }
}
