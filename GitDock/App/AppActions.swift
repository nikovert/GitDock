import AppKit
import GitDockCore

@MainActor
struct AppActions {
    let openSettings: () -> Void
    let openAbout: () -> Void
    let openWorkspace: (BoardSubject?) -> Void
    let openSearch: () -> Void
    let openPullRequest: (PullRequestPresentation) -> Void
    let openGitHub: (URL) -> Void

    init(
        openSettings: @escaping () -> Void = {},
        openAbout: @escaping () -> Void = { NSApp.orderFrontStandardAboutPanel(nil) },
        openWorkspace: @escaping (BoardSubject?) -> Void = { _ in },
        openSearch: @escaping () -> Void = {},
        openPullRequest: @escaping (PullRequestPresentation) -> Void = { _ in },
        openGitHub: @escaping (URL) -> Void = { NSWorkspace.shared.open($0) }
    ) {
        self.openSettings = openSettings
        self.openAbout = openAbout
        self.openWorkspace = openWorkspace
        self.openSearch = openSearch
        self.openPullRequest = openPullRequest
        self.openGitHub = openGitHub
    }
}
