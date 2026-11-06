import XCTest
@testable import GitDock

@MainActor
final class UpdateControllerTests: XCTestCase {
    func testValidationFactoryOffersManualDownloadsWithoutSparkle() {
        XCTAssertTrue(UpdateControllerFactory.make().canCheckForUpdates)
        XCTAssertTrue(UpdateControllerFactory.make() is ManualDownloadUpdateController)
    }

    func testManualUpdateActionOpensForkReleasesIncludingValidationBuilds() {
        var openedURLs: [URL] = []
        let model = UpdateModel(controller: ManualDownloadUpdateController { url in
            openedURLs.append(url)
            return true
        })

        XCTAssertEqual(model.actionTitle, "Download Updates…")
        XCTAssertEqual(model.presentation, .manualDownload)
        model.checkForUpdates()

        XCTAssertEqual(openedURLs.map(\.absoluteString), ["https://github.com/nikovert/GitDock/releases"])
        XCTAssertEqual(model.presentation, .manualDownload)
        XCTAssertTrue(model.canCheckForUpdates)
    }

    func testFailedBrowserOpenIsVisibleAndRetryable() {
        var attempts = 0
        let model = UpdateModel(controller: ManualDownloadUpdateController { _ in
            attempts += 1
            return attempts > 1
        })

        model.checkForUpdates()
        guard case let .failed(message) = model.presentation else {
            return XCTFail("Expected a visible browser-open error")
        }
        XCTAssertTrue(message.contains("https://github.com/nikovert/GitDock/releases"))
        XCTAssertTrue(model.canCheckForUpdates)
        model.checkForUpdates()
        XCTAssertEqual(attempts, 2)
        XCTAssertEqual(model.presentation, .manualDownload)
    }
}
