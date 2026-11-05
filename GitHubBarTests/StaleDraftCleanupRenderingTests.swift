import AppKit
import SwiftUI
import XCTest
@testable import GitHubBarCore
@testable import GitHubBar

@MainActor
final class StaleDraftCleanupRenderingTests: XCTestCase {
    func testSelectionAndResultsAtMinimumAndLargeSizesInLightAndDark() async throws {
        let directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent(".build/ui-previews")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for stage in ["selection", "results"] {
            for (sizeName, size) in [("minimum", NSSize(width: 660, height: 500)), ("large", NSSize(width: 1000, height: 760))] {
                for (appearanceName, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
                    let model = StaleDraftCleanupModel(service: DraftRenderingService())
                    model.updateContext(accountLogin: "tester", workload: [])
                    model.setInactiveDays(UserDefaults.standard.object(forKey: "staleDraftInactiveDays") as? Int ?? 30)
                    model.scan(); await model.pendingTask?.value
                    model.select("acme/widget#1", enabled: true)
                    if stage == "results" {
                        model.requestConfirmation(); model.confirmSelected()
                        await model.pendingTask?.value
                    }
                    let view = NSHostingView(rootView: StaleDraftCleanupView(model: model, accountLogin: "tester",
                        workload: [], onClosed: {}, onManualCleanup: {}))
                    let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                        styleMask: [.titled], backing: .buffered, defer: false)
                    window.isReleasedWhenClosed = false
                    window.appearance = NSAppearance(named: appearance)
                    window.contentView = view
                    view.frame = NSRect(origin: .zero, size: size)
                    view.layoutSubtreeIfNeeded()
                    let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
                    view.cacheDisplay(in: view.bounds, to: bitmap)
                    let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                    try png.write(to: directory.appendingPathComponent("stale-drafts-\(stage)-\(sizeName)-\(appearanceName).png"))
                    window.contentView = nil
                    window.close()
                }
            }
        }
    }
}

private actor DraftRenderingService: StaleDraftCleanupServicing {
    func preview(workload: [PullRequestPresentation], accountLogin: String, inactiveDays: Int) async throws -> [StaleDraftCleanupCandidate] {
        [1, 2].map { number in
            .init(key: try! PullRequestKey(url: URL(string: "https://github.com/acme/widget/pull/\(number)")!),
                nodeID: "PR_\(number)", accountLogin: accountLogin,
                title: number == 1 ? "Replace the old renderer and keep long draft titles readable when reviewing changes" : "A draft without close permission",
                authorLogin: accountLogin, headSHA: "abc", updatedAt: Date(timeIntervalSince1970: 1_000),
                previewedAt: Date(), inactiveDays: inactiveDays, viewerCanClose: number == 1)
        }
    }
    func close(_ approved: StaleDraftCleanupCandidate, accountLogin: String) async -> StaleDraftCleanupResult {
        .init(candidate: approved, outcome: .closed, message: "Closed on GitHub. Remote branches and all local data were kept.")
    }
}
