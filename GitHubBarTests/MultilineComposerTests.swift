import AppKit
import XCTest
@testable import GitHubBar

@MainActor
final class MultilineComposerTests: XCTestCase {
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
