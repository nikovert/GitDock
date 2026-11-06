import Foundation
import GitDockCore
import Observation

protocol PRSearchServing: Sendable {
    func states() async -> AsyncStream<PRSearchState>
    func configure(login: String?, current: [PullRequestPresentation], repositories: [String]) async
    func query(_ value: String) async
    func search(extended: Bool) async
    func pause() async
    func clear() async
}

@MainActor
@Observable
final class PRSearchModel {
    private(set) var state = PRSearchState()
    private(set) var query = ""
    private(set) var extended = false
    private(set) var repositories: [String] = []
    private(set) var accountLogin: String?
    var repositoryInput = ""
    var inputError: String?
    var visibleListCount = 50
    var visibleExtendedCount = 50
    var focusRequest = UUID()

    @ObservationIgnored private let service: any PRSearchServing
    @ObservationIgnored private var contextGeneration = 0
    @ObservationIgnored private var streamTask: Task<Void, Never>?
    @ObservationIgnored private(set) var pendingCommand: Task<Void, Never>?
    @ObservationIgnored private var workload = AppPresentationState.empty
    @ObservationIgnored private var followsDefaultRepositories = true
    @ObservationIgnored private var configured = false
    @ObservationIgnored private var hasEditedQuery = false

    init(service: any PRSearchServing) { self.service = service }

    var isSearching: Bool { state.phase == .indexing || state.phase == .validating }
    var canSearch: Bool { accountLogin != nil && !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    func updateWorkload(_ value: AppPresentationState) {
        let login = PRSearchScope.accountLogin(in: value)
        let accountChanged = login?.lowercased() != accountLogin?.lowercased()
        let previousPRs = PRSearchScope.activePullRequests(in: workload)
        let previousRepositories = repositories
        workload = value
        accountLogin = login
        if accountChanged {
            hasEditedQuery = false
            followsDefaultRepositories = true
            query = ""
            extended = false
            repositoryInput = ""
            inputError = nil
        }
        if followsDefaultRepositories { repositories = PRSearchScope.defaultRepositories(in: value) }
        if !configured || accountChanged || previousRepositories != repositories ||
            previousPRs != PRSearchScope.activePullRequests(in: value) {
            configureContext()
        }
    }

    func setQuery(_ value: String) {
        hasEditedQuery = true
        query = value
        resetPagination()
        let service = service
        enqueue { await service.query(value) }
    }

    func setExtended(_ value: Bool) {
        extended = value
        if !value { pause() }
    }

    func submit() {
        guard canSearch else { return }
        inputError = nil
        let service = service
        let query = query
        let extended = extended
        enqueue {
            await service.query(query)
            await service.search(extended: extended)
        }
    }

    func pause() {
        let service = service
        enqueue { await service.pause() }
    }

    func close() { pause() }

    func clearCache() {
        invalidatePresentation()
        let generation = contextGeneration
        let service = service
        enqueue { [weak self] in
            await service.clear()
            self?.subscribe(generation: generation)
        }
    }

    func addRepository(_ input: String) {
        guard let name = PRSearchScope.normalizedRepository(input) else {
            inputError = "Enter a repository as owner/repository, not a URL or search expression."
            return
        }
        inputError = nil
        repositoryInput = ""
        guard !repositories.contains(name) else { return }
        followsDefaultRepositories = false
        repositories = (repositories + [name]).sorted()
        configureContext()
    }

    func removeRepository(_ name: String) {
        followsDefaultRepositories = false
        repositories.removeAll { $0 == name }
        configureContext()
    }

    func useDefaultRepositories() {
        followsDefaultRepositories = true
        repositories = PRSearchScope.defaultRepositories(in: workload)
        configureContext()
    }

    private func configureContext() {
        configured = true
        invalidatePresentation()
        let generation = contextGeneration
        let service = service
        let login = accountLogin
        let current = PRSearchScope.activePullRequests(in: workload)
        let repositories = repositories
        let query = query
        let preserveRestoredQuery = !hasEditedQuery && query.isEmpty
        enqueue { [weak self] in
            await service.configure(login: login, current: current, repositories: repositories)
            if !preserveRestoredQuery { await service.query(query) }
            self?.subscribe(generation: generation)
        }
    }

    private func invalidatePresentation() {
        contextGeneration += 1
        streamTask?.cancel()
        streamTask = nil
        state = PRSearchState()
        state.query = query
        resetPagination()
    }

    private func subscribe(generation: Int) {
        guard generation == contextGeneration else { return }
        streamTask?.cancel()
        let service = service
        streamTask = Task { [weak self] in
            let states = await service.states()
            for await state in states {
                guard !Task.isCancelled, let self, self.contextGeneration == generation else { return }
                if !self.hasEditedQuery, self.query.isEmpty, state.submittedQuery == state.query,
                   !state.query.isEmpty {
                    self.query = state.query
                    self.hasEditedQuery = true
                }
                guard state.query == self.query else { continue }
                self.state = state
            }
        }
    }

    private func resetPagination() { visibleListCount = 50; visibleExtendedCount = 50 }

    private func enqueue(_ operation: @escaping @MainActor @Sendable () async -> Void) {
        let previous = pendingCommand
        pendingCommand = Task {
            await previous?.value
            guard !Task.isCancelled else { return }
            await operation()
        }
    }
}
