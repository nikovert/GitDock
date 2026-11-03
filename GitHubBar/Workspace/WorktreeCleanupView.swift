import SwiftUI
import GitHubBarCore

struct WorktreeCleanupView: View {
    @Bindable var model: WorktreeCleanupModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Clean up merged worktrees").workspaceFont(.title2.bold())
            Text("Only verified merged PRs with clean worktrees matching origin are eligible. Local branches, board notes, and review history are kept.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let error = model.errorMessage {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.primary).padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(nsColor: .controlBackgroundColor))
                    .overlay(alignment: .leading) { Rectangle().fill(.orange).frame(width: 3) }
                    .textSelection(.enabled)
            }

            switch model.phase {
            case .idle:
                Text("Scan local session links and verify current PR status on GitHub.")
            case .scanning:
                ProgressView("Checking GitHub, origin, local changes, and attached sessions…")
            case .choice:
                Text("\(model.eligible.count) eligible · \(model.candidates.count - model.eligible.count) skipped")
                    .workspaceFont(.headline)
                Text("Stopping closes the attached agent sessions and may interrupt work in them. Choose all eligible worktrees, or review the list and select individual ones.")
                    .fixedSize(horizontal: false, vertical: true)
                candidateList(selectable: false)
            case .reviewing:
                Text("Choose worktrees to stop and close. Nothing is selected automatically.")
                candidateList(selectable: true)
            case .running:
                ProgressView("Rechecking approved worktrees, stopping selected sessions, and removing eligible directories…")
                Text("Changed or unsafe worktrees will be retained.").foregroundStyle(.secondary)
            case .results:
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(model.results) { result in
                            VStack(alignment: .leading, spacing: 4) {
                                Label(result.outcome.rawValue.capitalized, systemImage: result.outcome == .removed ? "checkmark.circle" : "exclamationmark.circle")
                                    .workspaceFont(.headline)
                                if let candidate = model.candidates.first(where: { $0.path == result.path }) {
                                    pullRequestDetails(candidate)
                                }
                                Text(result.path).workspaceFont(.caption).textSelection(.enabled)
                                Text(result.message).foregroundStyle(.secondary).textSelection(.enabled)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            Divider()
                        }
                    }
                }
            }
            Spacer(minLength: 0)
            Divider()
            HStack {
                if model.phase == .running {
                    Button("Stop cleanup") { model.stopAfterCurrent() }
                } else {
                    Button(model.phase == .results ? "Done" : "Cancel") { model.cancel(); dismiss() }
                        .keyboardShortcut(.cancelAction)
                }
                Spacer()
                switch model.phase {
                case .idle, .results:
                    Button("Scan again") { model.scan() }.keyboardShortcut(.defaultAction)
                case .choice:
                    Button("Review individually") { model.reviewIndividually() }
                    Button("Stop and close all eligible worktrees", role: .destructive) { model.confirmAll() }
                        .disabled(model.eligible.isEmpty)
                case .reviewing:
                    Button("Stop and close selected (\(model.selected.count))", role: .destructive) { model.confirmSelected() }
                        .disabled(model.selected.isEmpty)
                case .scanning, .running: EmptyView()
                }
            }
        }
        .padding(24)
        .frame(width: 760, height: 580)
        .background(Color(nsColor: .windowBackgroundColor))
        .interactiveDismissDisabled(model.isBusy)
        .onDisappear { model.cancel() }
    }

    private func candidateList(selectable: Bool) -> some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 12) {
                ForEach(model.candidates) { row in
                    HStack(alignment: .top, spacing: 12) {
                        if selectable {
                            Toggle("Select \(row.title)", isOn: Binding(
                                get: { model.selected.contains(row.id) },
                                set: { model.select(row.id, enabled: $0) }))
                                .labelsHidden().toggleStyle(.checkbox).disabled(!row.isEligible)
                        }
                        VStack(alignment: .leading, spacing: 4) {
                            pullRequestDetails(row)
                            Text(row.path).workspaceFont(.caption).textSelection(.enabled)
                            ForEach(row.sessions) { session in
                                let live = session.tmuxSessionName.flatMap { row.liveSessions[$0] } != nil
                                let activity = live ? "Running" : (row.isEligible ? "Not running" : "Activity not verified")
                                Text("\(session.agent.rawValue.capitalized) · \(activity) · \(session.tmuxSessionName ?? "No managed terminal")")
                                    .workspaceFont(.caption).foregroundStyle(.secondary)
                            }
                            Label(row.skipReason ?? "Merged, clean, and synced with origin", systemImage: row.isEligible ? "checkmark.shield" : "lock")
                                .workspaceFont(.caption).foregroundStyle(row.isEligible ? Color.green : Color.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    Divider()
                }
                if model.candidates.isEmpty {
                    Text("No linked worktrees to clean up.").foregroundStyle(.secondary)
                }
            }
        }
    }

    private func pullRequestDetails(_ candidate: WorktreeCleanupCandidate) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(candidate.pullRequests) { pr in
                VStack(alignment: .leading, spacing: 3) {
                    Text(pr.title).workspaceFont(.headline).fixedSize(horizontal: false, vertical: true)
                    Link(pr.key.description, destination: pr.key.url).workspaceFont(.caption)
                    Text(pr.description.isEmpty ? "No PR description provided." : pr.description)
                        .workspaceFont(.subheadline).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
            }
            ForEach(Array(Set(candidate.sessions.map { $0.subject.key }))
                .filter { key in !candidate.pullRequests.contains(where: { $0.key == key }) }
                .sorted { $0.description < $1.description }, id: \.self) { key in
                VStack(alignment: .leading, spacing: 3) {
                    Link(key.description, destination: key.url).workspaceFont(.headline)
                    Text("PR title and description unavailable.")
                        .workspaceFont(.subheadline).foregroundStyle(.secondary)
                }
            }
        }
    }
}
