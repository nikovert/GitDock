import Foundation

public actor PRSearchEngine {
    private let connection: any AccountConnection
    private let client: PRSearchRESTClient
    private let index: any PRSearchIndex
    private let now: @Sendable () -> Date
    private var state = PRSearchState()
    private var account: AccountCandidate?
    private var hasContext = false
    private var active: [PullRequestPresentation] = []
    private var repositories: [String] = []
    private var extended = true
    private var generation = 0
    private var task: Task<Void, Never>?
    private var observers: [UUID: AsyncStream<PRSearchState>.Continuation] = [:]
    private var validated: [String: Revision] = [:]
    private var results: [String: PRSearchResult] = [:]
    private var discovered = Set<String>()
    private var indexed = Set<String>()
    private var partial = Set<String>()

    private struct Revision: Equatable {
        let base: String
        let head: String
        let updated: Date
        init(_ document: PRSearchDocument) {
            base = document.baseSHA; head = document.headSHA; updated = document.pullRequest.updatedAt
        }
    }

    public init(accountConnection: any AccountConnection = GitHubCLIAccountConnection(),
                transport: any PRSearchTransport = URLSessionPRSearchTransport(),
                index: any PRSearchIndex = SQLitePRSearchIndex(),
                now: @escaping @Sendable () -> Date = { Date() }) {
        connection = accountConnection
        client = PRSearchRESTClient(transport: transport, now: now)
        self.index = index
        self.now = now
    }

    deinit { task?.cancel() }

    public func states() -> AsyncStream<PRSearchState> {
        let id = UUID()
        let (stream, continuation) = AsyncStream<PRSearchState>.makeStream(bufferingPolicy: .bufferingNewest(1))
        observers[id] = continuation
        continuation.yield(state)
        continuation.onTermination = { [weak self] _ in Task { await self?.removeObserver(id) } }
        return stream
    }

    public func setContext(selectedLogin: String?, currentPRs: [PullRequestPresentation], repositories: [String]) async {
        await setContext(account: selectedLogin.map { AccountCandidate(login: $0, hostname: "github.com") },
                         activePRs: currentPRs, repositories: repositories)
    }

    public func setContext(account: AccountCandidate?, activePRs: [PullRequestPresentation], repositories: [String]) async {
        let names = Array(Set(repositories.map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() })).sorted()
        guard !hasContext || self.account != account || active != activePRs || self.repositories != names else { return }
        cancel()
        let hadResolvedContext = self.account != nil
        let changedAccount = !hasContext || self.account?.id.lowercased() != account?.id.lowercased()
        hasContext = true
        let removed = Set(self.repositories).subtracting(names)
        self.account = account
        active = account == nil ? [] : activePRs
        for pr in active {
            let id = PRSearchDocument.key(pr)
            if let revision = validated[id],
               (pr.headSHA != nil && pr.headSHA != revision.head) || pr.updatedAt > revision.updated {
                validated.removeValue(forKey: id)
                indexed.remove(id)
                partial.remove(id)
            }
        }
        self.repositories = names
        state.accountLogin = account?.login
        state.repositoryNames = names
        state.phase = account == nil ? .connectionRequired : .idle
        state.message = nil
        do {
            if changedAccount {
                validated.removeAll(); results.removeAll()
                discovered.removeAll(); indexed.removeAll(); partial.removeAll()
                state.progress = PRSearchProgress()
                state.submittedQuery = nil
                // bind removes other accounts on disk, including after app restart.
                if let account {
                    try index.bind(account: account)
                    if let saved = try index.submittedQuery() {
                        state.submittedQuery = saved
                        if state.query.isEmpty { state.query = saved }
                        state.phase = .paused
                        state.message = "Previous search restored. Resume explicitly to validate access and continue."
                    }
                } else if hadResolvedContext {
                    try index.clear()
                }
            } else if let account {
                try index.bind(account: account)
                for repo in removed { try index.remove(repository: repo) }
            }
            let allowed = Set(names).union(active.map { $0.repositoryNameWithOwner.lowercased() })
            results = results.filter { allowed.contains($0.value.pullRequest.repositoryNameWithOwner.lowercased()) }
            if account != nil { try await recompute() }
            else { results.removeAll() }
        } catch is CancellationError { return }
        catch { failStorage(error) }
        publish()
    }

    public func setQuery(_ query: String) async {
        guard query != state.query else { return }
        cancel()
        state.query = query
        state.phase = account == nil ? .connectionRequired : .idle
        state.message = nil
        do { try await recompute() }
        catch is CancellationError { return }
        catch { failStorage(error) }
        publish()
    }

    /// Starts or resumes a submitted query. Context changes and typing never start network work.
    public func search(extended: Bool = true) async {
        cancel()
        self.extended = extended
        guard !PRSearchQuery(state.query).terms.isEmpty else { state.phase = .idle; publish(); return }
        guard let account else { state.phase = .connectionRequired; publish(); return }
        state.submittedQuery = state.query
        state.phase = .validating
        state.message = nil
        state.progress.moreHistory = true
        state.progress.scanStartedAt = now()
        state.progress.scanFinishedAt = nil
        publish()
        let currentGeneration = generation
        let query = state.query
        task = Task { [weak self] in await self?.run(account: account, query: query, generation: currentGeneration) }
    }

    public func pause() async {
        cancel()
        if state.phase == .validating || state.phase == .indexing {
            state.phase = .paused
            state.message = "Search paused. Resume explicitly to continue indexing."
        }
        publish()
    }

    public func clearCache() async {
        cancel()
        validated.removeAll(); results.removeAll()
        discovered.removeAll(); indexed.removeAll(); partial.removeAll()
        state.progress = PRSearchProgress()
        state.submittedQuery = nil
        state.phase = .idle
        state.message = "Search cache cleared. Submit a search to index again."
        do { try index.clear() } catch { failStorage(error) }
        publish()
    }

    private func run(account selected: AccountCandidate, query: String, generation expected: Int) async {
        do {
            let resolution = await connection.inspect(selectedLogin: selected.login)
            try check(expected)
            guard case .connected(let resolved) = resolution,
                  resolved.login.caseInsensitiveCompare(selected.login) == .orderedSame,
                  resolved.hostname.caseInsensitiveCompare(selected.hostname) == .orderedSame else {
                suppressPrivateResults()
                state.phase = .connectionRequired
                state.message = "The selected monitored account could not be verified."
                publish(); return
            }
            try index.bind(account: selected)
            try index.saveSubmittedQuery(query)
            discovered.removeAll(); indexed.removeAll(); partial.removeAll()
            state.phase = .indexing
            publish()
            var processed = Set<String>()
            // Persisted matching snippets are hidden until their PR access and revision are revalidated.
            for saved in try index.matches(query: query) where isAllowed(saved.pullRequest) {
                let detail = try await client.detail(repository: saved.pullRequest.repositoryNameWithOwner, number: saved.pullRequest.number, account: resolved)
                try check(expected)
                if let old = try index.document(id: detail.id), Revision(old) == Revision(detail) {
                    validated[detail.id] = Revision(detail)
                    results[detail.id] = saved
                    discovered.insert(detail.id)
                    publish()
                }
            }
            for pr in active {
                try check(expected)
                try await process(repository: pr.repositoryNameWithOwner, number: pr.number, account: resolved, query: query, generation: expected)
                processed.insert(PRSearchDocument.key(pr))
            }
            if extended {
                for repository in repositories {
                    try check(expected)
                    guard PRSearchRESTClient.validRepository(repository) else { throw PRSearchError.invalidRepository }
                    var checkpoint = try index.checkpoint(repository: repository, query: query)
                        ?? PRSearchCheckpoint(startedAt: now())
                    if checkpoint.complete { checkpoint = PRSearchCheckpoint(startedAt: now()) }
                    state.progress.scanStartedAt = min(state.progress.scanStartedAt ?? checkpoint.startedAt, checkpoint.startedAt)
                    // An interrupted creation-order scan still needs edits behind its checkpoint.
                    if checkpoint.page > 1 || checkpoint.offset > 0 {
                        // Coverage survives independently of retained query matches and evicted diffs.
                        for (id, coverage) in try index.coverage(repository: repository) {
                            discovered.insert(id)
                            indexed.insert(id)
                            if !coverage.fileListComplete || !coverage.codeComplete { partial.insert(id) }
                        }
                        var freshnessPage = 1
                        var moreUpdates = true
                        while moreUpdates {
                            let (updates, more) = try await client.list(repository: repository, page: freshnessPage, account: resolved, updated: true)
                            try check(expected)
                            for document in updates where document.pullRequest.updatedAt >= checkpoint.startedAt {
                                discovered.insert(document.id)
                                if !processed.contains(document.id) {
                                    try await process(repository: repository, number: document.pullRequest.number, account: resolved, query: query, generation: expected)
                                    processed.insert(document.id)
                                }
                            }
                            moreUpdates = more && !updates.contains { $0.pullRequest.updatedAt < checkpoint.startedAt }
                            freshnessPage += 1
                        }
                    }
                    while !checkpoint.complete {
                        let (documents, more) = try await client.list(repository: repository, page: checkpoint.page, account: resolved)
                        try check(expected)
                        for document in documents { discovered.insert(document.id) }
                        publish()
                        for (offset, document) in documents.enumerated() where offset >= checkpoint.offset {
                            try check(expected)
                            if !processed.contains(document.id) {
                                try await process(repository: repository, number: document.pullRequest.number, account: resolved, query: query, generation: expected)
                                processed.insert(document.id)
                            }
                            try check(expected)
                            checkpoint.offset = offset + 1
                            try index.saveCheckpoint(checkpoint, repository: repository, query: query)
                        }
                        checkpoint.page += 1; checkpoint.offset = 0; checkpoint.complete = !more
                        try index.saveCheckpoint(checkpoint, repository: repository, query: query)
                    }
                }
            }
            try check(expected)
            state.progress.moreHistory = false
            state.progress.lastRefresh = now()
            state.progress.scanFinishedAt = now()
            state.progress.hasEvictedHistory = try index.hasEvictedHistory()
            state.phase = .complete
            state.message = partial.isEmpty
                ? "Scan finished for the selected repositories. Results reflect observations during this scan."
                : "Scan finished with partial code coverage for \(partial.count) pull requests."
            if state.progress.hasEvictedHistory { state.message! += " A new query may need to rescan evicted history." }
            publish()
        } catch is CancellationError {
            // The operation that invalidated this generation publishes its replacement state.
        } catch {
            guard expected == generation else { return }
            if case PRSearchError.rateLimited(let until) = error {
                state.phase = .rateLimited
                state.message = until.map { "GitHub quota reserved for workload refresh. Resume after \($0.formatted())." }
                    ?? "GitHub rate limit reached. Wait before explicitly resuming."
            } else if case PRSearchError.accessDenied = error {
                suppressPrivateResults()
                state.phase = .connectionRequired
                state.message = "Repository access could not be verified. Private search results are hidden."
            } else if error is PRSearchIndexError {
                failStorage(error)
            } else {
                suppressPrivateResults()
                state.phase = .failed
                state.message = "Search could not reach or validate GitHub. Private cached results are hidden; coverage remains incomplete."
            }
            state.progress.moreHistory = true
            publish()
        }
    }

    private func process(repository: String, number: Int, account: ResolvedAccount, query: String, generation expected: Int) async throws {
        let detail = try await client.detail(repository: repository, number: number, account: account)
        try check(expected)
        discovered.insert(detail.id)
        var document: PRSearchDocument
        if let cached = try index.document(id: detail.id), Revision(cached) == Revision(detail), cached.files != nil {
            document = detail
            document.files = cached.files
            document.coverage = cached.coverage
        } else {
            do { document = try await client.hydrate(detail, account: account) }
            catch PRSearchError.revisionChanged {
                try check(expected)
                document = detail
                document.coverage = PRSearchCoverage(reasons: ["PR revision changed during retrieval. Retry to search its code."])
            } catch PRSearchError.responseTooLarge {
                try check(expected)
                document = detail
                document.coverage = PRSearchCoverage(reasons: ["Local response size limit reached. Code coverage is partial."])
            }
        }
        try check(expected)
        // No suspension between this guard, the writes, and publication.
        try index.save(document)
        validated[document.id] = Revision(document)
        indexed.insert(document.id)
        if document.coverage.codeComplete && document.coverage.fileListComplete { partial.remove(document.id) }
        else { partial.insert(document.id) }
        if let match = PRSearchMatcher.match(document, query: PRSearchQuery(query)) {
            results[document.id] = match
            try index.retain(match, query: query)
        } else { results.removeValue(forKey: document.id) }
        state.progress.lastRefresh = now()
        publish()
    }

    private func recompute() async throws {
        results.removeAll()
        guard account != nil else { return }
        let query = PRSearchQuery(state.query)
        guard !query.terms.isEmpty else { return }
        // Current workload titles are already account-bound; historical content is not trusted offline.
        for pr in active {
            let document = PRSearchDocument(pullRequest: pr, body: "", baseSHA: "", headSHA: pr.headSHA ?? "",
                changedFiles: -1, files: nil, coverage: PRSearchCoverage(reasons: ["Description and changed code have not been validated for this search."]), refreshedAt: now())
            if let match = PRSearchMatcher.match(document, query: query) { results[match.id] = match }
        }
        guard !validated.isEmpty else { return }
        let expected = generation
        // One bounded PR at a time, with cooperative cancellation between batches.
        for (offset, id) in validated.keys.sorted().enumerated() {
            if offset.isMultiple(of: 8) { await Task.yield(); try check(expected) }
            guard let document = try index.document(id: id), isAllowed(document.pullRequest),
                  validated[id] == Revision(document) else { continue }
            if let match = PRSearchMatcher.match(document, query: query) { results[id] = match }
        }
        for saved in try index.matches(query: state.query) where isAllowed(saved.pullRequest) && validated[saved.id] != nil {
            results[saved.id] = saved
        }
    }

    private func isAllowed(_ pr: PullRequestPresentation) -> Bool {
        active.contains { PRSearchDocument.key($0) == PRSearchDocument.key(pr) }
            || (extended && repositories.contains(pr.repositoryNameWithOwner.lowercased()))
    }

    private func suppressPrivateResults() { validated.removeAll(); results.removeAll() }

    private func failStorage(_ error: any Error) {
        state.phase = .paused
        state.message = (error as? PRSearchIndexError) == .lowDiskSpace
            ? "Low disk space. Search paused; current results are retained."
            : "Search storage is unavailable. Search paused; current results are retained."
    }

    private func cancel() { generation += 1; task?.cancel(); task = nil }
    private func check(_ expected: Int) throws {
        try Task.checkCancellation()
        guard expected == generation else { throw CancellationError() }
    }
    private func removeObserver(_ id: UUID) { observers.removeValue(forKey: id) }

    private func publish() {
        let activeIDs = Set(active.map(PRSearchDocument.key))
        state.inYourList = results.values.filter { activeIDs.contains($0.id) }.sorted(by: PRSearchMatcher.precedes)
        state.extendedResults = extended ? results.values.filter {
            !activeIDs.contains($0.id) && repositories.contains($0.pullRequest.repositoryNameWithOwner.lowercased())
        }.sorted(by: PRSearchMatcher.precedes) : []
        state.progress.discovered = discovered.count
        state.progress.indexed = indexed.count
        state.progress.partial = partial.count
        for observer in observers.values { observer.yield(state) }
    }
}
