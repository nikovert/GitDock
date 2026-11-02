import AppKit
import SwiftUI

@MainActor
extension StatusItemController {
    func configureStatusMenu() {
        guard let button = statusItem.button else { return }
        button.imagePosition = .imageOnly
        button.imageScaling = .scaleNone
        button.target = self
        button.action = #selector(toggleMenu)
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        popover.behavior = .transient
        popover.animates = false
        popover.delegate = self
        let closingActions = AppActions(
            openSettings: { [weak self] in self?.closeMenu(); self?.actions.openSettings() },
            openAbout: { [weak self] in self?.closeMenu(); self?.actions.openAbout() },
            openWorkspace: { [weak self] subject in self?.closeMenu(); self?.actions.openWorkspace(subject) },
            openSearch: { [weak self] in self?.closeMenu(); self?.actions.openSearch() },
            openPullRequest: { [weak self] pullRequest in self?.closeMenu(); self?.actions.openPullRequest(pullRequest) },
            openGitHub: { [weak self] url in self?.actions.openGitHub(url) }
        )
        popover.contentViewController = NSHostingController(rootView: PopoverView(
            appModel: appModel,
            actions: closingActions,
            avatarImageCache: avatarImageCache,
            workspaceModel: workspaceModel
        ))
    }
}
