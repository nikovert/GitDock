import Foundation
import GitHubBarCore
import Observation

enum ReviewWorkspaceMode: String, CaseIterable { case manage = "Dashboard", review = "Review" }
enum ReviewWorkspaceTab: String, CaseIterable { case overview = "Overview", changes = "Changes", threads = "Threads", workspace = "Workspace" }
enum ReviewWorkspaceQueue: String, CaseIterable {
    case attention = "Needs attention", mine = "My pull requests", requested = "Requested reviews"
    case pinned = "Pinned", snoozed = "Snoozed", all = "All PRs"
    var icon: String {
        switch self {
        case .attention: "tray.and.arrow.down"
        case .mine: "person.crop.circle"
        case .requested: "eye"
        case .pinned: "pin"
        case .snoozed: "moon"
        case .all: "tray.full"
        }
    }
}

struct ReviewLineSelection: Equatable, Hashable {
    let path: String
    let line: Int
    let side: String
    let text: String
}

@MainActor
@Observable
final class ReviewWorkspaceModel {
    var mode: ReviewWorkspaceMode = .manage
    var tab: ReviewWorkspaceTab = .overview
    var queue: ReviewWorkspaceQueue = .attention
    var search = ""
    var splitDiff = false
    var selection: ReviewLineSelection?
    private(set) var navigationRequest = 0
    var question = ""
    var inlineBody = ""
    private var selectedFilePath: String?
    private(set) var snapshot: PRReviewSnapshot?
    private(set) var loading = false
    private(set) var submitting = false
    private(set) var chatting = false
    private(set) var sinceLastReview = false
    var errorMessage: String?
    var notice: String?
    private(set) var chatErrorMessage: String?
    private(set) var chatContextTruncated = false
    private var retryPrompt: String?
    private var retryIdentity: ReviewIdentity?
    var canRetryChat: Bool { !chatting && retryPrompt != nil && retryIdentity == identity }
    var contextIsIncomplete: Bool {
        guard let snapshot else { return true }
        return chatContextTruncated || !snapshot.fileListComplete || snapshot.comparisonBaseSHA != nil ||
            snapshot.files.contains { !$0.hasCompletePatch } || !snapshot.notices.isEmpty
    }
    private(set) var submissionReceipt: PRReviewSubmissionReceipt?
    private var submittedIdentity: ReviewIdentity?
    private var submissionStatus: String?
    var submissionMessage: String? { submittedIdentity == identity ? submissionStatus : nil }
    private(set) var citations: [ReviewChatCitation] = []
    let local: ReviewWorkspaceState
    @ObservationIgnored private let service: any PRReviewServicing
    @ObservationIgnored private let chatService: any ReviewChatServicing
    @ObservationIgnored private(set) var loadTask: Task<Void, Never>?
    @ObservationIgnored private(set) var submitTask: Task<Void, Never>?
    @ObservationIgnored private(set) var chatTask: Task<Void, Never>?
    private var key: PullRequestKey?
    private var account: String?
    private var generation = 0
    private var chatGeneration = 0

    init(service: any PRReviewServicing = PRReviewClient(),
         chatService: any ReviewChatServicing = ReviewChatClient(),
         local: ReviewWorkspaceState = ReviewWorkspaceState()) {
        self.service = service; self.chatService = chatService; self.local = local
    }

    var identity: ReviewIdentity? {
        guard let snapshot, let account else { return nil }
        return ReviewIdentity(account: account, prURL: snapshot.key.url.absoluteString,
            headSHA: snapshot.headSHA, baseSHA: snapshot.baseSHA)
    }
    var draft: WorkspaceReviewDraft { identity.map(local.draft) ?? WorkspaceReviewDraft() }
    var selectedFile: PRSearchFile? {
        snapshot?.files.first { $0.path == (selectedFilePath ?? draft.selectedFile) } ?? snapshot?.files.first
    }
    var baseline: String? {
        guard let account, let key else { return nil }
        return local.lastReviewedSHA(ReviewIdentity(account: account, prURL: key.url.absoluteString, headSHA: ""))
    }

    func select(_ key: PullRequestKey?, account: String?, force: Bool = false) {
        let account = account?.lowercased()
        guard force || self.key != key || self.account != account else { return }
        let changedPR = self.key != key || self.account != account
        self.key = key; self.account = account
        if changedPR { sinceLastReview = false; question = ""; inlineBody = "" }
        generation += 1
        let revision = generation
        loadTask?.cancel(); stopChat()
        chatErrorMessage = nil; retryPrompt = nil; retryIdentity = nil; chatContextTruncated = false
        selection = nil; selectedFilePath = nil; citations = []; errorMessage = nil; notice = nil
        let comparison = sinceLastReview ? baseline : nil
        snapshot = nil
        guard let key, let account, !account.isEmpty else { loading = false; return }
        loading = true
        loadTask = Task { [weak self, service] in
            do {
                let loaded = try await service.load(key: key, accountLogin: account, sinceSHA: comparison)
                guard let self, revision == generation, !Task.isCancelled else { return }
                snapshot = loaded
                loading = false
            } catch {
                guard let self, revision == generation, !Task.isCancelled else { return }
                loading = false
                errorMessage = "Could not load this PR: \(error.localizedDescription)"
            }
        }
    }

    func refresh() { select(key, account: account, force: true) }
    func compareSinceLastReview(_ enabled: Bool) {
        guard !enabled || baseline != nil else { return }
        sinceLastReview = enabled
        refresh()
    }
    @discardableResult
    func editDraft(_ edit: (inout WorkspaceReviewDraft) -> Void) -> Bool {
        guard let identity, local.canSave else { return false }
        var value = local.draft(for: identity)
        edit(&value)
        return local.save(value, for: identity)
    }
    func selectFile(_ path: String) {
        selectedFilePath = path
        editDraft { $0.selectedFile = path }
        selection = nil
    }
    func markViewed(_ path: String, viewed: Bool) {
        editDraft { if viewed { $0.viewedFiles.insert(path) } else { $0.viewedFiles.remove(path) } }
    }
    func addInlineDraft() {
        guard let selection, !sinceLastReview, !inlineBody.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        guard local.canSave else {
            errorMessage = local.errorMessage ?? "Local review state cannot be saved. Your comment is still in the editor."
            return
        }
        guard snapshot?.canDraftInlineComment(in: selection.path) == true else {
            errorMessage = "This diff is incomplete. Read or comment on this file on GitHub."
            return
        }
        let comment = WorkspaceInlineDraft(path: selection.path, line: selection.line, side: selection.side, body: inlineBody)
        guard editDraft({ $0.comments.append(comment) }) else { return }
        inlineBody = ""
        self.selection = nil
    }
    func markReviewed() {
        guard let identity else { return }
        guard local.markReviewed(identity) else { errorMessage = local.errorMessage; return }
        notice = "Review position saved for commit \(identity.headSHA.prefix(8))."
    }

    func updateInlineDraft(_ id: UUID, body: String) {
        editDraft { value in
            if let index = value.comments.firstIndex(where: { $0.id == id }) { value.comments[index].body = body }
        }
    }

    func showDraft(_ comment: WorkspaceInlineDraft) {
        follow(ReviewChatCitation(path: comment.path, line: comment.line, side: comment.side))
    }

    func submitDraft(_ id: UUID, target: ReviewIdentity) {
        submit(event: .comment, target: target, selectedDraftIDs: [id])
    }

    func submit(event: PRReviewEvent, target: ReviewIdentity, selectedDraftIDs: Set<UUID>? = nil) {
        guard let identity, identity == target else {
            errorMessage = "The PR, account, or diff changed. Reopen the review sheet after reviewing the current changes."
            return
        }
        guard !submitting, let snapshot, !sinceLastReview, local.canSave else { return }
        let submitted = draft
        let selected = selectedDraftIDs.map { ids in submitted.comments.filter { ids.contains($0.id) } } ?? submitted.comments
        if let ids = selectedDraftIDs, ids.isEmpty || selected.count != ids.count { return }
        let body = selectedDraftIDs == nil ? submitted.body : ""
        guard event.permits(body: body, commentCount: selected.count),
              selected.allSatisfy({ !$0.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else {
            errorMessage = PRReviewError.invalidReview.localizedDescription
            return
        }
        let revision = generation
        submitting = true; errorMessage = nil; submissionReceipt = nil
        submittedIdentity = identity
        submissionStatus = selectedDraftIDs == nil ? "Posting review to GitHub…" : "Posting inline comment to GitHub…"
        submitTask = Task { [weak self, service] in
            guard let self else { return }
            defer { submitting = false }
            do {
                let comments = try selected.map { comment -> PRReviewDraftComment in
                    guard let side = PRReviewDraftComment.Side(rawValue: comment.side) else { throw PRReviewError.invalidComment }
                    return PRReviewDraftComment(id: comment.id, path: comment.path, line: comment.line, side: side, body: comment.body)
                }
                let receipt = try await service.submit(key: snapshot.key, accountLogin: identity.account,
                    headSHA: identity.headSHA, baseSHA: identity.baseSHA, event: event, body: body, comments: comments)
                guard receipt.id > 0, receipt.headSHA == identity.headSHA, receipt.event == event else {
                    throw PRReviewError.invalidResponse
                }
                // Read current storage after the await. Only exact versions confirmed by this POST are removed.
                var saved = local.draft(for: identity)
                if selectedDraftIDs == nil && saved.body == submitted.body { saved.body = "" }
                saved.comments.removeAll { current in selected.contains(current) }
                guard local.save(saved, for: identity) else {
                    submissionStatus = "GitHub confirmed review #\(receipt.id), but local cleanup failed. Check GitHub before posting again."
                    return
                }
                if selectedDraftIDs == nil { local.markReviewed(identity) }
                submissionReceipt = receipt
                submissionStatus = "Posted to GitHub · review #\(receipt.id) · @\(identity.account) · PR #\(snapshot.key.number)"
                guard revision == generation else { return }
                notice = submissionStatus
                refreshDiscussion(for: identity, revision: revision)
            } catch {
                submissionStatus = "Review was not confirmed: \(error.localizedDescription) Your draft is retained. Check GitHub before retrying."
                if revision == generation { errorMessage = submissionStatus }
            }
        }
    }

    private func refreshDiscussion(for target: ReviewIdentity, revision: Int) {
        guard let key else { return }
        loadTask?.cancel()
        loadTask = Task { [weak self, service] in
            do {
                let loaded = try await service.load(key: key, accountLogin: target.account, sinceSHA: nil)
                guard let self, generation == revision, !Task.isCancelled, identity == target else { return }
                snapshot = loaded
            } catch {
                guard let self, generation == revision, !Task.isCancelled else { return }
                errorMessage = "Review posted, but discussion could not refresh: \(error.localizedDescription)"
            }
        }
    }

    func sendQuestion(configuration: ReviewChatConfiguration, policy: String) {
        guard !chatting, local.canSave, let identity, let snapshot else { return }
        let prompt = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty else { return }
        let retrying = retryIdentity == identity && retryPrompt == prompt
        let revision = generation
        chatContextTruncated = snapshot.body.count + snapshot.files.reduce(0, { $0 + ($1.patch?.count ?? 0) }) > 39_000 || draft.messages.count > 20
        chatGeneration += 1
        let chatRevision = chatGeneration
        var context = "\(snapshot.title)\n\(snapshot.body)\n"
        if let selection { context += "Selected \(selection.path):\(selection.line) \(selection.side)\n\(selection.text)\n" }
        for file in snapshot.files {
            guard context.count < 40_000 else { chatContextTruncated = true; break }
            let excerpt = String((file.patch ?? "Patch unavailable").prefix(max(0, 40_000 - context.count)))
            if excerpt.count < (file.patch?.count ?? 0) { chatContextTruncated = true }
            context += "\nFile: \(file.path)\n\(excerpt)\n"
        }
        if context.count > 40_000 { chatContextTruncated = true }
        context = String(context.prefix(40_000)) + "\nContext may be truncated; say when evidence is missing."
        var history = draft.messages
        if retrying && history.last?.role == "user" && history.last?.text == prompt { history.removeLast() }
        let messages = history.suffix(20).map {
            ReviewChatMessage(role: $0.role == "user" ? .user : .assistant, text: $0.text)
        }
        var request = ReviewChatRequest(accountLogin: identity.account, prURL: identity.prURL,
            headSHA: identity.headSHA, question: prompt, context: context, policy: policy, messages: messages)
        // Bound the actual JSON bytes, including escaped source and multi-byte text.
        func requestSize() -> Int { (try? JSONEncoder().encode(request).count) ?? Int.max }
        while requestSize() > 750_000, !request.messages.isEmpty { request.messages.removeFirst(); chatContextTruncated = true }
        while requestSize() > 750_000, !request.context.isEmpty {
            request.context = String(request.context.prefix(request.context.count / 2)); chatContextTruncated = true
        }
        guard requestSize() <= 750_000 else {
            chatErrorMessage = "This question is too large for the chat adapter. Shorten it and try again."
            return
        }
        if !retrying { appendMessage(WorkspaceChatMessage(role: "user", text: prompt), for: identity) }
        retryPrompt = prompt; retryIdentity = identity; chatErrorMessage = nil
        question = ""; chatting = true; errorMessage = nil; citations = []
        chatTask = Task { [weak self, chatService] in
            do {
                let response = try await chatService.send(request, configuration: configuration)
                guard let self, generation == revision, chatGeneration == chatRevision, !Task.isCancelled else { return }
                chatting = false
                appendMessage(WorkspaceChatMessage(role: "assistant", text: response.answer), for: identity)
                citations = response.citations
                retryPrompt = nil; retryIdentity = nil; chatErrorMessage = nil
            } catch {
                guard let self, generation == revision, chatGeneration == chatRevision, !Task.isCancelled else { return }
                chatting = false
                question = prompt
                chatErrorMessage = "Agent could not answer: \(error.localizedDescription)"
            }
        }
    }

    func retryQuestion(configuration: ReviewChatConfiguration, policy: String) {
        guard canRetryChat, let retryPrompt else { return }
        question = retryPrompt
        sendQuestion(configuration: configuration, policy: policy)
    }

    func stopChat() {
        if chatting { chatErrorMessage = "Cancelled. Your question is available to retry." }
        chatGeneration += 1; chatTask?.cancel(); chatting = false
    }

    private func appendMessage(_ message: WorkspaceChatMessage, for identity: ReviewIdentity) {
        var saved = local.draft(for: identity)
        saved.messages.append(message)
        local.save(saved, for: identity)
    }

    func follow(_ citation: ReviewChatCitation) {
        guard let side = PRReviewDraftComment.Side(rawValue: citation.side),
              snapshot?.containsLine(path: citation.path, line: citation.line, side: side) == true,
              let file = snapshot?.files.first(where: { $0.path == citation.path }),
              let patch = file.patch,
              let line = PRDiffParser.parse(patch).first(where: {
                  citation.side == "LEFT" ? $0.oldLine == citation.line : $0.newLine == citation.line
              }) else {
            errorMessage = "That citation is outside the available diff. Open the file on GitHub for more context."
            return
        }
        selectFile(file.path)
        selection = ReviewLineSelection(path: file.path, line: citation.line, side: citation.side, text: line.text)
        navigationRequest += 1
        tab = .changes
    }
}
