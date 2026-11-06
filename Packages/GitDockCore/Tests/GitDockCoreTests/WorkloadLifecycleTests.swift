import Foundation
import XCTest
@testable import GitDockCore

final class WorkloadLifecycleTests: XCTestCase {
    func testAuthoritativeDiscoveryEvictsAbsentRowsDespiteCatalogWarning() async throws {
        let fresh = try await reconcile(LifecycleFixture(catalogWarning: true))
        let merged = fresh.mergingConfirmedUpdates(into: snapshot(authored: [pr("old"), pr("found")]))
        XCTAssertEqual(merged.authoredPullRequests.map(\.id), ["found"])
        XCTAssertEqual(merged.completeness, .partial)
        XCTAssertEqual(try JSONDecoder().decode(WorkloadSnapshot.self, from: JSONEncoder().encode(fresh)), fresh)
    }

    func testIncompleteSearchRetainsUnconfirmedButEvictsFreshTerminalEvidence() async throws {
        let fresh = try await reconcile(LifecycleFixture(searchIncomplete: true, terminal: true))
        let merged = fresh.mergingConfirmedUpdates(into: snapshot(authored: [pr("old"), pr("found")]))
        XCTAssertEqual(merged.authoredPullRequests.map(\.id), ["old"])
    }

    func testCompleteSearchRetainsDiscoveredRowWhoseHydrationFailed() async throws {
        let fresh = try await reconcile(LifecycleFixture(missingHydration: true))
        let merged = fresh.mergingConfirmedUpdates(into: snapshot(authored: [pr("old"), pr("missing")]))
        XCTAssertEqual(Set(merged.authoredPullRequests.map(\.id)), ["found", "missing"])
    }

    func testAuthoritativeDiscoveryStillEvictsAbsentRowsWhenAllHydrationFails() async throws {
        let fresh = try await reconcile(LifecycleFixture(allHydrationFails: true))
        let merged = fresh.mergingConfirmedUpdates(into: snapshot(authored: [pr("old"), pr("found")]))
        XCTAssertEqual(merged.authoredPullRequests.map(\.id), ["found"])
    }

    func testPartialSnapshotsNeverCrossAccountOrHost() async throws {
        let fresh = try await reconcile(LifecycleFixture(catalogWarning: true))
        XCTAssertEqual(fresh.mergingConfirmedUpdates(into: snapshot(authored: [pr("old")], account: "elsewhere")), fresh)
        XCTAssertEqual(fresh.mergingConfirmedUpdates(into: snapshot(authored: [pr("old")], hostname: "enterprise.example")), fresh)
    }

    func testEffectiveReviewOpinionsAndIncompleteHistory() async throws {
        let fresh = try await reconcile(LifecycleFixture())
        let row = try XCTUnwrap(fresh.authoredPullRequests.first)
        XCTAssertEqual(row.reviewers.map(\.displayName), ["waiting", "owner/team", "approved", "changed", "dismissed"])
        // Persisted reviewer evidence lets the detail UI avoid inferring approval from request absence.
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(row)) as? [String: Any])
        let roster = try XCTUnwrap(object["reviewers"] as? [[String: Any]])
        XCTAssertEqual(roster[2]["reviewState"] as? String, "approved")
        XCTAssertEqual(roster[3]["reviewState"] as? String, "changesRequested")
        XCTAssertEqual(roster[4]["reviewState"] as? String, "dismissed")
        XCTAssertEqual(object["reviewRosterIsComplete"] as? Bool, true)

        let partial = try await reconcile(LifecycleFixture(rosterIncomplete: true))
        let partialRow = try XCTUnwrap(partial.authoredPullRequests.first)
        let partialObject = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(partialRow)) as? [String: Any])
        let partialRoster = try XCTUnwrap(partialObject["reviewers"] as? [[String: Any]])
        XCTAssertEqual(partialObject["reviewRosterIsComplete"] as? Bool, false)
        XCTAssertFalse(partialRoster.contains { ($0["reviewStateIsComplete"] as? Bool) == true })
    }

    func testReviewQueueUsesSeparateAuthorityAndKeepsUnconfirmedTeamRequests() async throws {
        let previous = WorkloadSnapshot(hostname: "github.com", accountLogin: "owner", capturedAt: Date(),
            completeness: .complete, availableRepositories: [], needsYourReview: [pr("old"), pr("found")], authoredPullRequests: [])
        let complete = try await reconcile(LifecycleFixture(reviewLane: true))
        XCTAssertEqual(complete.mergingConfirmedUpdates(into: previous).needsYourReview.map(\.id), ["found"])
        let partial = try await reconcile(LifecycleFixture(reviewLane: true, teamWarning: true))
        XCTAssertEqual(Set(partial.mergingConfirmedUpdates(into: previous).needsYourReview.map(\.id)), ["found", "old"])
    }

    func testTruncatedSearchDoesNotClaimAuthoritativeAbsence() async throws {
        let fresh = try await reconcile(LifecycleFixture(searchCount: 1001))
        let merged = fresh.mergingConfirmedUpdates(into: snapshot(authored: [pr("old")]))
        XCTAssertEqual(Set(merged.authoredPullRequests.map(\.id)), ["found", "old"])
        XCTAssertEqual(fresh.completeness, .partial)
    }

    func testMissingReviewAuthorPreventsConfirmedOpinions() async throws {
        let fresh = try await reconcile(LifecycleFixture(missingReviewAuthor: true))
        let row = try XCTUnwrap(fresh.authoredPullRequests.first)
        XCTAssertFalse(row.reviewRosterIsComplete)
        XCTAssertFalse(row.reviewers.contains { $0.reviewStateIsComplete })
        XCTAssertEqual(fresh.completeness, .partial)
    }

    func testLaterReviewPagesSupersedeOpinionAndFailedPagesSuppressTicks() async throws {
        let fresh = try await reconcile(LifecycleFixture(rosterNextPage: true))
        let reviewer = try XCTUnwrap(fresh.authoredPullRequests.first?.reviewers.first { $0.displayName == "approved" })
        XCTAssertEqual(reviewer.reviewState, .changesRequested)
        XCTAssertTrue(reviewer.reviewStateIsComplete)
        let partial = try await reconcile(LifecycleFixture(rosterNextPage: true, rosterPageFails: true))
        let partialRow = try XCTUnwrap(partial.authoredPullRequests.first)
        XCTAssertFalse(partialRow.reviewRosterIsComplete)
        XCTAssertFalse(partialRow.reviewers.contains { $0.reviewStateIsComplete })
        XCTAssertEqual(partial.completeness, .partial)
    }

    func testUnrelatedCatalogOrReviewDiscoveryFailureStillAppliesAuthoredAuthority() async throws {
        for failedOperation in ["ViewerRepositories", "ViewerOrganizations", "directSearch"] {
            let fresh = try await reconcile(LifecycleFixture(failedOperation: failedOperation))
            let merged = fresh.mergingConfirmedUpdates(into: snapshot(authored: [pr("old")]))
            XCTAssertEqual(merged.authoredPullRequests.map(\.id), ["found"], failedOperation)
            XCTAssertEqual(fresh.completeness, .partial)
        }
    }

    func testFailedAuthoredSearchDoesNotDiscardConfirmedReviewLane() async throws {
        let fresh = try await reconcile(LifecycleFixture(reviewLane: true, failedOperation: "authoredSearch"))
        let previous = WorkloadSnapshot(hostname: "github.com", accountLogin: "owner", capturedAt: Date(),
            completeness: .complete, availableRepositories: [], needsYourReview: [pr("old")], authoredPullRequests: [pr("authored")])
        let merged = fresh.mergingConfirmedUpdates(into: previous)
        XCTAssertEqual(merged.needsYourReview.map(\.id), ["found"])
        XCTAssertEqual(merged.authoredPullRequests.map(\.id), ["authored"])
    }

    func testUnknownTeamMembershipDoesNotTurnTeamRequestIntoConfirmedAbsence() async throws {
        let fresh = try await reconcile(LifecycleFixture(reviewLane: true, teamWarning: true, onlyTeamRequest: true))
        let previous = WorkloadSnapshot(hostname: "github.com", accountLogin: "owner", capturedAt: Date(), completeness: .complete,
            availableRepositories: [], needsYourReview: [pr("found")], authoredPullRequests: [])
        XCTAssertEqual(fresh.mergingConfirmedUpdates(into: previous).needsYourReview.map(\.id), ["found"])
    }

    func testReviewRosterUnionsRequestsAndPreservesCompletedOpinions() {
        let waiting = ReviewerPresentation(id: "user:waiting", displayName: "waiting", avatarURL: nil, kind: .person)
        let team = ReviewerPresentation(id: "team:owner/team", displayName: "owner/team", avatarURL: nil, kind: .team)
        let requestedApprover = ReviewerPresentation(id: "user:approved", displayName: "approved", avatarURL: nil, kind: .person)
        let approved = ReviewerPresentation(id: "user:approved", displayName: "approved", avatarURL: nil, kind: .person,
            reviewState: .approved, reviewStateIsComplete: true)
        let changed = ReviewerPresentation(id: "user:changed", displayName: "changed", avatarURL: nil, kind: .person,
            reviewState: .changesRequested, reviewStateIsComplete: true)
        let requestedOnly = PullRequestPresentation(id: "p", repositoryID: "r", repositoryNameWithOwner: "owner/repo", number: 1,
            title: "PR", url: URL(string: "https://github.com/owner/repo/pull/1")!, isDraft: false, updatedAt: Date(),
            requestedReviewers: [waiting, team], reviewers: [])
        XCTAssertEqual(requestedOnly.reviewRoster.map(\.id), [waiting.id, team.id])
        XCTAssertTrue(requestedOnly.reviewRoster.allSatisfy { $0.isRequested == true })
        let combined = PullRequestPresentation(id: "p", repositoryID: "r", repositoryNameWithOwner: "owner/repo", number: 1,
            title: "PR", url: URL(string: "https://github.com/owner/repo/pull/1")!, isDraft: false, updatedAt: Date(),
            requestedReviewers: [waiting, team, requestedApprover], reviewers: [approved, changed])
        XCTAssertEqual(combined.reviewRoster.map(\.id), [waiting.id, team.id, approved.id, changed.id])
        XCTAssertEqual(combined.reviewRoster.first { $0.id == approved.id }?.reviewState, .approved)
        XCTAssertEqual(combined.reviewRoster.first { $0.id == approved.id }?.isRequested, true)
        XCTAssertEqual(combined.reviewRoster.first { $0.id == changed.id }?.isRequested, false)
    }

    func testPartialRequestPaginationPreservesKnownTeamAndRequestedApproverWithoutProvingAbsence() async throws {
        let fresh = try await reconcile(LifecycleFixture(rosterPageFails: true, requestNextPage: true,
            requestApprover: true, reviewDecisionAbsent: true))
        let row = try XCTUnwrap(fresh.authoredPullRequests.first)
        XCTAssertNil(row.requestedReviewers, "Partial requests must not drive authored classification")
        XCTAssertNil(row.authoredSection)
        XCTAssertFalse(row.reviewRosterIsComplete)
        let encoded = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(row)) as? [String: Any])
        let roster = try XCTUnwrap(encoded["reviewers"] as? [[String: Any]])
        let team = try XCTUnwrap(roster.first { $0["id"] as? String == "team:owner/team" })
        let approver = try XCTUnwrap(roster.first { $0["id"] as? String == "user:approved" })
        let completed = try XCTUnwrap(roster.first { $0["id"] as? String == "user:changed" })
        XCTAssertEqual(team["isRequested"] as? Bool, true)
        XCTAssertEqual(approver["isRequested"] as? Bool, true)
        XCTAssertNil(completed["isRequested"], "Missing later request pages cannot prove this person is unrequested")
        XCTAssertEqual(approver["reviewStateIsComplete"] as? Bool, true, "Request-only failure does not invalidate complete review history")
        XCTAssertEqual(try JSONDecoder().decode(PullRequestPresentation.self, from: JSONEncoder().encode(row)), row)

        let complete = try await reconcile(LifecycleFixture(requestApprover: true))
        let completeRow = try XCTUnwrap(complete.authoredPullRequests.first)
        let completeEncoded = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(completeRow)) as? [String: Any])
        let completeRoster = try XCTUnwrap(completeEncoded["reviewers"] as? [[String: Any]])
        XCTAssertEqual(completeRoster.first { $0["id"] as? String == "user:changed" }?["isRequested"] as? Bool, false)
    }

    func testLegacySnapshotAndReviewerDecodeWithoutNewEvidence() throws {
        let old = snapshot(authored: [pr("old")])
        let encoded = try JSONEncoder().encode(old)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object.removeValue(forKey: "membershipEvidence")
        var rows = try XCTUnwrap(object["authoredPullRequests"] as? [[String: Any]])
        rows[0].removeValue(forKey: "reviewRosterIsComplete")
        var reviewers = try XCTUnwrap(rows[0]["reviewers"] as? [[String: Any]])
        reviewers[0].removeValue(forKey: "reviewState")
        reviewers[0].removeValue(forKey: "reviewStateIsComplete")
        reviewers[0].removeValue(forKey: "isRequested")
        rows[0]["reviewers"] = reviewers
        object["authoredPullRequests"] = rows
        let decoded = try JSONDecoder().decode(WorkloadSnapshot.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertEqual(decoded.authoredPullRequests.map(\.id), ["old"])
        XCTAssertFalse(decoded.authoredPullRequests[0].reviewRosterIsComplete)
        XCTAssertNil(decoded.authoredPullRequests[0].reviewers[0].reviewState)
        XCTAssertFalse(decoded.authoredPullRequests[0].reviewers[0].reviewStateIsComplete)
        XCTAssertNil(decoded.authoredPullRequests[0].reviewers[0].isRequested)
    }

    private func reconcile(_ transport: LifecycleFixture) async throws -> WorkloadSnapshot {
        let account = ResolvedAccount(login: "owner", hostname: "github.com", scopes: ["repo"],
            accessCoverage: AccessCoverage(isComplete: true), accessToken: GitHubAccessToken("fixture"))
        switch await GraphQLGitHubWorkloadClient(transport: transport).reconcile(account: account) {
        case let .complete(snapshot, _), let .partial(snapshot, _): return snapshot
        case .failed: throw FixtureError.failed
        }
    }
    private enum FixtureError: Error { case failed }
    private func snapshot(authored: [PullRequestPresentation], account: String = "owner", hostname: String = "github.com") -> WorkloadSnapshot {
        WorkloadSnapshot(hostname: hostname, accountLogin: account, capturedAt: Date(), completeness: .complete,
            availableRepositories: [], needsYourReview: [], authoredPullRequests: authored)
    }
    private func pr(_ id: String) -> PullRequestPresentation {
        PullRequestPresentation(id: id, repositoryID: "r", repositoryNameWithOwner: "owner/repo", number: 1,
            title: id, url: URL(string: "https://github.com/owner/repo/pull/1")!, isDraft: false, updatedAt: Date(),
            reviewers: [ReviewerPresentation(id: "user:legacy", displayName: "legacy", avatarURL: nil, kind: .person)])
    }
}

private struct LifecycleFixture: GitHubTransport {
    var catalogWarning = false
    var searchIncomplete = false
    var terminal = false
    var missingHydration = false
    var rosterIncomplete = false
    var allHydrationFails = false
    var reviewLane = false
    var teamWarning = false
    var searchCount: Int?
    var missingReviewAuthor = false
    var rosterNextPage = false
    var rosterPageFails = false
    var failedOperation: String?
    var onlyTeamRequest = false
    var requestNextPage = false
    var requestApprover = false
    var reviewDecisionAbsent = false

    func execute(body: Data, accessToken: GitHubAccessToken) async throws -> GitHubTransportResponse {
        let request = try JSONSerialization.jsonObject(with: body) as! [String: Any]
        let operation = request["operationName"] as! String
        let variables = request["variables"] as? [String: Any] ?? [:]
        if operation == failedOperation
            || (operation == "SearchPullRequests"
                && ((failedOperation == "authoredSearch" && (variables["query"] as? String)?.contains("author:") == true)
                    || (failedOperation == "directSearch" && (variables["query"] as? String)?.contains("user-review-requested:") == true))) {
            throw URLError(.cannotConnectToHost)
        }
        let page: [String: Any] = ["hasNextPage": false, "endCursor": NSNull()]
        var data: [String: Any] = ["rateLimit": ["cost": 1, "remaining": 1000, "resetAt": "2026-11-05T12:00:00Z"]]
        var errors = false
        switch operation {
        case "ViewerRepositories":
            data["viewer"] = ["repositories": ["nodes": [], "pageInfo": page]]
            errors = catalogWarning
        case "ViewerOrganizations":
            data["viewer"] = ["organizations": ["nodes": [], "pageInfo": page]]
            errors = teamWarning
        case "SearchPullRequests":
            let authored = (variables["query"] as? String)?.contains("author:") == true
            let discovered = (reviewLane ? !authored : authored) ? (["found"] + (missingHydration ? ["missing"] : [])) : []
            var search: [String: Any] = ["nodes": discovered.map { ["id": $0] }, "pageInfo": page]
            if let searchCount, authored { search["issueCount"] = searchCount }
            data["search"] = search
            errors = authored && searchIncomplete
        case "HydratePullRequests":
            if allHydrationFails { throw URLError(.cannotConnectToHost) }
            let review: (String, String) -> [String: Any] = { ["state": $1, "author": ["login": $0]] }
            var reviews = [review("approved", "APPROVED"), review("approved", "COMMENTED"),
                review("changed", "APPROVED"), review("changed", "CHANGES_REQUESTED"),
                review("dismissed", "APPROVED"), review("dismissed", "DISMISSED"), review("commenter", "COMMENTED"), review("owner", "APPROVED")]
            if missingReviewAuthor { reviews.append(["state": "CHANGES_REQUESTED", "author": NSNull()]) }
            var requests: [[String: Any]] = [["requestedReviewer": ["__typename": "Team", "slug": "team", "organization": ["login": "owner"]]]]
            if !onlyTeamRequest { requests.insert(["requestedReviewer": ["__typename": "User", "login": reviewLane ? "owner" : "waiting"]], at: 0) }
            if requestApprover { requests.append(["requestedReviewer": ["__typename": "User", "login": "approved"]]) }
            let row: [String: Any] = ["id": "found", "number": 1, "title": "Found", "url": "https://github.com/owner/repo/pull/1",
                "isDraft": false, "state": terminal ? "MERGED" : "OPEN", "updatedAt": "2026-11-05T11:00:00Z", "reviewDecision": reviewDecisionAbsent ? NSNull() : "REVIEW_REQUIRED",
                "author": ["login": reviewLane ? "someone" : "owner"], "repository": ["id": "r", "nameWithOwner": "owner/repo"],
                "reviewRequests": ["nodes": requests, "pageInfo": requestNextPage ? ["hasNextPage": true, "endCursor": "next"] : page],
                "reviews": ["nodes": reviews, "pageInfo": rosterNextPage ? ["hasNextPage": true, "endCursor": "next"] : page]]
            data["nodes"] = missingHydration ? [row, NSNull()] : [row]
            errors = rosterIncomplete
        case "PullRequestRosterPage":
            if rosterPageFails { throw URLError(.cannotConnectToHost) }
            data["node"] = ["reviews": ["nodes": [["state": "CHANGES_REQUESTED", "author": ["login": "approved"]]], "pageInfo": page]]
        default: throw URLError(.badServerResponse)
        }
        var envelope: [String: Any] = ["data": data]
        if errors { envelope["errors"] = [["type": "FIXTURE_PARTIAL"]] }
        return GitHubTransportResponse(statusCode: 200, headers: [:], data: try JSONSerialization.data(withJSONObject: envelope))
    }
}
