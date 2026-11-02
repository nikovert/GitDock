import XCTest
@testable import GitHubBarCore

final class ApprovalClassificationTests: XCTestCase {
    func testMinimumApprovalClassifiesNullDecisionDespiteOutstandingRequest() async throws {
        let snapshot = try await reconcileApprovalFixture()
        XCTAssertEqual(snapshot.authoredPullRequests.first?.reviewDecision, .approved)
        XCTAssertEqual(snapshot.authoredPullRequests.first?.authoredSection, .approved)
        XCTAssertEqual(snapshot.authoredPullRequests.first?.requestedReviewers?.map(\.displayName), ["yuchen-shang"])
    }
    func testHydrationRequiresConfiguredMinimumAcrossRulesetsAndLegacyProtection() async throws {
        let underMinimum = try await reconcileApprovalFixture(requirements: .init(minimum: 2))
        XCTAssertNil(underMinimum.authoredPullRequests.first?.reviewDecision)
        XCTAssertEqual(underMinimum.authoredPullRequests.first?.authoredSection, .waitingForReviewers)
        let atMinimum = try await reconcileApprovalFixture(transport: .init(secondApproval: true), requirements: .init(minimum: 2))
        XCTAssertEqual(atMinimum.authoredPullRequests.first?.reviewDecision, .approved)
        let legacyMinimum = try await reconcileApprovalFixture(transport: .init(minimumLegacyApprovals: 2))
        XCTAssertNil(legacyMinimum.authoredPullRequests.first?.reviewDecision)
    }

    func testNullableLegacyCountHydratesButCannotInferUnknownRequiredMinimum() async throws {
        let unknown = try await reconcileApprovalFixture(transport: .init(legacyCountUnavailable: true))
        XCTAssertEqual(unknown.authoredPullRequests.count, 1)
        XCTAssertNil(unknown.authoredPullRequests.first?.reviewDecision)
        let irrelevant = try await reconcileApprovalFixture(transport: .init(legacyCountUnavailable: true, legacyReviewsRequired: false))
        XCTAssertEqual(irrelevant.authoredPullRequests.first?.reviewDecision, .approved)
    }

    func testLaterReviewPagesCanBlockFallbackAndFailedPagesDoNotInferApproval() async throws {
        let changed = try await reconcileApprovalFixture(transport: .init(laterChangeRequest: true))
        XCTAssertNil(changed.authoredPullRequests.first?.reviewDecision)
        let incomplete = try await reconcileApprovalFixture(transport: .init(laterChangeRequest: true, failsReviewPage: true))
        XCTAssertNil(incomplete.authoredPullRequests.first?.reviewDecision)
        XCTAssertEqual(incomplete.completeness, .partial)
        let unknownPolicy = try await reconcileApprovalFixture(requirements: .init(fails: true))
        XCTAssertNil(unknownPolicy.authoredPullRequests.first?.reviewDecision)
        XCTAssertEqual(unknownPolicy.completeness, .partial)
    }

    func testHydrationPreservesAuthoritativeBlockerDespiteEnoughApprovals() async throws {
        let snapshot = try await reconcileApprovalFixture(transport: .init(aggregate: "REVIEW_REQUIRED"))
        XCTAssertEqual(snapshot.authoredPullRequests.first?.reviewDecision, .reviewRequired)
    }

    func testMinimumTwoRequiresTwoDistinctEligibleApprovers() {
        XCTAssertNil(decision(reviews: [approval("alice")], requirements: [.init(minimumApprovals: 2)]))
        XCTAssertNil(decision(reviews: [approval("alice"), approval("ALICE")], requirements: [.init(minimumApprovals: 2)]))
        XCTAssertEqual(decision(reviews: [approval("alice"), approval("bob")], requirements: [.init(minimumApprovals: 2)]), .approved)
    }

    func testAuthoritativeDecisionsAlwaysWin() {
        for aggregate in [PullRequestReviewDecision.reviewRequired, .changesRequested, .approved] {
            XCTAssertEqual(ApprovalClassification.decision(aggregate: aggregate, author: "nikovert", authorIsHuman: true,
                headSHA: "head", reviewsComplete: true, reviews: [approval("alice")], requirements: [.init(minimumApprovals: 1)]), aggregate)
        }
    }

    func testDismissalAndLatestChangeRequestInvalidateAnEarlierApproval() {
        XCTAssertNil(decision(reviews: [approval("alice"), review("alice", "DISMISSED")]))
        XCTAssertNil(decision(reviews: [approval("alice"), review("alice", "CHANGES_REQUESTED")]))
        XCTAssertNil(decision(reviews: [approval("alice"), review("bob", "CHANGES_REQUESTED")]))
        XCTAssertEqual(decision(reviews: [review("alice", "CHANGES_REQUESTED"), approval("alice")]), .approved)
    }

    func testCommentAndPendingReviewsDoNotRevokeApproval() {
        XCTAssertEqual(decision(reviews: [approval("alice"), review("alice", "COMMENTED"), review("alice", "PENDING")]), .approved)
    }

    func testSelfOutsiderAndUnknownEligibilityApprovalsDoNotCount() {
        XCTAssertNil(decision(reviews: [approval("nikovert")]))
        XCTAssertNil(decision(reviews: [review("outsider", "APPROVED", canPush: false)]))
        XCTAssertNil(decision(reviews: [review("unknown", "APPROVED", canPush: nil)]))
        XCTAssertEqual(decision(reviews: [approval("alice"), review("outsider", "CHANGES_REQUESTED", canPush: false)]), .approved)
        XCTAssertNil(decision(reviews: [approval("alice"), review("unknown", "CHANGES_REQUESTED", canPush: nil)]))
        XCTAssertNil(decision(reviews: [approval("alice"), ApprovalReview(login: nil, state: "CHANGES_REQUESTED", canPush: true, commit: "head")]))
    }

    func testStaleApprovalsOnlyCountWhenPolicyAllowsThem() {
        let old = review("alice", "APPROVED", commit: "old")
        XCTAssertEqual(decision(reviews: [old]), .approved)
        XCTAssertNil(decision(reviews: [old], requirements: [.init(minimumApprovals: 1, dismissesStaleApprovals: true)]))
        XCTAssertNil(decision(reviews: [review("alice", "APPROVED", commit: nil)], requirements: [.init(minimumApprovals: 1, dismissesStaleApprovals: true)]))
        XCTAssertEqual(decision(reviews: [approval("alice")], requirements: [.init(minimumApprovals: 1, dismissesStaleApprovals: true)]), .approved)
    }

    func testUnknownCoverageOrPolicyCannotInferApproval() {
        XCTAssertNil(decision(reviews: [approval("alice")], complete: false))
        XCTAssertNil(decision(reviews: [approval("alice")], requirements: nil))
        XCTAssertEqual(decision(reviews: [approval("alice")], requirements: []), .approved)
        for requirement in [GitHubApprovalRequirement(minimumApprovals: 1, requiresCodeOwner: true),
                            .init(minimumApprovals: 1, requiresLastPushApproval: true),
                            .init(minimumApprovals: 1, requiresSpecificReviewers: true)] {
            XCTAssertNil(decision(reviews: [approval("alice")], requirements: [requirement]))
        }
        XCTAssertNil(ApprovalClassification.decision(aggregate: nil, author: "copilot", authorIsHuman: false,
            headSHA: "head", reviewsComplete: true, reviews: [approval("alice")],
            requirements: [.init(minimumApprovals: 1, requiresExtraApprovalForUnattributedChanges: true)]))
    }

    func testRequirementsRejectUnsafeRepositoryAndUnsupportedHostBeforeNetworkAccess() async {
        let client = RESTGitHubApprovalRequirementsClient()
        for (repository, host) in [("owner/repo?redirect=example", "github.com"), ("owner/../repo", "github.com"), ("owner/repo", "github.com@evil.example")] {
            let account = ResolvedAccount(login: "nikovert", hostname: host, scopes: [], accessCoverage: AccessCoverage(isComplete: true), accessToken: GitHubAccessToken("fixture"))
            do {
                _ = try await client.requirements(repository: repository, baseBranch: "main", account: account)
                XCTFail("Unsafe endpoint must be rejected")
            } catch { }
        }
    }

    func testRulesetDecoderCombinesReviewPoliciesWithoutInterpretingMergeRequirements() throws {
        let json = #"[{"type":"merge_queue","parameters":{"unrelated":true}},{"type":"pull_request","parameters":{"required_approving_review_count":1,"dismiss_stale_reviews_on_push":false,"require_code_owner_review":false,"require_last_push_approval":false,"required_review_thread_resolution":true,"require_extra_approval_for_unattributed_changes":true,"required_reviewers":[]}},{"type":"pull_request","parameters":{"required_approving_review_count":2,"dismiss_stale_reviews_on_push":true,"require_code_owner_review":false,"require_last_push_approval":false,"required_reviewers":[{"minimum_approvals":1}]}}]"#
        let requirements = try RESTGitHubApprovalRequirementsClient.decodeRequirements(Data(json.utf8))
        XCTAssertEqual(requirements.count, 2)
        XCTAssertEqual(requirements[0], .init(minimumApprovals: 1, requiresExtraApprovalForUnattributedChanges: true))
        XCTAssertEqual(requirements[1], .init(minimumApprovals: 2, dismissesStaleApprovals: true, requiresSpecificReviewers: true))
        XCTAssertThrowsError(try RESTGitHubApprovalRequirementsClient.decodeRequirements(Data(#"[{"type":"pull_request","parameters":{"required_approving_review_count":1}}]"#.utf8)))
    }

    private func approval(_ login: String) -> ApprovalReview { review(login, "APPROVED") }
    private func review(_ login: String, _ state: String, canPush: Bool? = true, commit: String? = "head") -> ApprovalReview {
        ApprovalReview(login: login, state: state, canPush: canPush, commit: commit)
    }
    private func decision(reviews: [ApprovalReview], requirements: [GitHubApprovalRequirement]? = [.init(minimumApprovals: 1)], complete: Bool = true) -> PullRequestReviewDecision? {
        ApprovalClassification.decision(aggregate: nil, author: "nikovert", authorIsHuman: true, headSHA: "head", reviewsComplete: complete, reviews: reviews, requirements: requirements)
    }

}

private func reconcileApprovalFixture(transport: ApprovalFixtureTransport = .init(), requirements: ApprovalFixtureRequirements = .init()) async throws -> WorkloadSnapshot {
    let client = GraphQLGitHubWorkloadClient(transport: transport, approvalRequirementsClient: requirements)
    let result = await client.reconcile(account: ResolvedAccount(login: "nikovert", hostname: "github.com", scopes: [], accessCoverage: AccessCoverage(isComplete: true), accessToken: GitHubAccessToken("fixture")))
    switch result {
    case let .complete(snapshot, _), let .partial(snapshot, _): return snapshot
    case .failed: throw ApprovalFixtureError.failed
    }
}
private enum ApprovalFixtureError: Error { case failed }
private struct ApprovalFixtureTransport: GitHubTransport {
    var minimumLegacyApprovals: Int? = nil
    var legacyCountUnavailable = false
    var legacyReviewsRequired = true
    var laterChangeRequest = false
    var failsReviewPage = false
    var aggregate: String? = nil
    var secondApproval = false
    func execute(body: Data, accessToken: GitHubAccessToken) async throws -> GitHubTransportResponse {
        let request = try JSONSerialization.jsonObject(with: body) as! [String: Any]
        let operation = request["operationName"] as! String
        // Contract subset from GitHub's BranchProtectionRule schema. Reject unknown selected fields,
        // as the real GraphQL server does before executing any hydration.
        if let query = request["query"] as? String,
           let range = query.range(of: #"branchProtectionRule\s*\{([^}]+)\}"#, options: .regularExpression) {
            let selection = String(query[range]).components(separatedBy: "{")[1].components(separatedBy: "}")[0]
                .replacingOccurrences(of: #"\b\w+\s*:"#, with: "", options: .regularExpression)
            let schemaFields: Set<String> = ["requiresApprovingReviews", "requiredApprovingReviewCount", "dismissesStaleReviews", "requiresCodeOwnerReviews", "requireLastPushApproval"]
            guard selection.split(whereSeparator: \.isWhitespace).allSatisfy({ schemaFields.contains(String($0)) }) else {
                return GitHubTransportResponse(statusCode: 200, headers: [:], data: Data(#"{"errors":[{"message":"Field is not defined on BranchProtectionRule"}]}"#.utf8))
            }
        }
        let page: [String: Any] = ["hasNextPage": false, "endCursor": NSNull()]
        let payload: [String: Any]
        switch operation {
        case "ViewerRepositories": payload = ["viewer": ["repositories": ["nodes": [], "pageInfo": page]]]
        case "ViewerOrganizations": payload = ["viewer": ["organizations": ["nodes": [], "pageInfo": page]]]
        case "SearchPullRequests":
            let variables = request["variables"] as! [String: Any]
            let authored = (variables["query"] as! String).contains("author:")
            payload = ["search": ["nodes": authored ? [["id": "PR-12853"]] : [], "pageInfo": page]]
        case "HydratePullRequests":
            var reviews: [[String: Any]] = [["author": ["login": "michaelcraiger"], "state": "APPROVED", "authorCanPushToRepository": true, "commit": ["oid": "head"]]]
            if secondApproval { reviews.append(["author": ["login": "second-reviewer"], "state": "APPROVED", "authorCanPushToRepository": true, "commit": ["oid": "head"]]) }
            let legacy: Any
            if legacyCountUnavailable || minimumLegacyApprovals != nil {
                legacy = ["requiresApprovingReviews": legacyReviewsRequired, "requiredApprovingReviewCount": minimumLegacyApprovals as Any? ?? NSNull(), "dismissesStaleReviews": false, "requiresCodeOwnerReviews": false, "requiresLastPushApproval": false]
            } else { legacy = NSNull() }
            payload = ["nodes": [[
                "id": "PR-12853", "number": 12853, "title": "Approved with outstanding request",
                "url": "https://github.com/carbon-re/carbo/pull/12853", "isDraft": false,
                "reviewDecision": aggregate as Any? ?? NSNull(), "state": "OPEN", "updatedAt": "2026-11-02T12:00:00Z",
                "headRefOid": "head", "baseRefName": "main", "baseRef": ["branchProtectionRule": legacy],
                "author": ["login": "nikovert", "__typename": "User"], "repository": ["id": "REPO", "nameWithOwner": "carbon-re/carbo"],
                "reviewRequests": ["nodes": [["requestedReviewer": ["__typename": "User", "login": "yuchen-shang"]]], "pageInfo": page],
                "reviews": ["nodes": reviews, "pageInfo": laterChangeRequest ? ["hasNextPage": true, "endCursor": "reviews-1"] : page]
            ]]]
        case "PullRequestRosterPage":
            if failsReviewPage { throw ApprovalFixtureError.failed }
            payload = ["node": ["reviews": ["nodes": [["author": ["login": "michaelcraiger"], "state": "CHANGES_REQUESTED", "authorCanPushToRepository": true, "commit": ["oid": "head"]]], "pageInfo": page]]]
        default: throw ApprovalFixtureError.failed
        }
        var data = payload
        data["rateLimit"] = ["cost": 1, "remaining": 5000, "resetAt": "2026-11-02T13:00:00Z"]
        return GitHubTransportResponse(statusCode: 200, headers: [:], data: try JSONSerialization.data(withJSONObject: ["data": data]))
    }
}

private struct ApprovalFixtureRequirements: GitHubApprovalRequirementsClient {
    var minimum = 1
    var fails = false
    func requirements(repository: String, baseBranch: String, account: ResolvedAccount) async throws -> [GitHubApprovalRequirement] {
        if fails { throw ApprovalFixtureError.failed }
        return [GitHubApprovalRequirement(minimumApprovals: minimum, requiresExtraApprovalForUnattributedChanges: true)]
    }
}
