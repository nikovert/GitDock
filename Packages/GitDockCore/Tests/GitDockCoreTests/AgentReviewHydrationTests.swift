import Foundation
import XCTest
@testable import GitDockCore

final class AgentReviewHydrationTests: XCTestCase, @unchecked Sendable {
    func testHeadCommitAndBotRequestsSurviveHydration() async throws {
        let pr = try await reconcile(failedRoster: false)
        XCTAssertEqual(pr.headSHA, "abc123")
        XCTAssertEqual(pr.requestedReviewers?.filter { $0.kind == .person }.map(\.displayName), ["niko"])
        XCTAssertEqual(pr.requestedReviewers?.filter { $0.kind == .bot }.count, 1)
    }

    func testFailedRequestPaginationDoesNotExposePartialRosterAsComplete() async throws {
        let pr = try await reconcile(failedRoster: true)
        XCTAssertNil(pr.requestedReviewers)
        XCTAssertFalse(pr.reviewers.isEmpty)
    }

    func testUnknownRequestedReviewerDoesNotProveSoleHumanReviewer() async throws {
        let pr = try await reconcile(failedRoster: false, unknownReviewer: true)
        XCTAssertNil(pr.requestedReviewers)
    }

    private func reconcile(failedRoster: Bool, unknownReviewer: Bool = false) async throws -> PullRequestPresentation {
        let result = await GraphQLGitHubWorkloadClient(transport: AgentHydrationTransport(failedRoster: failedRoster, unknownReviewer: unknownReviewer))
            .reconcile(account: ResolvedAccount(login: "niko", hostname: "github.com", scopes: ["repo"],
                accessCoverage: AccessCoverage(isComplete: true), accessToken: GitHubAccessToken("fixture-token")))
        switch result {
        case let .complete(snapshot, _), let .partial(snapshot, _): return try XCTUnwrap(snapshot.needsYourReview.first)
        case .failed: throw AgentReviewError.invalid("Fixture failed to reconcile")
        }
    }
}

private struct AgentHydrationTransport: GitHubTransport {
    let failedRoster: Bool
    let unknownReviewer: Bool
    func execute(body: Data, accessToken: GitHubAccessToken) async throws -> GitHubTransportResponse {
        let request = try JSONSerialization.jsonObject(with: body) as! [String: Any]
        let variables = request["variables"] as? [String: Any] ?? [:]
        let page: [String: Any] = ["hasNextPage": false, "endCursor": NSNull()]
        var data: [String: Any]
        switch request["operationName"] as? String {
        case "ViewerRepositories": data = ["viewer": ["repositories": ["nodes": [["id": "repo", "nameWithOwner": "acme/widget", "isArchived": false]], "pageInfo": page]]]
        case "ViewerOrganizations": data = ["viewer": ["organizations": ["nodes": [], "pageInfo": page]]]
        case "SearchPullRequests":
            let query = variables["query"] as? String ?? ""
            data = ["search": ["nodes": query.contains("user-review-requested:") ? [["id": "pr"]] : [], "pageInfo": page]]
        case "HydratePullRequests":
            data = ["nodes": [["id": "pr", "number": 12, "title": "Review this", "url": "https://github.com/acme/widget/pull/12",
                "isDraft": false, "state": "OPEN", "updatedAt": "2026-10-22T12:00:00Z", "headRefOid": "abc123",
                "author": ["login": "alice"], "repository": ["id": "repo", "nameWithOwner": "acme/widget"],
                "reviewRequests": ["nodes": [
                    ["requestedReviewer": ["__typename": "User", "login": "niko"]],
                    ["requestedReviewer": ["__typename": unknownReviewer ? "FutureReviewer" : "Bot", "login": "reviewer[bot]"]]],
                    "pageInfo": failedRoster ? ["hasNextPage": true, "endCursor": "next"] : page],
                "reviews": ["nodes": [], "pageInfo": page]]]]
        case "PullRequestRosterPage": throw GitHubTransportError.invalidResponse
        default: throw GitHubTransportError.invalidResponse
        }
        data["rateLimit"] = ["cost": 1, "remaining": 4900, "resetAt": "2026-10-22T20:00:00Z"]
        return GitHubTransportResponse(statusCode: 200, headers: [:], data: try JSONSerialization.data(withJSONObject: ["data": data]))
    }
}
