import AppKit
import GitDockCore
import OSLog

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var appModel: AppModel?
    private var statusItemController: StatusItemController?
    private var settingsWindowController: SettingsWindowController?
    private var workspaceWindowController: WorkspaceWindowController?
    private var workspaceModel: WorkspaceModel?
    private var searchModel: PRSearchModel?
    private var searchWindowController: PRSearchWindowController?
    private var applicationMenuController: ApplicationMenuController?
    private var globalHotKeyController: GlobalHotKeyController?
    private var visualValidationWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppearanceController.applySavedPreference()
        let workloadClient: any GitHubWorkloadClient = ProcessInfo.processInfo.environment["GITHUBBAR_FAILURE_DEMO"] == "1"
            ? UnavailableGitHubWorkloadClient()
            : GraphQLGitHubWorkloadClient()
        let engine = WorkloadEngine(
            accountConnection: GitHubCLIAccountConnection(
                executableLocator: GitHubCLIExecutableLocator(),
                commandRunner: ProcessCommandRunner()
            ),
            workloadClient: workloadClient,
            snapshotStore: FileSnapshotStore(),
            settingsStore: UserDefaultsSettingsStore(),
            diagnostics: OSLogReconciliationDiagnostics(),
            launchAtLoginController: MacLaunchAtLoginController()
        )
        let model = AppModel(engine: engine)
        let searchModel = PRSearchModel(service: CorePRSearchService())
        let workspaceStore = LocalWorkspaceStore()
        let reviewStore = AgentReviewStore()
        let workspaceModel = WorkspaceModel(
            store: workspaceStore,
            sessions: AgentSessionManager(store: workspaceStore),
            reviewStore: reviewStore
        )
        let workspaceWindowController = WorkspaceWindowController(
            appModel: model, workspaceModel: workspaceModel
        )
        let openPullRequest: (PullRequestPresentation) -> Void = { [weak workspaceWindowController] pullRequest in
            workspaceWindowController?.show(pullRequest: pullRequest)
        }
        let searchWindowController = PRSearchWindowController(model: searchModel, openPullRequest: openPullRequest)
        let settingsWindowController = SettingsWindowController(
            appModel: model,
            updateController: UpdateControllerFactory.make()
        )
        let actions = AppActions(
            openSettings: { [weak settingsWindowController] in settingsWindowController?.show() },
            openAbout: { [weak settingsWindowController] in settingsWindowController?.showAbout() },
            openWorkspace: { [weak workspaceWindowController] subject in
                workspaceWindowController?.show(subject: subject)
            },
            openSearch: { [weak searchWindowController] in searchWindowController?.show() },
            openPullRequest: openPullRequest
        )
        let statusItemController = StatusItemController(
            appModel: model,
            actions: actions,
            workspaceModel: workspaceModel,
            avatarImageCache: AvatarImageCache(),
            searchModel: searchModel
        )
        let applicationMenuController = ApplicationMenuController(appModel: model, actions: actions)
        applicationMenuController.install()

        appModel = model
        self.statusItemController = statusItemController
        self.settingsWindowController = settingsWindowController
        self.workspaceWindowController = workspaceWindowController
        self.workspaceModel = workspaceModel
        self.searchModel = searchModel
        self.searchWindowController = searchWindowController
        self.applicationMenuController = applicationMenuController

        let shortcut = GitDockShortcut.openMenu
        do {
            globalHotKeyController = try GlobalHotKeyController(shortcut: shortcut) { [weak statusItemController] in
                statusItemController?.toggleMenu()
            }
            statusItemController.setRegisteredShortcut(shortcut)
        } catch {
            Logger(subsystem: "com.franciscomoretti.githubbar", category: "shortcut")
                .error("Could not register the global menu shortcut: \(String(describing: error), privacy: .public)")
        }

        model.start()
        workspaceModel.onDocumentChange = { [weak statusItemController] in
            statusItemController?.rebuildStatusMenu()
        }
        workspaceModel.start()
        model.send(.launch)
        workspaceWindowController.show()

        if ProcessInfo.processInfo.environment["GITHUBBAR_OPEN_MENU"] == "1" {
            DispatchQueue.main.async {
                statusItemController.showMenu()
            }
        }

        if ProcessInfo.processInfo.environment["GITHUBBAR_VISUAL_VALIDATION"] == "1" {
            showVisualValidationWindow(
                statusItemController: statusItemController
            )
        }
        if ProcessInfo.processInfo.environment["GITHUBBAR_OPEN_SETTINGS"] == "1" {
            DispatchQueue.main.async {
                settingsWindowController.show()
            }
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        workspaceWindowController?.show()
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationWillTerminate(_ notification: Notification) {
        appModel?.stop()
        workspaceModel?.stop()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        Task {
            searchModel?.pause()
            await searchModel?.pendingCommand?.value
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    private func showVisualValidationWindow(statusItemController: StatusItemController) {
        let height: CGFloat = 640
        let window = NSWindow(
            contentRect: NSRect(
                x: 0,
                y: 0,
                width: 390,
                height: height
            ),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "GitDock Visual Validation"
        let background = NSView()
        background.wantsLayer = true
        background.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        let openMenuButton = NSButton(title: "Open GitDock menu", target: self, action: #selector(openMenuValidation))
        openMenuButton.frame = NSRect(x: 110, y: height / 2 - 16, width: 170, height: 32)
        background.addSubview(openMenuButton)
        window.contentView = background
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        visualValidationWindow = window
    }

    @objc private func openMenuValidation() {
        statusItemController?.showMenu()
    }
}
