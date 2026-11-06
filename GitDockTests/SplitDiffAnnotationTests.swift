import AppKit
import SwiftUI
import XCTest
@testable import GitDock

@MainActor
final class SplitDiffAnnotationTests: XCTestCase {
    func testRightAnnotationKeepsItsColumnWhenLeftHasNoConversations() throws {
        let host = NSHostingView(rootView: SplitDiffAnnotations(columnWidth: 100) {
            EmptyView()
        } right: {
            Color(nsColor: .red).frame(height: 40)
        }.background(Color(nsColor: .white)))
        host.frame = NSRect(x: 0, y: 0, width: 201, height: 40)
        host.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let left = try XCTUnwrap(bitmap.colorAt(x: bitmap.pixelsWide / 4, y: bitmap.pixelsHigh / 2)?.usingColorSpace(.deviceRGB))
        let right = try XCTUnwrap(bitmap.colorAt(x: bitmap.pixelsWide * 3 / 4, y: bitmap.pixelsHigh / 2)?.usingColorSpace(.deviceRGB))
        XCTAssertGreaterThan(left.greenComponent, 0.8, "Empty left column must retain its space")
        XCTAssertLessThan(right.greenComponent, 0.2, "Right annotation must appear under right-side code")
    }
}
