import AppKit
import SwiftUI

/// A multiline editor whose Return action is shared by chat and review composers.
/// `isEnabled` controls submission; the draft stays editable while it is unavailable.
struct MultilineComposer: NSViewRepresentable {
    @Binding var text: String
    var placeholder: String
    var isEnabled: Bool
    var actionLabel: String = "Submit"
    var allowsEmpty = false
    var onSubmit: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        scroll.drawsBackground = true
        let editor = ComposerTextView()
        editor.isRichText = false
        editor.isAutomaticQuoteSubstitutionEnabled = false
        editor.isAutomaticDashSubstitutionEnabled = false
        editor.font = .systemFont(ofSize: NSFont.systemFontSize)
        editor.textContainerInset = NSSize(width: 6, height: 8)
        editor.minSize = NSSize(width: 0, height: 0)
        editor.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        editor.isVerticallyResizable = true
        editor.isHorizontallyResizable = false
        editor.autoresizingMask = [.width]
        editor.textContainer?.widthTracksTextView = true
        editor.delegate = context.coordinator
        editor.setAccessibilityLabel(placeholder)
        editor.setAccessibilityHelp("Enter to \(actionLabel.lowercased()). Control-Enter to insert a new line.")
        scroll.documentView = editor
        updateNSView(scroll, context: context)
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let editor = scroll.documentView as? ComposerTextView else { return }
        // Replacing marked text interrupts an input method's composition.
        if editor.string != text, !editor.hasMarkedText() { editor.string = text }
        editor.setAccessibilityLabel(placeholder)
        editor.setAccessibilityHelp("Enter to \(actionLabel.lowercased()). Control-Enter to insert a new line.")
        editor.placeholder = placeholder
        editor.submissionEnabled = isEnabled
        editor.allowsEmpty = allowsEmpty
        editor.onSubmit = onSubmit
        editor.needsDisplay = true
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: MultilineComposer
        init(_ parent: MultilineComposer) { self.parent = parent }
        func textDidChange(_ notification: Notification) {
            guard let editor = notification.object as? NSTextView else { return }
            parent.text = editor.string
        }
    }
}

final class ComposerTextView: NSTextView {
    var onSubmit: (() -> Void)?
    var submissionEnabled = true
    var allowsEmpty = false
    var placeholder = ""

    override func keyDown(with event: NSEvent) {
        guard event.keyCode == 36 || event.keyCode == 76 else { super.keyDown(with: event); return }
        guard !hasMarkedText() else { super.keyDown(with: event); return }
        if event.modifierFlags.contains(.control) {
            insertText("\n", replacementRange: selectedRange())
            return
        }
        guard submissionEnabled, !event.isARepeat,
              allowsEmpty || !string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        // Hold the gate closed until SwiftUI supplies the next action state.
        submissionEnabled = false
        onSubmit?()
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        if string.isEmpty, !placeholder.isEmpty {
            (placeholder as NSString).draw(at: NSPoint(x: textContainerInset.width + 5, y: textContainerInset.height),
                withAttributes: [.font: font ?? NSFont.systemFont(ofSize: NSFont.systemFontSize),
                                 .foregroundColor: NSColor.placeholderTextColor])
        }
    }
}
