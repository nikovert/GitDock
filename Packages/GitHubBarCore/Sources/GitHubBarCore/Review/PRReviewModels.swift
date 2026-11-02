import Foundation

public protocol PRReviewServicing: Sendable {
    func load(key: PullRequestKey, accountLogin: String, sinceSHA: String?) async throws -> PRReviewSnapshot
    func submit(key: PullRequestKey, accountLogin: String, headSHA: String, baseSHA: String, event: PRReviewEvent,
                body: String, comments: [PRReviewDraftComment]) async throws -> PRReviewSubmissionReceipt
}

public struct PRReviewSnapshot: Equatable, Sendable {
    public let key: PullRequestKey
    public let title: String
    public let body: String
    public let author: String
    public let createdAt: Date?
    public let updatedAt: Date
    public let headSHA: String
    public let baseSHA: String
    public let files: [PRSearchFile]
    public let notices: [String]
    public let comments: [PRReviewComment]
    public let checksSummary: String
    public let comparisonBaseSHA: String?
    public let fileListComplete: Bool

    public init(key: PullRequestKey, title: String, body: String, author: String, createdAt: Date?,
                updatedAt: Date, headSHA: String, baseSHA: String, files: [PRSearchFile],
                notices: [String], comments: [PRReviewComment], checksSummary: String,
                comparisonBaseSHA: String? = nil, fileListComplete: Bool = false) {
        self.key = key; self.title = title; self.body = body; self.author = author
        self.createdAt = createdAt; self.updatedAt = updatedAt
        self.headSHA = headSHA; self.baseSHA = baseSHA; self.files = files
        self.notices = notices; self.comments = comments; self.checksSummary = checksSummary
        self.comparisonBaseSHA = comparisonBaseSHA
        self.fileListComplete = fileListComplete
    }

    public func canDraftInlineComment(in path: String) -> Bool {
        comparisonBaseSHA == nil && fileListComplete
            && files.contains { $0.path == path && $0.hasCompletePatch }
    }
}

public enum PRReviewEvent: String, Codable, CaseIterable, Sendable {
    case comment = "COMMENT"
    case approve = "APPROVE"
    case requestChanges = "REQUEST_CHANGES"

    public func permits(body: String, commentCount: Int) -> Bool {
        let hasBody = !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        switch self {
        case .approve: return true
        case .comment: return hasBody || commentCount > 0
        case .requestChanges: return hasBody
        }
    }

    public var submittedState: String {
        switch self {
        case .comment: "COMMENTED"
        case .approve: "APPROVED"
        case .requestChanges: "CHANGES_REQUESTED"
        }
    }
}

/// Returned only after GitHub confirms a submitted review for the pinned commit.
public struct PRReviewSubmissionReceipt: Equatable, Sendable {
    public let id: Int
    public let headSHA: String
    public let event: PRReviewEvent
    public let url: URL?

    public init(id: Int, headSHA: String, event: PRReviewEvent, url: URL? = nil) {
        self.id = id; self.headSHA = headSHA; self.event = event; self.url = url
    }
}

public struct PRReviewDraftComment: Codable, Equatable, Identifiable, Sendable {
    public enum Side: String, Codable, CaseIterable, Sendable { case left = "LEFT", right = "RIGHT" }
    public let id: UUID
    public let path: String
    public let line: Int
    public let side: Side
    public var body: String
    /// Comparison coordinates must never be sent as pull-request diff coordinates.
    public let comparisonBaseSHA: String?

    public init(id: UUID = UUID(), path: String, line: Int, side: Side, body: String,
                comparisonBaseSHA: String? = nil) {
        self.id = id; self.path = path; self.line = line; self.side = side; self.body = body
        self.comparisonBaseSHA = comparisonBaseSHA
    }
}

public struct PRReviewComment: Equatable, Identifiable, Sendable {
    public let id: String
    public let author: String
    public let body: String
    public let path: String?
    public let line: Int?
    public let url: URL?
    public let createdAt: Date?
    public let replyToID: String?
    public let side: PRReviewDraftComment.Side?
    public let isOutdated: Bool
    public let originalLine: Int?

    public init(id: String, author: String, body: String, path: String? = nil, line: Int? = nil,
                url: URL? = nil, createdAt: Date? = nil, replyToID: String? = nil,
                side: PRReviewDraftComment.Side? = nil, isOutdated: Bool = false, originalLine: Int? = nil) {
        self.id = id; self.author = author; self.body = body; self.path = path; self.line = line
        self.url = url; self.createdAt = createdAt; self.replyToID = replyToID
        self.side = side; self.isOutdated = isOutdated; self.originalLine = originalLine
    }
}

public enum PRReviewError: Error, Equatable, Sendable, LocalizedError {
    case connectionRequired, accountMismatch, invalidResponse, revisionChanged
    case invalidComment, comparisonDraft, invalidReview, submissionRejected

    public var errorDescription: String? {
        switch self {
        case .connectionRequired: "Connect the selected GitHub account before reviewing."
        case .accountMismatch: "The verified GitHub account or host does not match this review."
        case .invalidResponse: "GitHub returned an invalid review response."
        case .revisionChanged: "The pull request changed. Reload it and review your drafts before submitting."
        case .invalidComment: "A draft is not on a complete, current diff line. Reload and check its path, side, and line."
        case .comparisonDraft: "Comparison lines cannot receive review comments. Return to the full PR diff and recreate the draft."
        case .invalidReview: "Add a summary or inline comments for Comment. Request changes requires a summary; inline comments must be nonempty."
        case .submissionRejected: "GitHub rejected this review. Check your review and permissions; your drafts remain local."
        }
    }
}
