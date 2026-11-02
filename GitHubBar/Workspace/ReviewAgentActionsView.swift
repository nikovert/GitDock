import GitHubBarCore
import SwiftUI

struct ReviewAgentActionsView: View {
    @Bindable var review: ReviewWorkspaceModel
    @Bindable var workspace: WorkspaceModel
    var allowsActions = true
    @AppStorage("githubbar.chat.configuration") private var configurationData = Data()
    @State private var showsSettings = false
    @State private var fixTarget: AgentFixTarget?
    private var configuration: ReviewChatConfiguration {
        (try? JSONDecoder().decode(ReviewChatConfiguration.self, from: configurationData)) ?? ReviewChatConfiguration()
    }
    private var configured: Bool { (try? configuration.validated()) != nil }
    private var supportsWorktree: Bool { configuration.provider == .codex || configuration.provider == .claude }
    private var hasCheckout: Bool {
        guard let repository = review.snapshot?.key.repositoryNameWithOwner else { return false }
        return workspace.document.configuration.repositoryCheckouts[repository]?.isEmpty == false
    }
    private var canReview: Bool { allowsActions && configured && supportsWorktree && hasCheckout && review.identity != nil && !review.loading && !review.reviewing && !review.sinceLastReview && review.local.canSave }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 10) { reviewButton; fixesButton; Spacer(minLength: 0) }
                VStack(alignment: .leading, spacing: 8) { reviewButton; fixesButton }
            }
            if review.reviewing {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(review.agentReviewMessage ?? "Agent reviewing…").font(.caption)
                    Button("Cancel review") { review.cancelAgentReview() }.controlSize(.small)
                }
            } else if let message = review.agentReviewMessage {
                Text(message).font(.caption).foregroundStyle(.secondary)
            }
            if let error = review.agentReviewErrorMessage {
                Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled)
            }
            if let path = review.agentReviewWorktreePath, review.reviewing {
                Label("Inspecting a separate read-only worktree", systemImage: "folder.badge.gearshape")
                    .font(.caption).foregroundStyle(.secondary).help(path)
            }
            if let warning = review.agentReviewCleanupMessage {
                Text(warning).font(.caption).foregroundStyle(.orange).textSelection(.enabled)
            }
            if !configured { Button("Configure review agent…") { showsSettings = true }.font(.caption) }
            else if !supportsWorktree {
                Button("Choose Codex or Claude for worktree reviews…") { showsSettings = true }.font(.caption)
            }
            if !hasCheckout, !review.reviewing {
                Button("Configure a repository checkout for worktree reviews…") { review.tab = .workspace }.font(.caption)
            }
        }
        .sheet(isPresented: $showsSettings) { ReviewChatSettingsView() }
        .sheet(item: $fixTarget) { target in
            AgentFixLaunchView(review: review, workspace: workspace, target: target,
                preferredAgent: configuration.provider == .claude ? .claude : .codex)
        }
    }

    private var reviewButton: some View {
        Button { review.runAgentReview(configuration: configuration) } label: {
            Label("Agent review", systemImage: "wand.and.stars")
        }.disabled(!canReview)
            .help("Prepare a fresh worktree at this PR's head and inspect all changed files with the selected provider. Findings stay local; coverage is reported explicitly.")
    }
    private var fixesButton: some View {
        Button {
            do {
                if let identity = review.identity { fixTarget = AgentFixTarget(identity: identity, request: try review.makeFixRequest()) }
            } catch { review.errorMessage = error.localizedDescription }
        } label: {
            Label("Have an agent make all fixes…", systemImage: "wrench.and.screwdriver")
        }.disabled(!allowsActions || review.identity == nil || review.loading || review.sinceLastReview || review.reviewing)
            .help("Review all published comments and local drafts, apply justified fixes, test, and commit in a new local worktree.")
    }
}

struct AgentFixTarget: Identifiable {
    let identity: ReviewIdentity
    let request: AgentFixRequest
    var id: String { identity.revisionKey }
}

struct AgentFixLaunchView: View {
    @Bindable var review: ReviewWorkspaceModel
    @Bindable var workspace: WorkspaceModel
    let target: AgentFixTarget
    let preferredAgent: AgentKind
    @State private var instructions = AgentFixRequest.defaultInstructions
    @State private var agent: AgentKind = .codex
    @State private var launching = false
    @State private var session: AgentSessionLink?
    @State private var error: String?
    @State private var launchTask: Task<Void, Never>?
    @Environment(\.dismiss) private var dismiss
    private var valid: Bool { review.identity == target.identity && workspace.monitoredAccountLogin?.lowercased() == target.identity.account.lowercased() }
    private var checkoutConfigured: Bool { workspace.document.configuration.repositoryCheckouts[target.request.key.repositoryNameWithOwner]?.isEmpty == false }
    private var command: String { agent == .codex ? workspace.document.configuration.codexCommand : workspace.document.configuration.claudeCommand }
    private var executableFound: Bool { AgentSessionManager.findExecutable(command) != nil }
    private var canStart: Bool { valid && checkoutConfigured && executableFound && !launching && session == nil && !instructions.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && instructions.utf8.count <= AgentFixRequest.maximumInstructionBytes }
    private var preview: String {
        var request = target.request
        request.instructions = instructions
        return String(request.defaultPrompt.prefix(24_000))
    }

    var body: some View {
        ScrollView {
        VStack(alignment: .leading, spacing: 16) {
            Text("Have an agent make all fixes").font(.title2.bold())
            Text(target.request.title).font(.headline)
            Text("\(target.request.key.description) · @\(target.identity.account) · Head \(target.identity.headSHA.prefix(8))")
                .font(.caption.monospaced()).foregroundStyle(.secondary)
            Text("Start a coding-agent session in a fresh PR worktree. It will assess published comments and local drafts, apply justified fixes, run tests, and commit locally. Follow progress in Terminal.")
                .font(.subheadline).foregroundStyle(.secondary)
            Picker("Coding agent", selection: $agent) {
                ForEach(AgentKind.allCases, id: \.self) { value in Text(value.rawValue.capitalized).tag(value) }
            }.pickerStyle(.segmented).disabled(launching || session != nil)
            Text("Default fix prompt").font(.subheadline.bold())
            TextEditor(text: $instructions).font(.body).frame(height: 170)
                .overlay { RoundedRectangle(cornerRadius: 4).stroke(Color.secondary.opacity(0.25)) }
                .disabled(launching || session != nil)
            HStack {
                Button("Reset default prompt") { instructions = AgentFixRequest.defaultInstructions }.disabled(launching || session != nil)
                Spacer()
                Text("Commits stay local · pushing is separate").font(.caption).foregroundStyle(.secondary)
            }
            DisclosureGroup("PR and comment context") {
                ScrollView { Text(preview).font(.caption.monospaced()).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }.frame(height: 130)
                if target.request.defaultPrompt.count > 24_000 { Text("Preview is shortened. Complete comment context is sent to the agent.").font(.caption).foregroundStyle(.secondary) }
            }.font(.caption)
            if !valid { Text("The account, PR, or diff changed. Close and reopen this sheet.").foregroundStyle(.orange) }
            if !checkoutConfigured {
                Text("Configure a local checkout and worktree root in this PR's Workspace tab first.").font(.caption).foregroundStyle(.orange)
                Button("Configure workspace") { review.tab = .workspace; dismiss() }
            } else if !executableFound { Text("The selected coding-agent executable is unavailable. Check Workspace setup.").font(.caption).foregroundStyle(.orange) }
            if launching { HStack { ProgressView().controlSize(.small); Text("Checking the PR and starting the coding session…").font(.caption) } }
            if let error { Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled) }
            if let session {
                Text("Session started. The agent has been asked to fix, test, and commit; inspect its results in Terminal.").font(.caption).foregroundStyle(.secondary)
                Button("Open agent session") { workspace.focus(session) }
            }
            HStack {
                Button("Close") { dismiss() }.keyboardShortcut(.cancelAction).disabled(launching)
                Spacer()
                Button("Start fixes and commit") { start() }.buttonStyle(.borderedProminent).disabled(!canStart)
            }
        }.padding(24)
        }.frame(width: 680, height: 680)
            .background(Color(nsColor: .windowBackgroundColor))
            .interactiveDismissDisabled(launching)
            .onAppear {
                let preferredCommand = preferredAgent == .codex ? workspace.document.configuration.codexCommand : workspace.document.configuration.claudeCommand
                if AgentSessionManager.findExecutable(preferredCommand) != nil { agent = preferredAgent }
                else { agent = AgentSessionManager.findExecutable(workspace.document.configuration.codexCommand) != nil ? .codex : .claude }
            }
    }
    private func start() {
        guard canStart else { return }
        launching = true; error = nil
        launchTask = Task { @MainActor in
            defer { launching = false; launchTask = nil }
            do {
                let request = try await review.prepareFixRequest(for: target.identity, instructions: instructions)
                let started = try await workspace.launchFixes(request, agent: agent)
                session = started
                workspace.focus(started)
            } catch { self.error = error.localizedDescription }
        }
    }
}
