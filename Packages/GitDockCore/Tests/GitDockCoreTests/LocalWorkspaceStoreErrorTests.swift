import XCTest
@testable import GitDockCore

final class LocalWorkspaceStoreErrorTests: XCTestCase {
    func testWorkspaceStoreFailuresExplainRecoveryWithoutDiscardingData() {
        XCTAssertTrue(
            LocalWorkspaceStoreError.corrupt.localizedDescription.contains("Back up workspace.json")
        )
        XCTAssertTrue(
            LocalWorkspaceStoreError.incompatibleVersion.localizedDescription.contains("Update GitDock")
        )
        XCTAssertTrue(
            LocalWorkspaceStoreError.lockUnavailable.localizedDescription.contains("permissions")
        )
    }
}
