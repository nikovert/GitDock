import XCTest
@testable import GitDockCore

final class PRSearchMatchingTests: XCTestCase {
    func testLiteralTermsPreserveIdentifiersAndQuotedPhrases() {
        XCTAssertEqual(PRSearchQuery("  src/foo.swift  \"old value\" FOO_bar ").terms,
                       ["src/foo.swift", "old value", "foo_bar"])
    }

    func testAllSourcesAndRemovedCodeAreSearchable() {
        let document = searchDocument(number: 1, title: "TitleNeedle", body: "BodyNeedle", files: [
            PRSearchFile(path: "new.swift", previousPath: "old.swift", patch:
                "@@ -1,2 +1,2 @@\n-removedNeedle\n+addedNeedle\n contextNeedle", additions: 1, deletions: 1)
        ])
        for (query, source, kind) in [
            ("titleneedle", PRSearchSource.title, nil),
            ("bodyneedle", .description, nil),
            ("old.swift", .file, nil),
            ("removedneedle", .code, PRSearchLineKind.removed),
            ("addedneedle", .code, .added),
            ("contextneedle", .code, .context)
        ] {
            let match = PRSearchMatcher.match(document, query: PRSearchQuery(query))
            XCTAssertEqual(match?.source, source)
            XCTAssertEqual(match?.lineKind, kind)
        }
        XCTAssertNil(PRSearchMatcher.match(document, query: PRSearchQuery("")))
        XCTAssertNil(PRSearchMatcher.match(document, query: PRSearchQuery(".*")))
    }

    func testWordCoveragePrecedesSourceAndTiesAreDeterministic() {
        let title = PRSearchMatcher.match(searchDocument(number: 2, title: "alpha"), query: PRSearchQuery("alpha beta"))!
        let body = PRSearchMatcher.match(searchDocument(number: 3, body: "alpha beta"), query: PRSearchQuery("alpha beta"))!
        XCTAssertTrue(PRSearchMatcher.precedes(body, title))
        let older = PRSearchMatcher.match(searchDocument(number: 1, title: "alpha"), query: PRSearchQuery("alpha beta"))!
        XCTAssertTrue(PRSearchMatcher.precedes(older, title))
    }

    func testPatchCoverageDoesNotTreatOmissionOrTruncationAsComplete() {
        let omitted = PRSearchFile(path: "image.png", patch: nil, additions: 0, deletions: 0)
        let truncated = PRSearchFile(path: "file", patch: "@@ -1 +1 @@\n-old\n+new", additions: 2, deletions: 1)
        XCTAssertFalse(omitted.hasCompletePatch)
        XCTAssertFalse(truncated.hasCompletePatch)
        XCTAssertTrue(PRSearchFile(path: "file", patch: "@@ -1 +1 @@\n-old\n+new", additions: 1, deletions: 1).hasCompletePatch)
        XCTAssertFalse(PRSearchFile(path: "file", patch: "@@ -1,3 +1,3 @@\n-old\n+new", additions: 1, deletions: 1).hasCompletePatch)
    }

    func testCanonicalRepositoryNodeIDsRemainCaseSensitive() {
        let first = searchDocument(number: 1).pullRequest
        let second = PullRequestPresentation(id: "other", repositoryID: "r_repo", repositoryNameWithOwner: "other/repo", number: 1,
            title: first.title, url: first.url, isDraft: false, updatedAt: first.updatedAt, reviewers: [])
        XCTAssertNotEqual(PRSearchDocument.key(first), PRSearchDocument.key(second))
    }
}

func searchDocument(number: Int, title: String = "Routine update", body: String = "", files: [PRSearchFile] = []) -> PRSearchDocument {
    PRSearchDocument(pullRequest: PullRequestPresentation(
        id: "PR_\(number)", repositoryID: "R_repo", repositoryNameWithOwner: "org/repo", number: number,
        title: title, url: URL(string: "https://github.com/org/repo/pull/\(number)")!, isDraft: false,
        updatedAt: Date(timeIntervalSince1970: 1_000), reviewers: [], headSHA: "head"),
        body: body, baseSHA: "base", headSHA: "head", changedFiles: files.count, files: files,
        coverage: PRSearchCoverage(fileListComplete: true, codeComplete: true), refreshedAt: Date())
}
