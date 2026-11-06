import Foundation
import XCTest
@testable import GitDockCore

final class SettingsStoreTests: XCTestCase {
    func testPinnedRepositoriesPersistInUserDefaults() async {
        let suiteName = "GitDockCoreTests.\(UUID().uuidString)"
        defer { UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName) }
        let store = UserDefaultsSettingsStore(defaults: UserDefaults(suiteName: suiteName)!)
        let expected = AppSettings(
            selectedLogin: "FranciscoMoretti",
            pinnedRepositories: [
                PinnedRepository(id: "REPO-1", nameWithOwner: "owner/one"),
                PinnedRepository(id: "REPO-2", nameWithOwner: "owner/two"),
            ]
        )

        await store.save(expected)

        let loaded = await store.load()
        XCTAssertEqual(loaded, expected)
    }
}
