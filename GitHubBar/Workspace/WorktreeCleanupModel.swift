import Foundation
import GitHubBarCore
import Observation

@MainActor
@Observable
final class WorktreeCleanupModel {
    var automaticEnabled: Bool {
        didSet {
            defaults?.set(automaticEnabled, forKey: "githubbar.cleanup.automatic")
            if !automaticEnabled, isAutomaticRun { cancel() }
        }
    }
    private(set) var isAutomaticRun = false
    private(set) var activity: [CleanupActivityRun] = []
    private(set) var automaticStatus: String?
    private var manualReviewActive = false
    private var lastAutomaticRefresh: Date?
    private var deferredAutomaticRefresh: Date?
    @ObservationIgnored private let defaults: UserDefaults?
    enum Phase { case idle, scanning, choice, reviewing, running, results }
    private(set) var phase: Phase = .idle
    private(set) var candidates: [WorktreeCleanupCandidate] = []
    private(set) var results: [WorktreeCleanupResult] = []
    private(set) var selected: Set<String> = []
    private(set) var errorMessage: String?
    @ObservationIgnored private(set) var pendingTask: Task<Void, Never>?
    @ObservationIgnored var onCompletion: (() async -> Void)?
    @ObservationIgnored private let service: any WorktreeCleanupServicing
    @ObservationIgnored private var revision = 0
    private var accountLogin: String?
    private var configuration: WorkspaceConfiguration?
    var isBusy: Bool { phase == .scanning || phase == .running }
    var eligible: [WorktreeCleanupCandidate] { candidates.filter(\.isEligible) }
    init(service: any WorktreeCleanupServicing, defaults: UserDefaults? = nil) {
        self.service = service
        self.defaults = defaults
        automaticEnabled = defaults?.object(forKey: "githubbar.cleanup.automatic") as? Bool ?? true
    }

    func updateAccount(_ login: String?) {
        let login = login?.lowercased()
        guard accountLogin != login else { return }
        cancel()
        accountLogin = login
        lastAutomaticRefresh = nil; deferredAutomaticRefresh = nil
        automaticStatus = nil
        activity = activityKey.flatMap { defaults?.data(forKey: $0) }
            .flatMap { try? JSONDecoder().decode([CleanupActivityRun].self, from: $0) } ?? []
    }

    func updateConfiguration(_ configuration: WorkspaceConfiguration) {
        guard self.configuration != configuration else { return }
        if self.configuration != nil { cancel() }
        self.configuration = configuration
    }

    func scan() {
        manualReviewActive = true
        guard !isBusy else { return }
        guard let accountLogin, !accountLogin.isEmpty else {
            errorMessage = "Connect a monitored GitHub account before scanning."
            return
        }
        revision += 1
        let version = revision
        candidates = []; results = []; selected = []; errorMessage = nil
        phase = .scanning
        pendingTask = Task { [weak self, service] in
            do {
                let rows = try await service.preview(accountLogin: accountLogin)
                guard let self, version == revision, !Task.isCancelled else { return }
                candidates = rows
                phase = .choice
            } catch {
                guard let self, version == revision else { return }
                errorMessage = error.localizedDescription
                phase = .idle
            }
        }
    }

    /// Successful refreshes are distinct from restored cache and failed refreshes.
    func automaticRefreshCompleted(at date: Date) {
        guard automaticEnabled, let accountLogin, configuration != nil,
              lastAutomaticRefresh == nil || date > lastAutomaticRefresh! else { return }
        guard !manualReviewActive, !isBusy else {
            if deferredAutomaticRefresh == nil || date > deferredAutomaticRefresh! { deferredAutomaticRefresh = date }
            return
        }
        lastAutomaticRefresh = date
        revision += 1
        let version = revision
        isAutomaticRun = true
        phase = .scanning
        automaticStatus = "Checking merged worktrees…"
        errorMessage = nil
        pendingTask = Task { [weak self, service] in
            defer {
                if let self, version == revision, isAutomaticRun, Task.isCancelled {
                    isAutomaticRun = false; phase = .results
                    automaticStatus = "Cleanup stopped; remaining worktrees retained."
                }
            }
            do {
                let rows = try await service.preview(accountLogin: accountLogin)
                guard let self, version == revision, !Task.isCancelled else { return }
                candidates = rows
                if manualReviewActive {
                    isAutomaticRun = false; phase = .choice
                    return
                }
                let safe = rows.filter(\.isAutomaticallyEligible)
                var outcomes = rows.filter { !$0.isAutomaticallyEligible }.map {
                    WorktreeCleanupResult(path: $0.path, outcome: .skipped, message: automaticReason($0))
                }
                var recorded = false
                if !safe.isEmpty {
                    phase = .running
                    let removed = await service.execute(safe, accountLogin: accountLogin, intent: .automatic)
                    outcomes += removed
                    if Task.isCancelled {
                        let reported = Set(outcomes.map(\.path))
                        outcomes += safe.filter { !reported.contains($0.path) }.map {
                            WorktreeCleanupResult(path: $0.path, outcome: .skipped, message: "Cleanup stopped; worktree retained.")
                        }
                    }
                    record(outcomes, automatic: true, candidates: rows, account: accountLogin)
                    recorded = true
                    await onCompletion?()
                    guard version == revision else { return }
                }
                results = outcomes
                selected = []
                phase = .results
                isAutomaticRun = false
                if !recorded, !outcomes.isEmpty { record(outcomes, automatic: true, candidates: rows, account: accountLogin) }
                automaticStatus = Task.isCancelled ? "Cleanup stopped; completed removals are listed below." : outcomes.isEmpty ? "No worktrees found for cleanup." : "Automatic cleanup: \(outcomes.filter { $0.outcome == .removed }.count) removed · \(outcomes.filter { $0.outcome != .removed }.count) need review"
                if !Task.isCancelled { resumeDeferredRefresh() }
            } catch {
                guard let self, version == revision, !Task.isCancelled else { return }
                isAutomaticRun = false; phase = .idle
                errorMessage = error.localizedDescription
                automaticStatus = "Automatic cleanup paused: \(error.localizedDescription)"
            }
        }
    }

    func endManualReview() {
        cancel()
        manualReviewActive = false
        resumeDeferredRefresh()
    }

    private func resumeDeferredRefresh() {
        guard let date = deferredAutomaticRefresh else { return }
        deferredAutomaticRefresh = nil
        automaticRefreshCompleted(at: date)
    }

    private func automaticReason(_ candidate: WorktreeCleanupCandidate) -> String {
        if let reason = candidate.skipReason ?? candidate.automaticSkipReason { return reason }
        if candidate.provenance == .external { return "Other worktree: explicit manual approval required." }
        if !candidate.liveSessions.isEmpty { return "Live session: agent activity is unknown; manual approval required." }
        return "Automatic cleanup eligibility could not be verified. Review manually."
    }

    func reviewIndividually() {
        guard phase == .choice else { return }
        selected = []
        phase = .reviewing
    }

    func select(_ id: String, enabled: Bool) {
        guard phase == .reviewing, eligible.contains(where: { $0.id == id }) else { return }
        if enabled { selected.insert(id) } else { selected.remove(id) }
    }

    func confirmAll() {
        guard phase == .choice else { return }
        execute(eligible)
    }

    func confirmSelected() {
        guard phase == .reviewing else { return }
        execute(eligible.filter { selected.contains($0.id) })
    }

    private func execute(_ approved: [WorktreeCleanupCandidate]) {
        guard !isBusy, !approved.isEmpty, let accountLogin else { return }
        let version = revision
        phase = .running
        pendingTask = Task { [weak self, service] in
            let outcomes = await service.execute(approved, accountLogin: accountLogin, intent: .manual)
            guard let self else { return }
            record(outcomes, automatic: false, candidates: approved, account: accountLogin)
            await onCompletion?()
            guard version == revision else { return }
            results = outcomes
            if Task.isCancelled {
                errorMessage = "Cleanup stopped. Completed removals are not undone; remaining worktrees are retained."
            }
            selected = []
            phase = .results
        }
    }

    func cancel() {
        revision += 1
        pendingTask?.cancel()
        candidates = []; selected = []; results = []
        phase = .idle
        isAutomaticRun = false
        errorMessage = nil
    }

    func stopAfterCurrent() { pendingTask?.cancel() }

    private var activityKey: String? { accountLogin.map { "githubbar.cleanup.activity." + $0 } }

    private func record(_ outcomes: [WorktreeCleanupResult], automatic: Bool, candidates: [WorktreeCleanupCandidate], account: String) {
        let account = account.lowercased()
        let key = "githubbar.cleanup.activity." + account
        let entries = outcomes.prefix(200).map { result in
            CleanupActivityRun.Entry(path: result.path,
                title: candidates.first { $0.path == result.path }?.title ?? result.path,
                outcome: result.outcome.rawValue, message: result.message)
        }
        var history = accountLogin == account ? activity : defaults?.data(forKey: key)
            .flatMap { try? JSONDecoder().decode([CleanupActivityRun].self, from: $0) } ?? []
        history.insert(CleanupActivityRun(id: UUID(), completedAt: .now, automatic: automatic, entries: entries,
            totalCount: outcomes.count, removedCount: outcomes.filter { $0.outcome == .removed }.count), at: 0)
        history = Array(history.prefix(20))
        if let data = try? JSONEncoder().encode(history) { defaults?.set(data, forKey: key) }
        if accountLogin == account { activity = history }
    }
}
