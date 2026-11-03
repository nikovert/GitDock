import AppKit
import GitHubBarCore

@MainActor
final class ApplicationMenuController: NSObject {
    private let appModel: AppModel
    private let actions: AppActions

    init(appModel: AppModel, actions: AppActions) {
        self.appModel = appModel
        self.actions = actions
        super.init()
    }

    func install() {
        let mainMenu = NSMenu()
        let applicationItem = NSMenuItem()
        let applicationMenu = NSMenu(title: "GitHubBar")

        applicationMenu.addItem(
            NSMenuItem(title: "About GitHubBar", action: #selector(showAbout), keyEquivalent: "")
        )
        applicationMenu.addItem(.separator())
        applicationMenu.addItem(
            NSMenuItem(title: "Search PRs…", action: #selector(showSearch), keyEquivalent: "f")
        )
        applicationMenu.addItem(
            NSMenuItem(title: "Refresh", action: #selector(refresh), keyEquivalent: "r")
        )
        applicationMenu.addItem(
            NSMenuItem(title: "Workspace Board…", action: #selector(showWorkspace), keyEquivalent: "b")
        )
        applicationMenu.addItem(
            NSMenuItem(title: "Settings…", action: #selector(showSettings), keyEquivalent: ",")
        )
        applicationMenu.addItem(.separator())
        applicationMenu.addItem(
            NSMenuItem(title: "Quit GitHubBar", action: #selector(quit), keyEquivalent: "q")
        )

        for item in applicationMenu.items {
            item.target = self
        }
        applicationItem.submenu = applicationMenu
        mainMenu.addItem(applicationItem)
        let viewItem = NSMenuItem()
        let viewMenu = NSMenu(title: "View")
        viewMenu.addItem(NSMenuItem(title: "Make Text Larger", action: #selector(WorkspaceWindow.makeWorkspaceTextLarger(_:)), keyEquivalent: "+"))
        viewMenu.addItem(NSMenuItem(title: "Make Text Smaller", action: #selector(WorkspaceWindow.makeWorkspaceTextSmaller(_:)), keyEquivalent: "-"))
        viewMenu.addItem(NSMenuItem(title: "Actual Text Size", action: #selector(WorkspaceWindow.resetWorkspaceTextSize(_:)), keyEquivalent: "0"))
        viewItem.submenu = viewMenu
        mainMenu.addItem(viewItem)
        NSApp.mainMenu = mainMenu
    }

    @objc private func refresh() {
        appModel.send(.manualRefresh)
    }

    @objc private func showSettings() {
        actions.openSettings()
    }

    @objc private func showSearch() {
        actions.openSearch()
    }

    @objc private func showWorkspace() {
        actions.openWorkspace(nil)
    }

    @objc private func showAbout() {
        actions.openAbout()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}
