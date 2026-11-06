import AppKit
import GitDockCore
import SwiftUI

@MainActor
final class StatusItemController: NSObject, NSPopoverDelegate {
    let appModel: AppModel
    let actions: AppActions
    let workspaceModel: WorkspaceModel
    let avatarImageCache: AvatarImageCache
    let statusItem: NSStatusItem
    let popover = NSPopover()
    private(set) var registeredShortcut: GitDockShortcut?
    private var avatarCacheAccountLogin: String?
    private let searchModel: PRSearchModel?
    private var keyMonitor: Any?

    var isStatusMenuOpen: Bool { popover.isShown }

    init(
        appModel: AppModel,
        actions: AppActions = AppActions(),
        workspaceModel: WorkspaceModel,
        avatarImageCache: AvatarImageCache,
        searchModel: PRSearchModel? = nil
    ) {
        self.appModel = appModel
        self.actions = actions
        self.workspaceModel = workspaceModel
        self.avatarImageCache = avatarImageCache
        self.searchModel = searchModel
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        super.init()
        configureStatusMenu()
        apply(appModel.state)
        appModel.onStateChange = { [weak self] state in self?.apply(state) }
    }

    private func apply(_ state: AppPresentationState) {
        workspaceModel.updateWorkload(state)
        searchModel?.updateWorkload(state)
        let login: String?
        if case let .connected(value, _) = state.accountConnection { login = value } else { login = nil }
        if avatarCacheAccountLogin != login {
            avatarImageCache.removeAll()
            avatarCacheAccountLogin = login
        }
        let urls = (state.needsYourReview + state.authoredPullRequests).flatMap { pullRequest in
            pullRequest.reviewers.compactMap(\.avatarURL) + [pullRequest.author?.avatarURL].compactMap { $0 }
        }
        Task { await avatarImageCache.preload(urls) }
        statusItem.button?.image = StatusIconRenderer.image(reviewCount: state.reviewCount)
        statusItem.button?.setAccessibilityTitle("GitDock. \(state.reviewCountAccessibilityLabel).")
        statusItem.button?.toolTip = "GitDock — \(state.reviewCountAccessibilityLabel)"
        // The existing SwiftUI tree observes AppModel. Never replace it during refresh.
    }

    func showMenu() {
        guard !popover.isShown, let button = statusItem.button else { return }
        let height = PopoverView.resolvedHeight(forVisibleScreenHeight: button.window?.screen?.visibleFrame.height)
        popover.contentSize = NSSize(width: PopoverView.preferredWidth, height: height)
        NSApp.activate(ignoringOtherApps: true)
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
    }

    @objc func toggleMenu() {
        if popover.isShown { closeMenu() } else { showMenu() }
    }

    func closeMenu() { popover.performClose(nil) }

    func setRegisteredShortcut(_ shortcut: GitDockShortcut) { registeredShortcut = shortcut }

    /// Kept for workspace callers; observation updates the persistent popover content.
    func rebuildStatusMenu() {}

    func popoverDidShow(_ notification: Notification) {
        appModel.send(.setWorkloadSurfaceOpen(true))
        installKeyMonitor()
    }

    func popoverDidClose(_ notification: Notification) {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor); self.keyMonitor = nil }
        appModel.send(.setWorkloadSurfaceOpen(false))
    }

    private func installKeyMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.popover.isShown else { return event }
            if event.keyCode == 53 { self.closeMenu(); return nil }
            guard event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command else { return event }
            switch event.charactersIgnoringModifiers?.lowercased() {
            case "r": self.appModel.send(.manualRefresh)
            case "f": self.closeMenu(); self.actions.openSearch()
            case ",": self.closeMenu(); self.actions.openSettings()
            case "q": NSApp.terminate(nil)
            default: return event
            }
            return nil
        }
    }
}
