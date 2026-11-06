import AppKit
import Observation
import SwiftUI

/// Preferred panel sizes survive temporary window constraints and panel hiding.
@MainActor
@Observable
final class WorkspaceLayout {
    var sidebarWidth: CGFloat { didSet { persist(sidebarWidth, "sidebarWidth") } }
    var inspectorWidth: CGFloat { didSet { persist(inspectorWidth, "inspectorWidth") } }
    var fileListWidth: CGFloat { didSet { persist(fileListWidth, "fileListWidth") } }
    var showsSidebar: Bool { didSet { defaults.set(showsSidebar, forKey: key("showsSidebar")) } }
    var showsInspector: Bool { didSet { defaults.set(showsInspector, forKey: key("showsInspector")) } }
    var showsFileList: Bool { didSet { defaults.set(showsFileList, forKey: key("showsFileList")) } }

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let keyPrefix: String
    static let dividerWidth: CGFloat = 10
    private static let defaultSidebarWidth: CGFloat = 260
    private static let defaultInspectorWidth: CGFloat = 360
    private static let defaultFileListWidth: CGFloat = 230

    init(defaults: UserDefaults = .standard, keyPrefix: String = "workspace.layout") {
        self.defaults = defaults
        self.keyPrefix = keyPrefix
        func savedWidth(_ name: String, fallback: CGFloat, range: ClosedRange<CGFloat>) -> CGFloat {
            let value = defaults.object(forKey: "\(keyPrefix).\(name)") as? Double
            guard let value, value.isFinite else { return fallback }
            return min(range.upperBound, max(range.lowerBound, CGFloat(value)))
        }
        sidebarWidth = savedWidth("sidebarWidth", fallback: Self.defaultSidebarWidth, range: 180...520)
        inspectorWidth = savedWidth("inspectorWidth", fallback: Self.defaultInspectorWidth, range: 240...720)
        fileListWidth = savedWidth("fileListWidth", fallback: Self.defaultFileListWidth, range: 140...520)
        showsSidebar = defaults.object(forKey: "\(keyPrefix).showsSidebar") as? Bool ?? true
        showsInspector = defaults.object(forKey: "\(keyPrefix).showsInspector") as? Bool ?? true
        showsFileList = defaults.object(forKey: "\(keyPrefix).showsFileList") as? Bool ?? true
    }

    func reset() {
        sidebarWidth = Self.defaultSidebarWidth
        inspectorWidth = Self.defaultInspectorWidth
        fileListWidth = Self.defaultFileListWidth
        showsSidebar = true
        showsInspector = true
        showsFileList = true
    }

    /// Shrinks panels proportionally to preserve the editor, without losing stored preferences.
    func resolvedWidths(availableWidth: CGFloat, minimumCenterWidth: CGFloat = 400, includesInspector: Bool = true) -> (sidebar: CGFloat, inspector: CGFloat) {
        let sidebar = showsSidebar ? Self.clamp(sidebarWidth, minimum: 180, maximum: 520) : 0
        let inspectorIsVisible = showsInspector && includesInspector
        let inspector = inspectorIsVisible ? Self.clamp(inspectorWidth, minimum: 240, maximum: 720) : 0
        let dividerCount = (showsSidebar ? 1 : 0) + (inspectorIsVisible ? 1 : 0)
        let budget = max(0, availableWidth - minimumCenterWidth - CGFloat(dividerCount) * Self.dividerWidth)
        let total = sidebar + inspector
        guard total > budget, total > 0 else { return (sidebar, inspector) }
        return (sidebar * budget / total, inspector * budget / total)
    }

    func resolvedFileListWidth(availableWidth: CGFloat, minimumContentWidth: CGFloat = 300) -> CGFloat {
        guard showsFileList else { return 0 }
        return Self.clamp(fileListWidth, minimum: 140, maximum: min(520, max(0, availableWidth - minimumContentWidth - Self.dividerWidth)))
    }

    static func clamp(_ value: CGFloat, minimum: CGFloat, maximum: CGFloat) -> CGFloat {
        let upper = max(0, maximum)
        let lower = min(max(0, minimum), upper)
        return min(upper, max(lower, value.isFinite ? value : lower))
    }

    private func key(_ name: String) -> String { "\(keyPrefix).\(name)" }
    private func persist(_ value: CGFloat, _ name: String) {
        guard value.isFinite else { return }
        defaults.set(Double(value), forKey: key(name))
    }
}

/// A 10-point mouse target with native resize cursor and a one-point visible separator.
/// Use direction -1 for a panel positioned to the right of its divider.
struct WorkspaceResizeDivider: NSViewRepresentable {
    @Binding var width: CGFloat
    let minimum: CGFloat
    let maximum: CGFloat
    var direction: CGFloat = 1

    func makeNSView(context: Context) -> WorkspaceDividerView { WorkspaceDividerView() }

    func updateNSView(_ view: WorkspaceDividerView, context: Context) {
        view.currentWidth = width
        view.minimum = minimum
        view.maximum = maximum
        view.direction = direction
        view.onResize = { width = $0 }
        view.setAccessibilityLabel("Resize panel")
    }
}

final class WorkspaceDividerView: NSView {
    var currentWidth: CGFloat = 0
    var minimum: CGFloat = 0
    var maximum: CGFloat = .greatestFiniteMagnitude
    var direction: CGFloat = 1
    var onResize: ((CGFloat) -> Void)?
    private var hoverTrackingArea: NSTrackingArea?
    private var isHovered = false
    private var isDragging = false

    override var intrinsicContentSize: NSSize { NSSize(width: WorkspaceLayout.dividerWidth, height: NSView.noIntrinsicMetric) }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .resizeLeftRight) }
    override func updateTrackingAreas() {
        if let hoverTrackingArea { removeTrackingArea(hoverTrackingArea) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(area)
        hoverTrackingArea = area
        super.updateTrackingAreas()
    }
    override func mouseEntered(with event: NSEvent) {
        isHovered = true
        needsDisplay = true
    }
    override func mouseExited(with event: NSEvent) {
        isHovered = false
        needsDisplay = true
    }
    override func draw(_ dirtyRect: NSRect) {
        let highlighted = isHovered || isDragging
        if highlighted {
            NSColor.controlAccentColor.withAlphaComponent(0.1).setFill()
            bounds.fill()
        }
        (highlighted ? NSColor.controlAccentColor : NSColor.separatorColor).setFill()
        let lineWidth: CGFloat = highlighted ? 2 : 1
        NSRect(x: floor(bounds.midX - lineWidth / 2), y: 0, width: lineWidth, height: bounds.height).fill()
    }
    override func mouseDown(with event: NSEvent) {
        let startX = event.locationInWindow.x
        let startWidth = currentWidth
        guard let window else { return }
        isDragging = true
        needsDisplay = true
        defer { isDragging = false; needsDisplay = true }
        while let next = window.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) {
            if next.type == .leftMouseUp { break }
            NSCursor.resizeLeftRight.set()
            let proposed = startWidth + (next.locationInWindow.x - startX) * direction
            onResize?(WorkspaceLayout.clamp(proposed, minimum: minimum, maximum: maximum))
        }
    }
    override func keyDown(with event: NSEvent) {
        guard event.keyCode == 123 || event.keyCode == 124 else { super.keyDown(with: event); return }
        let step: CGFloat = event.modifierFlags.contains(.shift) ? 40 : 10
        let delta = event.keyCode == 123 ? -step : step
        onResize?(WorkspaceLayout.clamp(currentWidth + delta * direction, minimum: minimum, maximum: maximum))
    }
}
