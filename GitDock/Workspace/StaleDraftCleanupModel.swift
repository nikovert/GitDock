import Foundation
import GitDockCore
import Observation

@MainActor
@Observable
final class StaleDraftCleanupModel {
    enum Phase { case idle, scanning, reviewing, running, results }
    private(set) var phase: Phase = .idle
    private(set) var candidates: [StaleDraftCleanupCandidate] = []
    private(set) var results: [StaleDraftCleanupResult] = []
    private(set) var selected: Set<String> = []
    private(set) var confirmationRequested = false
    private(set) var inactiveDays = 30
    private(set) var currentID: String?
    private(set) var errorMessage: String?
    @ObservationIgnored private(set) var pendingTask: Task<Void, Never>?
    @ObservationIgnored var onClosed: (() async -> Void)?
    @ObservationIgnored private let service: any StaleDraftCleanupServicing
    @ObservationIgnored private var revision = 0
    private var accountLogin: String?
    private var workload: [PullRequestPresentation] = []

    var isBusy: Bool { phase == .scanning || phase == .running }
    var hasConfirmedCloses: Bool { results.contains { $0.outcome == .closed } }
    var confirmationCount: Int { selected.count }

    init(service: any StaleDraftCleanupServicing = StaleDraftCleanupService()) { self.service = service }

    func updateContext(accountLogin: String?, workload: [PullRequestPresentation]) {
        if self.accountLogin != accountLogin {
            cancel()
        } else if self.workload != workload, phase != .results {
            // Changing scope or refreshing PR evidence invalidates a selected preview before another write.
            cancel()
        }
        self.accountLogin = accountLogin
        self.workload = workload
    }

    func setInactiveDays(_ days: Int) {
        guard inactiveDays != days else { return }
        cancel()
        inactiveDays = days
        if days <= 0 { errorMessage = StaleDraftCleanupError.invalidThreshold.localizedDescription }
    }

    func scan() {
        guard !isBusy else { return }
        guard inactiveDays > 0 else {
            errorMessage = StaleDraftCleanupError.invalidThreshold.localizedDescription
            return
        }
        guard let accountLogin, !accountLogin.isEmpty else {
            errorMessage = "Connect a monitored GitHub account before scanning drafts."
            return
        }
        revision += 1
        let version = revision
        let workload = workload
        let days = inactiveDays
        candidates = []; results = []; selected = []; errorMessage = nil
        confirmationRequested = false
        phase = .scanning
        pendingTask = Task { [weak self, service] in
            do {
                let rows = try await service.preview(workload: workload, accountLogin: accountLogin, inactiveDays: days)
                guard let self, version == revision, !Task.isCancelled else { return }
                candidates = rows
                phase = .reviewing
            } catch {
                guard let self, version == revision else { return }
                errorMessage = (error as? StaleDraftCleanupError)?.localizedDescription ??
                    "Could not check drafts on GitHub. Refresh and try scanning again."
                phase = .idle
            }
        }
    }

    func select(_ id: String, enabled: Bool) {
        guard phase == .reviewing, candidates.contains(where: { $0.id == id && $0.isEligible }) else { return }
        confirmationRequested = false
        if enabled { selected.insert(id) } else { selected.remove(id) }
    }

    func requestConfirmation() {
        guard phase == .reviewing, !selected.isEmpty else { return }
        confirmationRequested = true
    }

    func dismissConfirmation() { confirmationRequested = false }

    func confirmSelected() {
        guard phase == .reviewing, confirmationRequested, let accountLogin else { return }
        let approved = candidates.filter { selected.contains($0.id) && $0.isEligible }
        confirmationRequested = false
        guard !approved.isEmpty else { return }
        let version = revision
        let completion = onClosed
        phase = .running
        results = []
        pendingTask = Task { [weak self, service] in
            guard let self else { return }
            var didClose = false
            for candidate in approved {
                guard version == revision, !Task.isCancelled else { break }
                currentID = candidate.id
                let result = await service.close(candidate, accountLogin: accountLogin)
                didClose = didClose || result.outcome == .closed
                guard version == revision else { break }
                results.append(result)
            }
            if version == revision {
                if Task.isCancelled {
                    let completed = Set(results.map(\.id))
                    results += approved.filter { !completed.contains($0.id) }.map {
                        .init(candidate: $0, outcome: .retained, message: "Stopped before this draft was sent to GitHub.")
                    }
                }
                currentID = nil
                selected = []
                phase = .results
            }
            // Even if account/scope changed during a dispatched write, confirmed closes require a fresh workload.
            if didClose { await completion?() }
        }
    }

    func stopAfterCurrent() { pendingTask?.cancel() }

    func cancel() {
        revision += 1
        pendingTask?.cancel()
        candidates = []; results = []; selected = []; currentID = nil
        confirmationRequested = false
        errorMessage = nil
        phase = .idle
    }
}
