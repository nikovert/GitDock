import AppKit
import GitHubBarCore
import Observation

private enum WorkspaceAction: Hashable {
    case priority(BoardSubject)
    case tag(BoardSubject, String)
    case note(BoardSubject)
    case checkout(String)
    case worktreeRoot
    case saveTag(String)
    case launch(BoardSubject, AgentKind)
    case pin(BoardSubject, AgentKind)
    case stop(UUID)
    case restart(UUID)
    case unlink(UUID)
    case removeWorktree(UUID)
    case focus(UUID)

}

@MainActor
@Observable
final class WorkspaceModel {
    let cleanup: WorktreeCleanupModel
    private(set) var document: LocalWorkspaceDocument = .empty
    private(set) var priorityAuthors: [String] = []
    @ObservationIgnored private let priorityDefaults: UserDefaults
    static let priorityAuthorsKey = "githubbar.workspace.priority-authors"
    private(set) var monitoredAccountLogin: String?
    private(set) var reviewContexts: [String: AgentPRContext] = [:]
    var selectedSubject: BoardSubject?
    private var navigationPullRequest: PullRequestPresentation?
    var errorMessage: String?

    @ObservationIgnored private let store: LocalWorkspaceStore
    @ObservationIgnored private let sessions: AgentSessionManager
    @ObservationIgnored private var pollingTask: Task<Void, Never>?
    @ObservationIgnored private var failedAction: WorkspaceAction?
    private var pendingActions: Set<WorkspaceAction> = []
    @ObservationIgnored var onDocumentChange: (() -> Void)?

    init(
        store: LocalWorkspaceStore,
        sessions: AgentSessionManager,
        reviewStore: AgentReviewStore = AgentReviewStore(),
        defaults: UserDefaults = .standard
    ) {
        self.store = store
        self.sessions = sessions
        priorityDefaults = defaults
        if let saved = defaults.stringArray(forKey: Self.priorityAuthorsKey) {
            priorityAuthors = saved
        } else {
            // Read legacy preferences once without invoking its transactional worker store,
            // whose load() expires jobs. Worker state stays byte-for-byte inert.
            let file = reviewStore.directoryURL.appendingPathComponent("agent-reviews.json")
            if let data = try? Data(contentsOf: file), let legacy = try? AgentReviewStore.decoder.decode(AgentReviewDocument.self, from: data) {
                priorityAuthors = legacy.priorityAuthors
                defaults.set(legacy.priorityAuthors, forKey: Self.priorityAuthorsKey)
            }
        }
        cleanup = WorktreeCleanupModel(service: WorktreeCleanupCoordinator(store: store, sessions: sessions))
        cleanup.onCompletion = { [weak self] in await self?.reload() }
    }

    func start() {
        guard pollingTask == nil else { return }
        pollingTask = Task { [weak self] in
            while !Task.isCancelled {
                _ = try? await self?.sessions.refreshStates()
                await self?.reload()
                try? await Task.sleep(for: .seconds(5))
            }
        }
    }

    func stop() {
        pollingTask?.cancel()
        pollingTask = nil
    }

    func reload() async {
        do {
            let loaded = try await store.load()
            cleanup.updateConfiguration(loaded.configuration)
            if loaded != document {
                document = loaded
                onDocumentChange?()
            }
        } catch {
            if errorMessage == nil {
                errorMessage = "Could not read the local workspace: \(error.localizedDescription)"
            }
        }
    }

    func setPriority(_ priority: BoardPriority, for subject: BoardSubject) {
        updateEntry(subject, action: .priority(subject)) {
            $0.priority = priority == .none ? nil : priority
        }
    }

    func updateWorkload(_ state: AppPresentationState) {
        let previousLogin = monitoredAccountLogin
        if case let .connected(login, _) = state.accountConnection {
            monitoredAccountLogin = login
        } else {
            monitoredAccountLogin = nil
        }
        if previousLogin?.lowercased() != monitoredAccountLogin?.lowercased() {
            if let navigationPullRequest,
               selectedSubject?.key == (try? PullRequestKey(url: navigationPullRequest.url)) {
                selectedSubject = nil
            }
            navigationPullRequest = nil
        }
        reviewContexts = WorkspaceReviewContext.contexts(in: state)
        cleanup.updateAccount(monitoredAccountLogin)
    }

    func openPullRequest(_ pullRequest: PullRequestPresentation) {
        guard let key = try? PullRequestKey(url: pullRequest.url) else { return }
        navigationPullRequest = pullRequest
        selectedSubject = .pullRequest(key)
    }

    func pullRequests(in state: AppPresentationState) -> [PullRequestPresentation] {
        var result = state.needsYourReview + state.authoredPullRequests
        guard let navigationPullRequest, let key = try? PullRequestKey(url: navigationPullRequest.url) else {
            return result
        }
        let current = (result + state.pullRequestStacks.flatMap(\.pullRequests)).first {
            (try? PullRequestKey(url: $0.url)) == key
        }
        let selected = current.map { $0.updatedAt >= navigationPullRequest.updatedAt ? $0 : navigationPullRequest }
            ?? navigationPullRequest
        result.removeAll { (try? PullRequestKey(url: $0.url)) == key }
        result.append(selected)
        return result
    }

    func reviewContext(for pullRequest: PullRequestPresentation) -> AgentPRContext {
        let url = (try? PullRequestKey(url: pullRequest.url))?.url.absoluteString ?? pullRequest.url.absoluteString
        return reviewContexts[url] ?? WorkspaceReviewContext.make(pullRequest,
            accountLogin: monitoredAccountLogin ?? "", stackURL: nil)
    }

    func reviewPriority(for context: AgentPRContext) -> AgentPriority {
        context.priority(in: document, priorityAuthors: priorityAuthors)
    }

    func setPriorityAuthors(_ authors: [String]) {
        priorityAuthors = Array(Set(authors.map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }.filter { !$0.isEmpty })).sorted()
        priorityDefaults.set(priorityAuthors, forKey: Self.priorityAuthorsKey)
    }

    func setTag(_ id: String, enabled: Bool, currentIDs: Set<String>, for subject: BoardSubject) {
        updateEntry(subject, action: .tag(subject, id)) { entry in
            var tags = entry.tagIDs ?? currentIDs
            if enabled { tags.insert(id) } else { tags.remove(id) }
            entry.tagIDs = tags
        }
    }

    func setNote(_ note: String, for subject: BoardSubject) {
        updateEntry(subject, action: .note(subject)) { $0.note = note }
    }

    private func updateEntry(
        _ subject: BoardSubject,
        action: WorkspaceAction,
        edit: @escaping @Sendable (inout BoardEntry) -> Void
    ) {
        perform(action) { [store] in
            _ = try await store.update { document in
                var entry = document.entry(for: subject) ?? BoardEntry(subject: subject)
                edit(&entry)
                entry.updatedAt = .now
                entry.updatedBy = "local"
                document.setEntry(entry)
            }
        }
    }

    func saveCheckout(_ path: String, for repository: String) {
        perform(.checkout(repository)) { [store] in
            _ = try await store.update { $0.configuration.repositoryCheckouts[repository] = path }
        }
    }

    func saveWorktreeRoot(_ path: String) {
        perform(.worktreeRoot) { [store] in
            _ = try await store.update { $0.configuration.worktreeRoot = path }
        }
    }

    func saveTag(_ tag: BoardTag) {
        perform(.saveTag(tag.id)) { [store] in _ = try await store.update { $0.setTag(tag) } }
    }

    func createTag(name: String, color: BoardTagColor) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let tag = BoardTag(id: "custom-\(UUID().uuidString.lowercased())", name: trimmed, color: color)
        saveTag(tag)
    }

    func launch(_ agent: AgentKind, for subject: BoardSubject) {
        perform(.launch(subject, agent)) { [sessions] in
            _ = try await sessions.launch(subject: subject, agent: agent)
        }
    }

    func pin(_ agent: AgentKind, for subject: BoardSubject, path: String, tmuxName: String?) {
        perform(.pin(subject, agent)) { [sessions] in
            _ = try await sessions.pinExisting(
                subject: subject, agent: agent, worktreePath: path,
                tmuxSessionName: tmuxName?.isEmpty == true ? nil : tmuxName
            )
        }
    }

    func stopSession(_ id: UUID) {
        perform(.stop(id)) { [sessions] in try await sessions.stop(id: id) }
    }

    func restartSession(_ id: UUID) {
        perform(.restart(id)) { [sessions] in _ = try await sessions.restart(id: id) }
    }

    func unlinkSession(_ id: UUID) {
        perform(.unlink(id)) { [sessions] in try await sessions.unlink(id: id) }
    }

    func removeWorktree(_ id: UUID) {
        perform(.removeWorktree(id)) { [sessions] in
            try await sessions.removeManagedWorktree(id: id)
        }
    }

    func focus(_ session: AgentSessionLink) {
        let action = WorkspaceAction.focus(session.id)
        beginAttempt(action)
        do {
            try TerminalSessionOpener.open(session)
        } catch {
            errorMessage = "Could not open Terminal: \(error.localizedDescription)"
            failedAction = action
        }
    }

    private func beginAttempt(_ action: WorkspaceAction) {
        if failedAction == action {
            errorMessage = nil
            failedAction = nil
        }
    }

    private func perform(
        _ action: WorkspaceAction,
        operation: @escaping @Sendable () async throws -> Void
    ) {
        beginAttempt(action)
        pendingActions.insert(action)
        Task {
            defer { pendingActions.remove(action) }
            do {
                try await operation()
                await reload()
            } catch {
                errorMessage = error.localizedDescription
                failedAction = action
            }
        }
    }
}
