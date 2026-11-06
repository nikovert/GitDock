import AppKit
import XCTest
@testable import GitDock

@MainActor
final class MultilineComposerTests: XCTestCase {
    func testChangingTextSizePreservesDraftAndSelection() {
        let editor = ComposerTextView()
        editor.string = "Keep this draft"
        editor.setSelectedRange(NSRange(location: 5, length: 4))
        editor.setWorkspaceTextScale(1.5)
        XCTAssertEqual(editor.font?.pointSize ?? 0, NSFont.systemFontSize * 1.5, accuracy: 0.001)
        XCTAssertEqual(editor.string, "Keep this draft")
        XCTAssertEqual(editor.selectedRange(), NSRange(location: 5, length: 4))
    }

    func testZoomWaitsForInputCompositionToFinish() {
        let editor = ComposerTextView()
        editor.setWorkspaceTextScale(1)
        editor.setMarkedText("日本", selectedRange: NSRange(location: 2, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        editor.setWorkspaceTextScale(2)
        XCTAssertTrue(editor.hasMarkedText())
        XCTAssertEqual(editor.font?.pointSize ?? 0, NSFont.systemFontSize, accuracy: 0.001)
        editor.unmarkText()
        XCTAssertEqual(editor.font?.pointSize ?? 0, NSFont.systemFontSize * 2, accuracy: 0.001)
        XCTAssertEqual(editor.string, "日本")
    }

    func testReturnSubmitsWithoutInsertingNewlineAndIgnoresKeyRepeat() {
        let editor = ComposerTextView()
        editor.string = "Explain the change"
        var submissions = 0
        editor.onSubmit = { submissions += 1 }
        editor.keyDown(with: event(isRepeat: true))
        XCTAssertEqual(submissions, 0)
        editor.keyDown(with: event())
        editor.keyDown(with: event())
        XCTAssertEqual(submissions, 1)
        XCTAssertEqual(editor.string, "Explain the change")
    }

    func testControlReturnInsertsNewline() {
        let editor = ComposerTextView()
        editor.string = "first"
        editor.setSelectedRange(NSRange(location: 5, length: 0))
        var submissions = 0
        editor.onSubmit = { submissions += 1 }
        editor.keyDown(with: event(modifiers: .control))
        XCTAssertEqual(editor.string, "first\n")
        XCTAssertEqual(submissions, 0)
    }

    func testDisabledAndBlankComposerCannotSubmit() {
        let editor = ComposerTextView()
        var submissions = 0
        editor.onSubmit = { submissions += 1 }
        editor.string = " \n "
        editor.keyDown(with: event())
        editor.string = "question"
        editor.submissionEnabled = false
        editor.keyDown(with: event())
        XCTAssertEqual(submissions, 0)
    }

    func testEmptyReturnSubmitsOnlyWhenExplicitlyAllowed() {
        let editor = ComposerTextView()
        var submissions = 0
        editor.onSubmit = { submissions += 1 }
        editor.keyDown(with: event())
        XCTAssertEqual(submissions, 0)
        editor.allowsEmpty = true
        editor.keyDown(with: event())
        XCTAssertEqual(submissions, 1)
    }

    func testReturnWithMarkedTextCommitsCompositionWithoutSubmitting() {
        let editor = ComposerTextView()
        var submissions = 0
        editor.onSubmit = { submissions += 1 }
        editor.setMarkedText("日本", selectedRange: NSRange(location: 2, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertTrue(editor.hasMarkedText())
        editor.keyDown(with: event())
        XCTAssertEqual(submissions, 0)
        XCTAssertTrue(editor.string.contains("日本"))
    }

    private func event(modifiers: NSEvent.ModifierFlags = [], isRepeat: Bool = false) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers,
                        timestamp: 0, windowNumber: 0, context: nil, characters: "\r",
                        charactersIgnoringModifiers: "\r", isARepeat: isRepeat, keyCode: 36)!
    }
}
