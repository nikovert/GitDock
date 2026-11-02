import AppKit
import XCTest
@testable import GitHubBar

@MainActor
final class WorkspaceLayoutTests: XCTestCase {
    func testPanelPreferencesAndVisibilityPersistIndependently() throws {
        let suite = "WorkspaceLayoutTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let layout = WorkspaceLayout(defaults: defaults)
        layout.sidebarWidth = 310
        layout.inspectorWidth = 460
        layout.fileListWidth = 280
        layout.showsInspector = false
        layout.showsFileList = false
        let restored = WorkspaceLayout(defaults: defaults)
        XCTAssertEqual(restored.sidebarWidth, 310)
        XCTAssertEqual(restored.inspectorWidth, 460)
        XCTAssertEqual(restored.fileListWidth, 280)
        XCTAssertFalse(restored.showsInspector)
        XCTAssertFalse(restored.showsFileList)
        XCTAssertEqual(restored.resolvedWidths(availableWidth: 900).inspector, 0)
        restored.showsInspector = true
        XCTAssertEqual(restored.inspectorWidth, 460)
    }

    func testNarrowWindowClampsPanelsAndKeepsPreferredSizesForExpansion() throws {
        let suite = "WorkspaceLayoutTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let layout = WorkspaceLayout(defaults: defaults)
        layout.sidebarWidth = 400
        layout.inspectorWidth = 600
        let narrow = layout.resolvedWidths(availableWidth: 900)
        XCTAssertEqual(narrow.sidebar + narrow.inspector, 480, accuracy: 0.001)
        XCTAssertEqual(layout.sidebarWidth, 400)
        XCTAssertEqual(layout.inspectorWidth, 600)
        let expanded = layout.resolvedWidths(availableWidth: 1600)
        XCTAssertEqual(expanded.sidebar, 400)
        XCTAssertEqual(expanded.inspector, 600)
        XCTAssertEqual(layout.resolvedFileListWidth(availableWidth: 200), 0)
        XCTAssertEqual(WorkspaceLayout.clamp(.infinity, minimum: 100, maximum: 200), 100)
    }
    func testInvalidStoredSizesAreClampedAndHiddenPanelsReleaseSpace() throws {
        let suite = "WorkspaceLayoutTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(-40, forKey: "workspace.layout.sidebarWidth")
        defaults.set(9_999, forKey: "workspace.layout.inspectorWidth")
        let layout = WorkspaceLayout(defaults: defaults)
        XCTAssertEqual(layout.sidebarWidth, 180)
        XCTAssertEqual(layout.inspectorWidth, 720)
        layout.showsSidebar = false
        layout.showsInspector = false
        let widths = layout.resolvedWidths(availableWidth: 900)
        XCTAssertEqual(widths.sidebar, 0)
        XCTAssertEqual(widths.inspector, 0)
        XCTAssertEqual(layout.sidebarWidth, 180)
        XCTAssertEqual(layout.inspectorWidth, 720)
    }

    func testResetRestoresDefaultSizesAndVisibilityAndPersistsThem() throws {
        let suite = "WorkspaceLayoutTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let layout = WorkspaceLayout(defaults: defaults)
        layout.sidebarWidth = 400
        layout.inspectorWidth = 600
        layout.fileListWidth = 420
        layout.showsSidebar = false
        layout.showsInspector = false
        layout.showsFileList = false

        layout.reset()

        let restored = WorkspaceLayout(defaults: defaults)
        XCTAssertEqual(restored.sidebarWidth, 260)
        XCTAssertEqual(restored.inspectorWidth, 360)
        XCTAssertEqual(restored.fileListWidth, 230)
        XCTAssertTrue(restored.showsSidebar)
        XCTAssertTrue(restored.showsInspector)
        XCTAssertTrue(restored.showsFileList)
    }

    func testDashboardDoesNotReserveInspectorSpaceOrChangeReviewPreference() throws {
        let suite = "WorkspaceLayoutTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let layout = WorkspaceLayout(defaults: defaults)
        layout.sidebarWidth = 400
        layout.inspectorWidth = 600
        let dashboard = layout.resolvedWidths(availableWidth: 900, includesInspector: false)
        XCTAssertEqual(dashboard.sidebar, 400)
        XCTAssertEqual(dashboard.inspector, 0)
        XCTAssertTrue(layout.showsInspector)
        XCTAssertEqual(layout.inspectorWidth, 600)
        let review = layout.resolvedWidths(availableWidth: 900)
        XCTAssertEqual(review.sidebar + review.inspector, 480, accuracy: 0.001)
    }

    func testDividerVisiblyHighlightsOnHoverAndRestoresOnExit() throws {
        let divider = WorkspaceDividerView(frame: NSRect(x: 0, y: 0, width: 10, height: 40))
        func snapshot() throws -> Data {
            let bitmap = try XCTUnwrap(divider.bitmapImageRepForCachingDisplay(in: divider.bounds))
            divider.cacheDisplay(in: divider.bounds, to: bitmap)
            return try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        }
        func hoverEvent(_ type: NSEvent.EventType) throws -> NSEvent {
            try XCTUnwrap(NSEvent.enterExitEvent(with: type, location: .zero, modifierFlags: [],
                timestamp: 0, windowNumber: 0, context: nil, eventNumber: 0, trackingNumber: 0, userData: nil))
        }
        let idle = try snapshot()
        divider.mouseEntered(with: try hoverEvent(.mouseEntered))
        let hovered = try snapshot()
        XCTAssertNotEqual(hovered, idle, "The divider must visibly highlight throughout its mouse target")
        divider.mouseExited(with: try hoverEvent(.mouseExited))
        XCTAssertEqual(try snapshot(), idle)
    }

}
