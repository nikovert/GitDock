import Foundation

/// Review requirements only; CI, conflicts and conversation resolution do not determine approval.
public struct GitHubApprovalRequirement: Sendable, Equatable {
    public let minimumApprovals: Int
    public let dismissesStaleApprovals: Bool
    public let requiresCodeOwner: Bool
    public let requiresLastPushApproval: Bool
    public let requiresSpecificReviewers: Bool
    public let requiresExtraApprovalForUnattributedChanges: Bool

    public init(minimumApprovals: Int, dismissesStaleApprovals: Bool = false,
                requiresCodeOwner: Bool = false, requiresLastPushApproval: Bool = false,
                requiresSpecificReviewers: Bool = false, requiresExtraApprovalForUnattributedChanges: Bool = false) {
        self.minimumApprovals = minimumApprovals
        self.dismissesStaleApprovals = dismissesStaleApprovals
        self.requiresCodeOwner = requiresCodeOwner
        self.requiresLastPushApproval = requiresLastPushApproval
        self.requiresSpecificReviewers = requiresSpecificReviewers
        self.requiresExtraApprovalForUnattributedChanges = requiresExtraApprovalForUnattributedChanges
    }
}

public protocol GitHubApprovalRequirementsClient: Sendable {
    /// All active ruleset review requirements applying to this base branch. Errors mean unknown policy.
    func requirements(repository: String, baseBranch: String, account: ResolvedAccount) async throws -> [GitHubApprovalRequirement]
}

public struct RESTGitHubApprovalRequirementsClient: GitHubApprovalRequirementsClient {
    private let session: URLSession
    public init(session: URLSession = .shared) { self.session = session }

    public func requirements(repository: String, baseBranch: String, account: ResolvedAccount) async throws -> [GitHubApprovalRequirement] {
        guard account.hostname == "github.com", PRSearchRESTClient.validRepository(repository) else {
            throw GitHubTransportError.invalidResponse
        }
        let origin = "https://api.github.com"
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "/%?#")
        guard !baseBranch.isEmpty, let branch = baseBranch.addingPercentEncoding(withAllowedCharacters: allowed),
              let url = URL(string: "\(origin)/repos/\(repository)/rules/branches/\(branch)") else {
            throw GitHubTransportError.invalidResponse
        }
        var requirements: [GitHubApprovalRequirement] = []
        // A bounded complete read avoids mistaking a truncated ruleset list for a weaker policy.
        for page in 1...10 {
            var components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
            components.queryItems = [URLQueryItem(name: "per_page", value: "100"), URLQueryItem(name: "page", value: String(page))]
            guard let pageURL = components.url else { throw GitHubTransportError.invalidResponse }
            var request = URLRequest(url: pageURL)
            request.timeoutInterval = 30
            request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            request.setValue("Bearer \(account.accessToken.rawValue)", forHTTPHeaderField: "Authorization")
            request.setValue("GitHubBar/0.1", forHTTPHeaderField: "User-Agent")
            let (data, response) = try await session.data(for: request)
            guard let response = response as? HTTPURLResponse, response.statusCode == 200 else {
                throw GitHubTransportError.invalidResponse
            }
            let rules = try JSONDecoder().decode([BranchRule].self, from: data)
            requirements.append(contentsOf: try Self.requirements(from: rules))
            // Inspect only the continuation relation; never follow server-provided URLs with credentials.
            let link = response.value(forHTTPHeaderField: "Link") ?? ""
            let hasNext = link.range(of: #"rel\s*=\s*"?next"?"#, options: [.regularExpression, .caseInsensitive]) != nil
            if rules.count < 100 && !hasNext { return requirements }
        }
        throw GitHubTransportError.invalidResponse
    }

    static func decodeRequirements(_ data: Data) throws -> [GitHubApprovalRequirement] {
        try requirements(from: JSONDecoder().decode([BranchRule].self, from: data))
    }

    private static func requirements(from rules: [BranchRule]) throws -> [GitHubApprovalRequirement] {
        try rules.compactMap { rule in
            guard rule.type == "pull_request" else { return nil }
            guard let p = rule.parameters else { throw GitHubTransportError.invalidResponse }
            return GitHubApprovalRequirement(minimumApprovals: p.required_approving_review_count,
                dismissesStaleApprovals: p.dismiss_stale_reviews_on_push,
                requiresCodeOwner: p.require_code_owner_review,
                requiresLastPushApproval: p.require_last_push_approval,
                requiresSpecificReviewers: p.required_reviewers?.contains { $0.minimum_approvals > 0 } == true,
                requiresExtraApprovalForUnattributedChanges: p.require_extra_approval_for_unattributed_changes ?? false)
        }
    }
}

private struct BranchRule: Decodable {
    let type: String
    let parameters: Parameters?
    // Other rule types have unrelated parameter shapes.
    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        type = try c.decode(String.self, forKey: .type)
        parameters = type == "pull_request" ? try c.decode(Parameters.self, forKey: .parameters) : nil
    }
    enum CodingKeys: CodingKey { case type, parameters }
    struct Parameters: Decodable {
        let required_approving_review_count: Int
        let dismiss_stale_reviews_on_push: Bool
        let require_code_owner_review: Bool
        let require_last_push_approval: Bool
        let require_extra_approval_for_unattributed_changes: Bool?
        let required_reviewers: [RequiredReviewer]?
    }
    struct RequiredReviewer: Decodable { let minimum_approvals: Int }
}

struct ApprovalReview: Sendable {
    let login: String?
    let state: String
    let canPush: Bool?
    let commit: String?
}

enum ApprovalClassification {
    static func decision(aggregate: PullRequestReviewDecision?, author: String, authorIsHuman: Bool,
                         headSHA: String?, reviewsComplete: Bool, reviews: [ApprovalReview],
                         requirements: [GitHubApprovalRequirement]?) -> PullRequestReviewDecision? {
        if let aggregate { return aggregate }
        guard reviewsComplete, let requirements,
              requirements.allSatisfy({ $0.minimumApprovals >= 0 && !$0.requiresCodeOwner && !$0.requiresLastPushApproval && !$0.requiresSpecificReviewers && (!$0.requiresExtraApprovalForUnattributedChanges || authorIsHuman) }) else { return nil }
        guard !reviews.contains(where: { $0.state == "CHANGES_REQUESTED" && $0.login == nil && $0.canPush != false }) else { return nil }
        // Only submitted opinions supersede a previous opinion. Comment-only reviews do not revoke approval.
        var latest: [String: ApprovalReview] = [:]
        for review in reviews where ["APPROVED", "CHANGES_REQUESTED", "DISMISSED"].contains(review.state) {
            guard let login = review.login?.lowercased(), login != author.lowercased() else { continue }
            latest[login] = review
        }
        // Unknown eligibility could hide a blocking change request; do not infer approval.
        guard !latest.values.contains(where: { $0.state == "CHANGES_REQUESTED" && $0.canPush != false }) else { return nil }
        let minimum = max(1, requirements.map(\.minimumApprovals).max() ?? 0)
        let needsCurrentHead = requirements.contains(where: \.dismissesStaleApprovals)
        let count = latest.values.filter { review in
            review.state == "APPROVED" && review.canPush == true &&
                (!needsCurrentHead || (headSHA != nil && review.commit == headSHA))
        }.count
        return count >= minimum ? .approved : nil
    }
}
