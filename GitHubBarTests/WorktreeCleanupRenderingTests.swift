import AppKit
import SwiftUI
import XCTest
@testable import GitHubBarCore
@testable import GitHubBar

@MainActor
final class WorktreeCleanupRenderingTests: XCTestCase {
    func testBulkAndIndividualCleanupRenderInLightAndDarkMode() async throws {
        let model = WorktreeCleanupModel(service: CleanupRenderingService())
        model.updateAccount("tester")
        model.scan()
        await model.pendingTask?.value
        XCTAssertEqual(model.candidates.count, 4)
        let directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent(".build/ui-previews")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for stage in ["bulk", "individual"] {
            if stage == "individual" { model.reviewIndividually() }
            for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
                let view = NSHostingView(rootView: WorktreeCleanupView(model: model))
                let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 580),
                    styleMask: [.titled], backing: .buffered, defer: false)
                window.isReleasedWhenClosed = false
                window.appearance = NSAppearance(named: appearance)
                window.contentView = view
                view.frame = NSRect(x: 0, y: 0, width: 760, height: 580)
                view.layoutSubtreeIfNeeded()
                let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
                view.cacheDisplay(in: view.bounds, to: bitmap)
                let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                try png.write(to: directory.appendingPathComponent("cleanup-\(stage)-\(name).png"))
                // Detach before closing: the view's onDisappear correctly cancels its model.
                window.contentView = nil
                window.close()
                if model.candidates.isEmpty {
                    model.scan(); await model.pendingTask?.value
                    if stage == "individual" { model.reviewIndividually() }
                }
            }
        }
    }
}

private struct CleanupRenderingService: WorktreeCleanupServicing {
    func preview(accountLogin: String) async throws -> [WorktreeCleanupCandidate] {
        let existing = try await CleanupUIService().preview(accountLogin: accountLogin)
        let other = WorktreeCleanupCandidate(path: "/worktrees/experiment", sessions: [], title: "Experiment workspace",
            headSHA: String(repeating: "b", count: 40), skipReason: nil, liveSessions: [:], accountLogin: accountLogin,
            configuration: WorkspaceConfiguration(), provenance: .external, repositoryNameWithOwner: "example/project",
            automaticSkipReason: "Other worktree: explicit manual approval required.")
        return [other] + existing
    }
    func execute(_ approved: [WorktreeCleanupCandidate], accountLogin: String) async -> [WorktreeCleanupResult] {
        XCTFail("Rendering must never remove worktrees")
        return []
    }
}
