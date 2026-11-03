import XCTest
import GitHubBarCore
@testable import GitHubBar

final class ReviewFileTreeTests: XCTestCase {
    private let files = [
        PRSearchFile(path: "src/lib/noise.py", patch: nil, additions: 2, deletions: 1),
        PRSearchFile(path: "README.md", patch: nil, additions: 0, deletions: 0),
        PRSearchFile(path: "src/lib/models/terms.py", previousPath: "old/expressions.py", patch: nil, additions: 1, deletions: 1),
        PRSearchFile(path: "docs/models/narmax.md", patch: nil, additions: 41, deletions: 0),
        PRSearchFile(path: "src/lib/models/equations.py", patch: nil, additions: 6, deletions: 1)
    ]

    func testFoldersCompactWithoutLosingBranchPointsAndSortBeforeFiles() {
        let rows = ReviewFileTree(files: files).rows()
        XCTAssertEqual(rows.map(\.name), ["docs/models", "narmax.md", "src/lib", "models", "equations.py", "terms.py", "noise.py", "README.md"])
        XCTAssertEqual(rows.map(\.depth), [0, 1, 0, 1, 2, 2, 1, 0])
        XCTAssertEqual(rows.compactMap(\.file).map(\.path), ["docs/models/narmax.md", "src/lib/models/equations.py", "src/lib/models/terms.py", "src/lib/noise.py", "README.md"])
    }

    func testCollapsingFolderHidesOnlyDescendants() {
        let rows = ReviewFileTree(files: files).rows(collapsed: ["src/lib/models"])
        XCTAssertTrue(rows.contains { $0.path == "src/lib/models" && $0.file == nil })
        XCTAssertFalse(rows.contains { $0.path == "src/lib/models/terms.py" })
        XCTAssertTrue(rows.contains { $0.path == "src/lib/noise.py" })
    }

    func testSearchMatchesFullPathsAndRenameSourcesAndRevealsCollapsedMatches() {
        let byDirectory = ReviewFileTree(files: files, filter: "  SRC/LIB/MODELS  ")
        XCTAssertEqual(byDirectory.rows(collapsed: ["src/lib/models"]).compactMap(\.file).map(\.path), ["src/lib/models/equations.py", "src/lib/models/terms.py"])
        let byPreviousName = ReviewFileTree(files: files, filter: "expressions")
        XCTAssertEqual(byPreviousName.rows().compactMap(\.file).first?.path, "src/lib/models/terms.py")
        XCTAssertTrue(ReviewFileTree(files: files, filter: "not-present").rows().isEmpty)
    }

    func testSameBasenamesAndCaseDistinctDirectoriesRemainSeparate() {
        let files = ["A/item.py", "a/item.py", "tests/item.py", "src/item.py"].map {
            PRSearchFile(path: $0, patch: nil, additions: 0, deletions: 0)
        }
        let rows = ReviewFileTree(files: files).rows(collapsed: ["A"])
        XCTAssertEqual(Set(rows.compactMap(\.file).map(\.path)), ["a/item.py", "tests/item.py", "src/item.py"])
        XCTAssertEqual(Set(rows.map(\.id)).count, rows.count)
    }

    func testReplacingFileWithDirectoryKeepsBothSidesOfTheChangeNavigable() {
        let files = ["config", "config/app.yml"].map {
            PRSearchFile(path: $0, patch: nil, additions: 0, deletions: 0)
        }
        let tree = ReviewFileTree(files: files)
        XCTAssertEqual(tree.rows().compactMap(\.file).map(\.path), ["config/app.yml", "config"])
        XCTAssertEqual(tree.rows(collapsed: ["config"]).compactMap(\.file).map(\.path), ["config"])
        XCTAssertEqual(Set(tree.rows().map(\.id)).count, 3)
    }
}
