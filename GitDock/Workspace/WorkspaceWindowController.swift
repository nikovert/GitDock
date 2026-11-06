import AppKit
import GitDockCore
import SwiftUI

@MainActor
final class WorkspaceWindow: NSWindow {
    let textSize: WorkspaceTextSize
    init(textSize: WorkspaceTextSize) {
        self.textSize = textSize
        super.init(contentRect: NSRect(x: 0, y: 0, width: 1380, height: 860),
            styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        isReleasedWhenClosed = false
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard attachedSheet == nil, event.type == .keyDown, event.modifierFlags.contains(.command),
              event.modifierFlags.intersection([.control, .option]).isEmpty else {
            return super.performKeyEquivalent(with: event)
        }
        switch event.charactersIgnoringModifiers {
        case "+", "=": textSize.increase(); return true
        case "-": textSize.decrease(); return true
        case "0": textSize.reset(); return true
        default: return super.performKeyEquivalent(with: event)
        }
    }

    private var allowsTextActions: Bool { attachedSheet == nil && NSApp.keyWindow === self }
    @objc func makeWorkspaceTextLarger(_ sender: Any?) { if allowsTextActions { textSize.increase() } }
    @objc func makeWorkspaceTextSmaller(_ sender: Any?) { if allowsTextActions { textSize.decrease() } }
    @objc func resetWorkspaceTextSize(_ sender: Any?) { if allowsTextActions { textSize.reset() } }

    override func validateUserInterfaceItem(_ item: any NSValidatedUserInterfaceItem) -> Bool {
        switch item.action {
        case #selector(makeWorkspaceTextLarger(_:)): return allowsTextActions && textSize.canIncrease
        case #selector(makeWorkspaceTextSmaller(_:)): return allowsTextActions && textSize.canDecrease
        case #selector(resetWorkspaceTextSize(_:)): return allowsTextActions
        default: return super.validateUserInterfaceItem(item)
        }
    }
}

@MainActor
final class WorkspaceWindowController {
    private let appModel: AppModel
    private let workspaceModel: WorkspaceModel
    private let textSize = WorkspaceTextSize()
    private var window: NSWindow?

    init(appModel: AppModel, workspaceModel: WorkspaceModel) {
        self.appModel = appModel
        self.workspaceModel = workspaceModel
    }

    func show(subject: BoardSubject? = nil) {
        if let subject { workspaceModel.selectedSubject = subject }
        if window == nil { window = makeWindow() }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        Task { await workspaceModel.reload() }
    }

    func show(pullRequest: PullRequestPresentation) {
        workspaceModel.openPullRequest(pullRequest)
        show()
    }

    private func makeWindow() -> NSWindow {
        let window = WorkspaceWindow(textSize: textSize)
        window.title = "GitDock Workspace"
        window.isReleasedWhenClosed = false
        window.contentMinSize = NSSize(width: 900, height: 650)
        window.contentView = NSHostingView(
            rootView: ReviewWorkspaceView(workspace: workspaceModel, appModel: appModel, textSize: textSize)
        )
        window.setFrameAutosaveName("GitHubBarReviewWorkspace")
        window.center()
        return window
    }
}
