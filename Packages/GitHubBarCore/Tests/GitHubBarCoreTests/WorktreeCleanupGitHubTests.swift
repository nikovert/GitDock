import XCTest
@testable import GitHubBarCore

final class WorktreeCleanupGitHubTests: XCTestCase {
    func testClosedDraftEvidenceIsExplicitAndDoesNotBecomeMerged() async throws {
        let result = try await makeClient(extra: "closed-draft").check(.pullRequest(key), accountLogin: "tester")
        XCTAssertTrue(result.closed)
        XCTAssertTrue(result.isDraft)
        XCTAssertFalse(result.merged)
    }

    func testDuplicateStackEntriesDoNotProveCompleteMembership() async throws {
        let client = makeClient(states: ["MERGED", "MERGED"], urls: [12, 12])
        let result = try await client.check(.stack(key), accountLogin: "tester")
        XCTAssertFalse(result.stackComplete)
    }

    func testMergedRootWithOpenMemberIsNotMergedStack() async throws {
        let result = try await makeClient(states: ["MERGED", "OPEN"]).check(.pullRequest(key), accountLogin: "tester")
        XCTAssertTrue(result.merged)
        XCTAssertTrue(result.hasStack)
        XCTAssertTrue(result.stackComplete)
        XCTAssertFalse(result.stackMerged)
    }

    func testNullStackIsDistinguishedFromIncompleteStack() async throws {
        let result = try await makeClient(extra: "no-stack").check(.pullRequest(key), accountLogin: "tester")
        XCTAssertFalse(result.hasStack)
        XCTAssertTrue(result.merged)
    }

    func testTruncatedStackAndNullMembersAreIncomplete() async throws {
        for extra in ["truncated", "null", "size"] {
            let result = try await makeClient(extra: extra).check(.stack(key), accountLogin: "tester")
            XCTAssertFalse(result.stackComplete, extra)
        }
    }

    func testCompleteMergedStackIsEligibleMetadata() async throws {
        let result = try await makeClient().check(.stack(key), accountLogin: "tester")
        XCTAssertTrue(result.merged && result.stackComplete && result.stackMerged)
        XCTAssertEqual(result.title, "Finished change")
        XCTAssertEqual(result.body, "Handle missing sensor inputs.\n\nKeep the fallback active.")
        XCTAssertEqual(result.stackPullRequests.map(\.key.number), [12, 13])
        XCTAssertEqual(result.stackPullRequests.map(\.title), ["Stack change 12", "Stack change 13"])
        XCTAssertEqual(result.stackPullRequests.last?.description, "Description for change 13.")
    }

    func testWrongViewerAndGraphQLErrorsFailClosed() async throws {
        for extra in ["viewer", "error", "missing"] {
            do { _ = try await makeClient(extra: extra).check(.pullRequest(key), accountLogin: "tester"); XCTFail(extra) }
            catch { XCTAssertTrue(error.localizedDescription.contains("GitHub")) }
        }
    }

    private var key: PullRequestKey { try! PullRequestKey(url: URL(string: "https://github.com/acme/widget/pull/12")!) }
    private func makeClient(states: [String] = ["MERGED", "MERGED"], urls: [Int] = [12, 13], extra: String = "") -> WorktreeCleanupGitHubClient {
        var nodes: [Any] = zip(states, urls).map { state, number in
            ["pullRequest": ["url": "https://github.com/acme/widget/pull/\(number)", "state": state,
                             "title": "Stack change \(number)", "bodyText": "Description for change \(number)."]]
        }
        if extra == "null" { nodes[1] = NSNull() }
        var pr: [String: Any] = ["title": "Finished change", "bodyText": "Handle missing sensor inputs.\n\nKeep the fallback active.",
            "state": "MERGED", "headRefOid": String(repeating: "a", count: 40),
            "stack": ["size": extra == "size" ? 3 : 2, "entries": ["nodes": nodes, "pageInfo": ["hasNextPage": extra == "truncated"]]]]
        if extra == "closed-draft" { pr["state"] = "CLOSED"; pr["isDraft"] = true }
        if extra == "no-stack" { pr["stack"] = NSNull() }
        var json: [String: Any] = ["data": ["viewer": ["login": extra == "viewer" ? "wrong" : "tester"],
            "repository": ["pullRequest": extra == "missing" ? NSNull() as Any : pr as Any]]]
        if extra == "error" { json["errors"] = [["message": "Incomplete"]] }
        return WorktreeCleanupGitHubClient(connection: CleanupConnection(),
            transport: CleanupTransport(data: try! JSONSerialization.data(withJSONObject: json)))
    }
}

private struct CleanupConnection: AccountConnection {
    func inspect(selectedLogin: String?) async -> AccountConnectionResult {
        .connected(ResolvedAccount(login: selectedLogin ?? "", hostname: "github.com", scopes: [],
            accessCoverage: AccessCoverage(isComplete: true), accessToken: GitHubAccessToken("fake")))
    }
}
private struct CleanupTransport: GitHubTransport {
    let data: Data
    func execute(body: Data, accessToken: GitHubAccessToken) async throws -> GitHubTransportResponse {
        .init(statusCode: 200, headers: [:], data: data)
    }
}
