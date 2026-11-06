import AppKit
import XCTest
@testable import GitDock

@MainActor
final class WorkspaceTextSizeTests: XCTestCase {
    func testTextMenuOnlyActsInWorkspaceAndDisablesAtBounds() throws {
        try withDefaults { defaults in
            _ = NSApplication.shared
            let size = WorkspaceTextSize(defaults: defaults)
            let window = WorkspaceWindow(textSize: size)
            let other = NSWindow(contentRect: .init(x: 0, y: 0, width: 300, height: 200), styleMask: [.titled], backing: .buffered, defer: false)
            other.isReleasedWhenClosed = false
            defer { window.close(); other.close() }
            let increase = NSMenuItem(title: "Larger", action: #selector(WorkspaceWindow.makeWorkspaceTextLarger(_:)), keyEquivalent: "+")
            let decrease = NSMenuItem(title: "Smaller", action: #selector(WorkspaceWindow.makeWorkspaceTextSmaller(_:)), keyEquivalent: "-")
            window.makeKeyAndOrderFront(nil)
            guard NSApp.keyWindow === window else {
                throw XCTSkip("The SwiftPM host cannot make a native window key; check View-menu focus validation in the running app.")
            }
            XCTAssertTrue(window.validateUserInterfaceItem(increase))
            for _ in 0..<10 { window.makeWorkspaceTextLarger(nil) }
            XCTAssertEqual(size.workspaceScale, 2)
            XCTAssertFalse(window.validateUserInterfaceItem(increase))
            XCTAssertTrue(window.validateUserInterfaceItem(decrease))
            other.makeKeyAndOrderFront(nil)
            XCTAssertFalse(window.validateUserInterfaceItem(decrease))
            window.makeWorkspaceTextSmaller(nil)
            XCTAssertEqual(size.workspaceScale, 2)
            window.makeKeyAndOrderFront(nil)
            window.resetWorkspaceTextSize(nil)
            XCTAssertEqual(size.workspaceScale, 1)
        }
    }

    func testCommandPlusEqualsMinusAndZeroWorkWhileTypingInChat() throws {
        try withDefaults { defaults in
            _ = NSApplication.shared
            let size = WorkspaceTextSize(defaults: defaults)
            let window = WorkspaceWindow(textSize: size)
            defer { window.close() }
            let editor = ComposerTextView(frame: NSRect(x: 0, y: 0, width: 300, height: 100))
            editor.string = "Unsent question"
            window.contentView = editor
            window.makeFirstResponder(editor)
            for (characters, modifiers) in [("=", NSEvent.ModifierFlags.command), ("+", [.command, .shift]), ("+", .command)] {
                XCTAssertTrue(window.performKeyEquivalent(with: key(characters, modifiers: modifiers)))
            }
            XCTAssertEqual(size.workspaceScale, 1.3, accuracy: 0.001)
            XCTAssertEqual(size.chatScale, 1.3, accuracy: 0.001)
            XCTAssertTrue(window.performKeyEquivalent(with: key("-")))
            XCTAssertEqual(size.workspaceScale, 1.2, accuracy: 0.001)
            XCTAssertTrue(window.performKeyEquivalent(with: key("0")))
            XCTAssertEqual(size.workspaceScale, 1)
            XCTAssertEqual(size.chatScale, 1)
            XCTAssertEqual(editor.string, "Unsent question")
            XCTAssertFalse(window.performKeyEquivalent(with: key("+", modifiers: [.command, .option])))
            XCTAssertEqual(size.workspaceScale, 1)
        }
    }

    func testWorkspaceZoomIncludesChatAndChatCanBeAdjustedSeparately() throws {
        try withDefaults { defaults in
            let size = WorkspaceTextSize(defaults: defaults)
            size.increase()
            XCTAssertEqual(size.workspaceScale, 1.1, accuracy: 0.001)
            XCTAssertEqual(size.chatScale, 1.1, accuracy: 0.001)
            size.increaseChat()
            XCTAssertEqual(size.workspaceScale, 1.1, accuracy: 0.001)
            XCTAssertEqual(size.chatScale, 1.2, accuracy: 0.001)
            size.decrease()
            XCTAssertEqual(size.workspaceScale, 1, accuracy: 0.001)
            XCTAssertEqual(size.chatScale, 1.1, accuracy: 0.001)
            let restored = WorkspaceTextSize(defaults: defaults)
            XCTAssertEqual(restored.chatScale, 1.1, accuracy: 0.001)
            size.resetChat()
            XCTAssertEqual(size.chatScale, 1)
            size.increase()
            size.reset()
            XCTAssertEqual(size.workspaceScale, 1)
            XCTAssertEqual(size.chatScale, 1)
            XCTAssertEqual(WorkspaceTextSize(defaults: defaults).workspaceScale, 1)
        }
    }

    func testZoomBoundsPreventUnreadableOrUnusableSizes() throws {
        try withDefaults { defaults in
            let size = WorkspaceTextSize(defaults: defaults)
            for _ in 0..<100 { size.increase() }
            XCTAssertEqual(size.workspaceScale, 2)
            XCTAssertEqual(size.chatScale, 2)
            for _ in 0..<100 { size.decrease() }
            XCTAssertEqual(size.workspaceScale, 0.8, accuracy: 0.001)
            XCTAssertEqual(size.chatScale, 0.8, accuracy: 0.001)
            size.increaseChat()
            XCTAssertEqual(size.workspaceScale, 0.8, accuracy: 0.001)
            XCTAssertEqual(size.chatScale, 0.9, accuracy: 0.001)
        }
    }

    func testInvalidStoredSizesAreClampedOnLoad() throws {
        try withDefaults { defaults in
            defaults.set(9999, forKey: "workspace.text.workspaceStep")
            defaults.set(-9999, forKey: "workspace.text.chatStep")
            let size = WorkspaceTextSize(defaults: defaults)
            XCTAssertEqual(size.workspaceScale, 2)
            XCTAssertEqual(size.chatScale, 0.8, accuracy: 0.001)
        }
    }

    private func withDefaults(_ run: (UserDefaults) throws -> Void) throws {
        let name = "WorkspaceTextSizeTests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        try run(defaults)
    }
    private func key(_ text: String, modifiers: NSEvent.ModifierFlags = .command) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0,
            windowNumber: 0, context: nil, characters: text, charactersIgnoringModifiers: text,
            isARepeat: false, keyCode: 24)!
    }
}
