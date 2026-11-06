import Foundation

public struct PullRequestPresentation: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let repositoryID: String
    public let repositoryNameWithOwner: String
    public let number: Int
    public let title: String
    public let url: URL
    public let isDraft: Bool
    public let state: PullRequestState
    public let author: PullRequestAuthorPresentation?
    public let reviewDecision: PullRequestReviewDecision?
    public let stackMembership: PullRequestStackMembership?
    public let createdAt: Date?
    public let updatedAt: Date
    public let requestedReviewers: [ReviewerPresentation]?
    public let reviewers: [ReviewerPresentation]
    public let reviewRosterIsComplete: Bool
    public let headSHA: String?

    public init(
        id: String,
        repositoryID: String,
        repositoryNameWithOwner: String,
        number: Int,
        title: String,
        url: URL,
        isDraft: Bool,
        state: PullRequestState = .open,
        author: PullRequestAuthorPresentation? = nil,
        reviewDecision: PullRequestReviewDecision? = nil,
        stackMembership: PullRequestStackMembership? = nil,
        createdAt: Date? = nil,
        updatedAt: Date,
        requestedReviewers: [ReviewerPresentation]? = [],
        reviewers: [ReviewerPresentation],
        headSHA: String? = nil,
        reviewRosterIsComplete: Bool = false
    ) {
        self.id = id
        self.repositoryID = repositoryID
        self.repositoryNameWithOwner = repositoryNameWithOwner
        self.number = number
        self.title = title
        self.url = url
        self.isDraft = isDraft
        self.state = state
        self.author = author
        self.reviewDecision = reviewDecision
        self.stackMembership = stackMembership
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.requestedReviewers = requestedReviewers
        self.reviewers = reviewers
        self.headSHA = headSHA
        self.reviewRosterIsComplete = reviewRosterIsComplete
    }

    /// Union requests with submitted-review participants, including older cached rows where
    /// only the request list was populated. Submitted opinion evidence wins duplicate IDs.
    public var reviewRoster: [ReviewerPresentation] {
        let requestedIDs = Set((requestedReviewers ?? []).map { $0.id.lowercased() })
        var order: [String] = []
        var byID: [String: ReviewerPresentation] = [:]
        for reviewer in (requestedReviewers ?? []) + reviewers {
            let key = reviewer.id.lowercased()
            guard key != author?.id.lowercased() else { continue }
            if byID[key] == nil { order.append(key) }
            let isRequested: Bool? = requestedIDs.contains(key) ? true
                : requestedReviewers != nil ? false : reviewer.isRequested
            byID[key] = ReviewerPresentation(id: reviewer.id, displayName: reviewer.displayName,
                avatarURL: reviewer.avatarURL, kind: reviewer.kind, reviewState: reviewer.reviewState,
                reviewStateIsComplete: reviewer.reviewStateIsComplete, isRequested: isRequested)
        }
        return order.compactMap { byID[$0] }
    }

    public var authoredSection: AuthoredPullRequestSection? {
        guard state == .open else { return nil }
        if isDraft { return .drafts }
        switch reviewDecision {
        case .changesRequested:
            return .returnedToYou
        case .approved:
            return .approved
        case .reviewRequired:
            return .waitingForReviewers
        case nil:
            guard let requestedReviewers else { return nil }
            return requestedReviewers.isEmpty ? .needsReviewers : .waitingForReviewers
        }
    }

    private enum CodingKeys: String, CodingKey {
        case id, repositoryID, repositoryNameWithOwner
        case number, title, url, isDraft, state, author
        case reviewDecision, stackMembership, createdAt, updatedAt, requestedReviewers, reviewers
        case headSHA, reviewRosterIsComplete
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        repositoryID = try container.decode(String.self, forKey: .repositoryID)
        repositoryNameWithOwner = try container.decode(String.self, forKey: .repositoryNameWithOwner)
        number = try container.decode(Int.self, forKey: .number)
        title = try container.decode(String.self, forKey: .title)
        url = try container.decode(URL.self, forKey: .url)
        isDraft = try container.decode(Bool.self, forKey: .isDraft)
        state = try container.decodeIfPresent(PullRequestState.self, forKey: .state) ?? .open
        author = try container.decodeIfPresent(PullRequestAuthorPresentation.self, forKey: .author)
        reviewDecision = try container.decodeIfPresent(PullRequestReviewDecision.self, forKey: .reviewDecision)
        stackMembership = try container.decodeIfPresent(
            PullRequestStackMembership.self,
            forKey: .stackMembership
        )
        createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt)
        updatedAt = try container.decode(Date.self, forKey: .updatedAt)
        reviewers = try container.decode([ReviewerPresentation].self, forKey: .reviewers)
        reviewRosterIsComplete = try container.decodeIfPresent(Bool.self, forKey: .reviewRosterIsComplete) ?? false
        headSHA = try container.decodeIfPresent(String.self, forKey: .headSHA)
        requestedReviewers = try container.decodeIfPresent(
            [ReviewerPresentation].self,
            forKey: .requestedReviewers
        )
    }
}

public enum PullRequestState: String, Codable, Equatable, Sendable {
    case open = "OPEN"
    case closed = "CLOSED"
    case merged = "MERGED"
}

public struct PullRequestAuthorPresentation: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let displayName: String
    public let avatarURL: URL?

    public init(id: String, displayName: String, avatarURL: URL?) {
        self.id = id
        self.displayName = displayName
        self.avatarURL = avatarURL
    }
}

public enum PullRequestReviewDecision: String, Codable, Equatable, Sendable {
    case approved = "APPROVED"
    case changesRequested = "CHANGES_REQUESTED"
    case reviewRequired = "REVIEW_REQUIRED"
}

public enum AuthoredPullRequestSection: String, Codable, CaseIterable, Equatable, Sendable {
    case returnedToYou
    case needsReviewers
    case waitingForReviewers
    case approved
    case drafts
}

public struct ReviewerPresentation: Codable, Equatable, Identifiable, Sendable {
    public enum Kind: String, Codable, Equatable, Sendable {
        case person
        case team
        case bot
    }

    public let id: String
    public let displayName: String
    public let avatarURL: URL?
    public enum ReviewState: String, Codable, Equatable, Sendable {
        case approved, changesRequested, dismissed
    }

    public let kind: Kind
    public let reviewState: ReviewState?
    public let reviewStateIsComplete: Bool
    /// True is positive request evidence. Nil means an incomplete request list cannot prove absence.
    public let isRequested: Bool?

    public init(id: String, displayName: String, avatarURL: URL?, kind: Kind,
                reviewState: ReviewState? = nil, reviewStateIsComplete: Bool = false, isRequested: Bool? = nil) {
        self.id = id
        self.displayName = displayName
        self.avatarURL = avatarURL
        self.kind = kind
        self.reviewState = reviewState
        self.reviewStateIsComplete = reviewStateIsComplete
        self.isRequested = isRequested
    }

    private enum CodingKeys: String, CodingKey {
        case id, displayName, avatarURL, kind, reviewState, reviewStateIsComplete, isRequested
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        displayName = try c.decode(String.self, forKey: .displayName)
        avatarURL = try c.decodeIfPresent(URL.self, forKey: .avatarURL)
        kind = try c.decode(Kind.self, forKey: .kind)
        reviewState = try c.decodeIfPresent(ReviewState.self, forKey: .reviewState)
        reviewStateIsComplete = try c.decodeIfPresent(Bool.self, forKey: .reviewStateIsComplete) ?? false
        isRequested = try c.decodeIfPresent(Bool.self, forKey: .isRequested)
    }
}
