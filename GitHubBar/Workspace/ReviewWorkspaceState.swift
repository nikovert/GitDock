import Foundation
import Observation

struct ReviewIdentity: Codable, Equatable, Hashable {
    let account: String
    let prURL: String
    let headSHA: String
    let baseSHA: String

    init(account: String, prURL: String, headSHA: String, baseSHA: String = "") {
        self.account = account; self.prURL = prURL; self.headSHA = headSHA; self.baseSHA = baseSHA
    }

    var prKey: String { account.lowercased() + "|" + prURL }
    var revisionKey: String { prKey + "|" + headSHA + (baseSHA.isEmpty ? "" : "|" + baseSHA) }
}

struct WorkspaceInlineDraft: Codable, Equatable, Identifiable {
    var id = UUID()
    var path: String
    var line: Int
    var side: String
    var body: String
    var agentName: String? = nil
    var reviewRunID: UUID? = nil
    var createdAt: Date? = nil
}

struct WorkspaceGeneralDraft: Codable, Equatable, Identifiable {
    var id = UUID()
    var body: String
    var agentName: String? = nil
    var reviewRunID: UUID? = nil
    var anchorDescription: String? = nil
    var createdAt: Date? = nil
    var publicationBody: String {
        guard let anchorDescription else { return body }
        return body + "\n\nOriginal agent location (not attached to a current diff line): " + anchorDescription
    }
}

struct WorkspaceAgentReviewReceipt: Codable, Equatable {
    let id: UUID
    let provider: String
    let completedAt: Date
    let summary: String
    let findingCount: Int
    let contextIncomplete: Bool
}

struct WorkspaceChatMessage: Codable, Equatable, Identifiable {
    var id = UUID()
    var role: String
    var text: String
}

struct WorkspaceReviewDraft: Codable, Equatable {
    var body = ""
    var comments: [WorkspaceInlineDraft] = []
    var generalComments: [WorkspaceGeneralDraft] = []
    var viewedFiles: Set<String> = []
    var selectedFile: String?
    var messages: [WorkspaceChatMessage] = []
    var lastAgentReview: WorkspaceAgentReviewReceipt?
    var allDraftCount: Int { comments.count + generalComments.count }
    var hasUnsubmittedComments: Bool { !body.isEmpty || allDraftCount > 0 }
    var publicationBody: String {
        ([body] + generalComments.map(\.publicationBody)).filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .joined(separator: "\n\n---\n\n")
    }

    init() {}
    private enum CodingKeys: CodingKey { case body, comments, generalComments, viewedFiles, selectedFile, messages, lastAgentReview }
    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        body = try c.decodeIfPresent(String.self, forKey: .body) ?? ""
        comments = try c.decodeIfPresent([WorkspaceInlineDraft].self, forKey: .comments) ?? []
        generalComments = try c.decodeIfPresent([WorkspaceGeneralDraft].self, forKey: .generalComments) ?? []
        viewedFiles = try c.decodeIfPresent(Set<String>.self, forKey: .viewedFiles) ?? []
        selectedFile = try c.decodeIfPresent(String.self, forKey: .selectedFile)
        messages = try c.decodeIfPresent([WorkspaceChatMessage].self, forKey: .messages) ?? []
        lastAgentReview = try c.decodeIfPresent(WorkspaceAgentReviewReceipt.self, forKey: .lastAgentReview)
    }
}

@MainActor
@Observable
final class ReviewWorkspaceState {
    static let storageKey = "githubbar.review-workspace.v1"
    private struct Document: Codable {
        var drafts: [String: WorkspaceReviewDraft] = [:]
        var pins: Set<String> = []
        var snoozedUntil: [String: Date] = [:]
        var reviewedSHA: [String: String] = [:]
    }

    private var document = Document()
    private(set) var errorMessage: String?
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var writable = true
    var canSave: Bool { writable && errorMessage == nil }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.storageKey) {
            do { document = try JSONDecoder().decode(Document.self, from: data) }
            catch {
                writable = false
                errorMessage = "Saved review state could not be read. The original data has been retained; saving is disabled."
            }
        }
    }

    func draft(for identity: ReviewIdentity) -> WorkspaceReviewDraft {
        document.drafts[identity.revisionKey] ?? WorkspaceReviewDraft()
    }

    @discardableResult
    func save(_ draft: WorkspaceReviewDraft, for identity: ReviewIdentity) -> Bool {
        guard canSave else { return false }
        document.drafts[identity.revisionKey] = draft
        return persist()
    }

    func previousDraftHeads(_ identity: ReviewIdentity) -> [String] {
        previousDraftIdentities(identity).map(\.headSHA)
    }

    func previousDraftIdentities(_ identity: ReviewIdentity) -> [ReviewIdentity] {
        let prefix = identity.prKey + "|"
        return document.drafts.filter {
            $0.key.hasPrefix(prefix) && $0.key != identity.revisionKey && $0.value.hasUnsubmittedComments
        }.keys.sorted().compactMap { key in
            let parts = key.dropFirst(prefix.count).split(separator: "|", omittingEmptySubsequences: false)
            guard parts.count == 1 || parts.count == 2 else { return nil }
            return ReviewIdentity(account: identity.account, prURL: identity.prURL,
                headSHA: String(parts[0]), baseSHA: parts.count == 2 ? String(parts[1]) : "")
        }
    }

    func isPinned(_ identity: ReviewIdentity) -> Bool { document.pins.contains(identity.prKey) }
    func setPinned(_ value: Bool, for identity: ReviewIdentity) {
        guard writable else { return }
        if value { document.pins.insert(identity.prKey) } else { document.pins.remove(identity.prKey) }
        persist()
    }

    func isSnoozed(_ identity: ReviewIdentity, now: Date = .now) -> Bool {
        (document.snoozedUntil[identity.prKey] ?? .distantPast) > now
    }

    func snooze(until date: Date?, for identity: ReviewIdentity) {
        guard writable else { return }
        document.snoozedUntil[identity.prKey] = date
        persist()
    }

    func lastReviewedSHA(_ identity: ReviewIdentity) -> String? { document.reviewedSHA[identity.prKey] }
    @discardableResult
    func markReviewed(_ identity: ReviewIdentity) -> Bool {
        guard canSave else { return false }
        document.reviewedSHA[identity.prKey] = identity.headSHA
        return persist()
    }

    @discardableResult
    private func persist() -> Bool {
        do { defaults.set(try JSONEncoder().encode(document), forKey: Self.storageKey); return true }
        catch { errorMessage = "Could not save review state: \(error.localizedDescription)"; return false }
    }
}
