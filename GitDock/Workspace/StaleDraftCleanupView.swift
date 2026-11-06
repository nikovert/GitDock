import SwiftUI
import GitDockCore

struct StaleDraftCleanupView: View {
    @Bindable var model: StaleDraftCleanupModel
    let accountLogin: String?
    let workload: [PullRequestPresentation]
    let onClosed: () async -> Void
    let onManualCleanup: () -> Void
    @Environment(\.dismiss) private var dismiss
    @AppStorage("staleDraftInactiveDays") private var inactiveDays = 30
    @State private var confirmationVisible = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Close old drafts on GitHub").workspaceFont(.title2.bold())
            Text("Review your open drafts in the current repository scope. Inactivity uses GitHub’s last updated date, including automation.")
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Text("Inactive for at least")
                TextField("Days", value: $inactiveDays, format: .number)
                    .frame(width: 70).textFieldStyle(.roundedBorder)
                    .accessibilityLabel("Inactive days")
                Text("days")
                Spacer()
            }
            .disabled(model.isBusy)
            if let message = model.errorMessage {
                Label(message, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange).textSelection(.enabled)
            }
            switch model.phase {
            case .idle:
                Text("Scan to check current GitHub activity and close permissions. Nothing is selected automatically.")
                    .foregroundStyle(.secondary)
            case .scanning:
                ProgressView("Checking your scoped drafts on GitHub…")
            case .reviewing:
                Text("Choose drafts to close. Remote branches and all local data will be kept.")
                candidateList
            case .running:
                ProgressView("Rechecking and closing selected drafts… \(model.results.count) of \(model.confirmationCount)")
                if let id = model.currentID { Text(id).foregroundStyle(.secondary) }
                resultList
            case .results:
                resultList
                if model.hasConfirmedCloses {
                    Text("Closed drafts may still have local worktrees. Review them separately for manual cleanup.")
                        .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    Button("Review local worktrees…") {
                        dismiss()
                        onManualCleanup()
                    }
                }
            }
            Spacer(minLength: 0)
            Divider()
            HStack {
                if model.phase == .running {
                    Button("Stop closing") { model.stopAfterCurrent() }
                } else {
                    Button(model.phase == .results ? "Done" : "Cancel") { model.cancel(); dismiss() }
                        .keyboardShortcut(.cancelAction)
                }
                Spacer()
                if model.phase == .idle || model.phase == .reviewing || model.phase == .results {
                    Button(model.phase == .idle ? "Scan drafts" : "Scan again") { model.scan() }
                        .disabled(inactiveDays <= 0)
                }
                if model.phase == .reviewing {
                    Button("Close selected on GitHub (\(model.selected.count))…", role: .destructive) {
                        model.requestConfirmation()
                        confirmationVisible = model.confirmationRequested
                    }
                        .disabled(model.selected.isEmpty)
                }
            }
        }
        .padding(24)
        .frame(minWidth: 660, idealWidth: 760, minHeight: 500, idealHeight: 580)
        .background(Color(nsColor: .windowBackgroundColor))
        .interactiveDismissDisabled(model.isBusy)
        .alert("Close \(model.confirmationCount) selected drafts on GitHub?", isPresented: $confirmationVisible) {
                Button("Cancel", role: .cancel) { model.dismissConfirmation() }
                Button("Close drafts on GitHub", role: .destructive) { model.confirmSelected() }
        } message: {
            Text("Each PR is rechecked before closing. Changed drafts will be retained. Remote branches, local worktrees, notes and review history will be kept.")
        }
        .onAppear {
            model.onClosed = onClosed
            model.updateContext(accountLogin: accountLogin, workload: workload)
            model.setInactiveDays(inactiveDays)
        }
        .onChange(of: accountLogin) { _, _ in model.updateContext(accountLogin: accountLogin, workload: workload) }
        .onChange(of: workload) { _, _ in model.updateContext(accountLogin: accountLogin, workload: workload) }
        .onChange(of: inactiveDays) { _, days in model.setInactiveDays(days) }
        .onChange(of: model.confirmationRequested) { _, requested in confirmationVisible = requested }
        .onDisappear { model.cancel() }
    }

    private var candidateList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 12) {
                ForEach(model.candidates) { candidate in
                    HStack(alignment: .top, spacing: 12) {
                        Toggle("Select \(candidate.title)", isOn: Binding(
                            get: { model.selected.contains(candidate.id) },
                            set: { model.select(candidate.id, enabled: $0) }))
                            .labelsHidden().toggleStyle(.checkbox).disabled(!candidate.isEligible)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(candidate.title).workspaceFont(.headline).fixedSize(horizontal: false, vertical: true)
                            Link(candidate.key.description, destination: candidate.key.url)
                            Text("Last updated \(candidate.updatedAt.formatted(date: .abbreviated, time: .shortened))")
                                .workspaceFont(.caption).foregroundStyle(.secondary)
                            if !candidate.isEligible {
                                Label("GitHub does not allow this account to close this draft.", systemImage: "lock")
                                    .workspaceFont(.caption).foregroundStyle(.secondary)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    Divider()
                }
                if model.candidates.isEmpty {
                    Text("No drafts meet this inactivity threshold in the current repository scope.")
                        .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private var resultList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 12) {
                ForEach(model.results) { result in
                    VStack(alignment: .leading, spacing: 4) {
                        Label(result.outcome == .unconfirmed ? "Close unconfirmed" : result.outcome.rawValue.capitalized,
                              systemImage: result.outcome == .closed ? "checkmark.circle" : "exclamationmark.circle")
                            .workspaceFont(.headline)
                        Text(result.candidate.title).fixedSize(horizontal: false, vertical: true)
                        Link(result.candidate.key.description, destination: result.candidate.key.url)
                        Text(result.message).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                    }
                    Divider()
                }
            }
        }
    }
}
