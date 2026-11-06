import AppKit
import SwiftUI

/// Captures secondary clicks without replacing SwiftUI's keyboard and accessibility actions.
struct SecondaryClickCapture: NSViewRepresentable {
    let action: () -> Void

    func makeNSView(context: Context) -> SecondaryClickView {
        let view = SecondaryClickView()
        view.action = action
        return view
    }

    func updateNSView(_ view: SecondaryClickView, context: Context) { view.action = action }

    static func dismantleNSView(_ view: SecondaryClickView, coordinator: ()) { view.stopMonitoring() }
}

@MainActor
final class SecondaryClickView: NSView {
    var action: () -> Void = {}
    private var monitor: Any?
    private var pressed = false

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        stopMonitoring()
        guard window != nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.rightMouseDown, .rightMouseUp]) { [weak self] event in
            guard let self else { return event }
            return self.handle(event)
        }
    }

    func stopMonitoring() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        pressed = false
    }

    private func handle(_ event: NSEvent) -> NSEvent? {
        guard event.type == .rightMouseDown || event.type == .rightMouseUp,
              let window, event.window === window, !isHiddenOrHasHiddenAncestor else { return event }
        let inside = visibleRect.contains(convert(event.locationInWindow, from: nil))
        if event.type == .rightMouseDown {
            pressed = inside
            return inside ? nil : event
        }
        guard pressed else { return event }
        pressed = false
        if inside { action() }
        return nil
    }
}
