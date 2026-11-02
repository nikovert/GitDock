import AppKit
import GitHubBarCore
import SwiftUI

struct WorkspaceBoardView: View {
    @Bindable var workspace: WorkspaceModel
    @Bindable var appModel: AppModel
    @State private var showsCleanup = false

    private var pullRequests: [PullRequestPresentation] {
        workspace.pullRequests(in: appModel.state)
    }

    private var subjects: [BoardSubject] {
        var result = appModel.state.pullRequestStacks.compactMap { stack in
            stack.root.flatMap { try? PullRequestKey(url: $0.url) }.map(BoardSubject.stack)
        }
        result += pullRequests.compactMap { pullRequest in
            (try? PullRequestKey(url: pullRequest.url)).map(BoardSubject.pullRequest)
        }
        return Array(Set(result)).sorted {
            if let lhs = priorityContext(for: $0), let rhs = priorityContext(for: $1), lhs != rhs {
                return WorkspaceReviewContext.precedes(lhs, rhs, in: workspace.document,
                    priorityAuthors: workspace.priorityAuthors)
            }
            return $0.key.description < $1.key.description
        }
    }

    var body: some View {
        HStack(spacing: 0) {
            List(selection: $workspace.selectedSubject) {
                ForEach(subjects, id: \.self) { subject in
                    subjectRow(subject).tag(subject)
                }
            }
            .frame(minWidth: 290, idealWidth: 350)

            Divider()

            if let subject = workspace.selectedSubject {
                WorkspaceDetailView(
                    workspace: workspace,
                    subject: subject,
                    stackRoot: stackRoot(for: subject),
                    details: details(for: subject)
                )
                .id(subject)
            } else {
                VStack {
                    ContentUnavailableView(
                        "Select a pull request",
                        systemImage: "tray.full",
                        description: Text("Choose a PR or stack to set local status and manage agents.")
                    )
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(minWidth: 840, minHeight: 590)
        .safeAreaInset(edge: .top, spacing: 0) {
            HStack {
                Button("Refresh", systemImage: "arrow.clockwise") {
                    appModel.send(.manualRefresh)
                    Task { await workspace.reload() }
                }
                .help("Refresh pull requests and local workspace status")
                if appModel.state.isRefreshing {
                    ProgressView().controlSize(.small)
                    Text("Refreshing…").foregroundStyle(.secondary)
                } else if let updated = appModel.state.lastUpdatedAt {
                    Text("Updated \(updated.formatted(date: .omitted, time: .standard))")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Clean up merged worktrees…", systemImage: "trash") {
                    showsCleanup = true
                    workspace.cleanup.scan()
                }
                .disabled(workspace.monitoredAccountLogin == nil)
            }
            .padding(12)
            .background(Color(nsColor: .windowBackgroundColor))
            .overlay(alignment: .bottom) { Divider() }
        }
        .sheet(isPresented: $showsCleanup) { WorktreeCleanupView(model: workspace.cleanup) }
        .onAppear {
            if workspace.selectedSubject == nil { workspace.selectedSubject = subjects.first }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if let error = workspace.errorMessage {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                    ScrollView {
                        Text(error)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                    }
                    .frame(maxHeight: 110)
                    Button("Dismiss") { workspace.errorMessage = nil }
                }
                .foregroundStyle(.primary)
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(nsColor: .windowBackgroundColor))
                .overlay(alignment: .top) {
                    Rectangle().fill(Color.red).frame(height: 2)
                }
            }
        }
    }

    private func subjectRow(_ subject: BoardSubject) -> some View {
        let context = priorityContext(for: subject)
        let details = details(for: subject)
        return HStack(spacing: 6) {
            Image(systemName: subject.isStack ? "square.stack.3d.up" : "arrow.triangle.pull")
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(details?.primary.title ?? subject.key.description)
                    .font(.subheadline.weight(.medium)).lineLimit(2)
                Text("\(subject.key.description) · by \(details?.primary.author?.displayName ?? "unknown")")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                if let details {
                    Text("\(subject.isStack ? "Stack · \(details.members.count) PRs · " : "")Requested: \(requestedReviewerSummary(for: details.primary))")
                        .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                }
                if let context {
                    Text(workspace.reviewPriority(for: context).reason)
                        .font(.caption2).foregroundStyle(.secondary).lineLimit(2)
                }
            }
            Spacer()
            if let context {
                Text(workspace.reviewPriority(for: context).label)
                    .font(.caption2).foregroundStyle(.orange)
            }
            if !workspace.document.sessions(for: subject).isEmpty {
                Image(systemName: "terminal").foregroundStyle(.secondary)
            }
        }
        .help(details?.primary.title ?? subject.key.description)
    }

    private func priorityContext(for subject: BoardSubject) -> AgentPRContext? {
        guard let details = details(for: subject) else { return nil }
        let members = subject.isStack ? details.members : [details.primary]
        return members.map { workspace.reviewContext(for: $0) }.sorted {
            WorkspaceReviewContext.precedes($0, $1, in: workspace.document,
                priorityAuthors: workspace.priorityAuthors)
        }.first
    }

    private func details(for subject: BoardSubject) -> BoardSubjectDetails? {
        BoardSubjectDetails.resolve(
            subject: subject, pullRequests: pullRequests,
            stacks: appModel.state.pullRequestStacks
        )
    }

    private func stackRoot(for subject: BoardSubject) -> PullRequestKey? {
        guard case .pullRequest = subject else { return nil }
        return appModel.state.pullRequestStacks.first { stack in
            stack.pullRequests.contains { (try? PullRequestKey(url: $0.url)) == subject.key }
        }?.root.flatMap { try? PullRequestKey(url: $0.url) }
    }
}

struct WorkspaceDetailView: View {
    @Bindable var workspace: WorkspaceModel
    let subject: BoardSubject
    let stackRoot: PullRequestKey?
    let details: BoardSubjectDetails?

    @State private var noteDraft = ""
    @State private var checkoutPath = ""
    @State private var worktreeRoot = ""
    @State private var pinPath = ""
    @State private var pinTmuxName = ""
    @State private var pinAgent: AgentKind = .codex
    @State private var customTagName = ""
    @State private var customTagColor: BoardTagColor = .blue
    @State private var worktreeToRemove: AgentSessionLink?

    private var resolved: ResolvedBoardEntry {
        workspace.document.resolvedEntry(for: subject, stackRoot: stackRoot)
    }

    private var relatedSessions: [AgentSessionLink] {
        let direct = workspace.document.sessions(for: subject)
        guard let stackRoot else { return direct }
        return direct + workspace.document.sessions(for: .stack(stackRoot))
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(details?.primary.title ?? subject.key.description)
                            .font(.title2.bold())
                        Text("\(subject.key.description) · \(subject.isStack ? "Stack" : "Pull request")")
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Link("Open on GitHub ↗", destination: subject.key.url)
                }

                if let details {
                    GroupBox(subject.isStack ? "Stack root on GitHub" : "Pull request on GitHub") {
                        VStack(alignment: .leading, spacing: 7) {
                            Text("Author: \(details.primary.author?.displayName ?? "Unavailable")")
                            Text("Requested reviewers: \(requestedReviewerSummary(for: details.primary))")
                            Text("Review status: \(reviewStatusSummary(for: details.primary))")
                            Text("Last GitHub update: \(details.primary.updatedAt, style: .relative)")
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(5)
                    }
                    if subject.isStack {
                        GroupBox("Pull requests in stack") {
                            VStack(alignment: .leading, spacing: 10) {
                                ForEach(details.members) { member in
                                    VStack(alignment: .leading, spacing: 2) {
                                        Link("#\(member.number) \(member.title)", destination: member.url)
                                        Text("By \(member.author?.displayName ?? "unknown") · Requested: \(requestedReviewerSummary(for: member))")
                                            .font(.caption).foregroundStyle(.secondary)

                                    }
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                }
                            }
                            .padding(5)
                        }
                    }
                } else {
                    Text("GitHub PR details are unavailable until the next refresh.")
                        .foregroundStyle(.secondary)
                }

                GroupBox("Priority and status") {
                    VStack(alignment: .leading, spacing: 10) {
                        Picker("Priority", selection: Binding(
                            get: { workspace.document.entry(for: subject)?.priority ?? .none },
                            set: { workspace.setPriority($0, for: subject) }
                        )) {
                            ForEach(BoardPriority.allCases, id: \.self) { priority in
                                Text(priority == .none ? "Automatic" : priority.rawValue.capitalized)
                                    .tag(priority)
                            }
                        }
                        .frame(maxWidth: 270)
                        if let primary = details?.primary {
                            let priority = workspace.reviewPriority(for: workspace.reviewContext(for: primary))
                            Text("Effective: \(priority.label) · \(priority.reason)")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        FlowTagsView(workspace: workspace, subject: subject, selectedIDs: resolved.tagIDs)
                        if let origin = resolved.updatedBy {
                            Text("Last local update by \(origin)")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(5)
                }

                GroupBox("Agent notes") {
                    VStack(alignment: .leading) {
                        TextEditor(text: $noteDraft)
                            .font(.body)
                            .frame(minHeight: 85)
                            .scrollContentBackground(.hidden)
                        Button("Save note") { workspace.setNote(noteDraft, for: subject) }
                    }
                    .padding(5)
                }

                GroupBox("Pinned agent sessions") {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(relatedSessions) { session in
                            sessionRow(session)
                        }
                        if relatedSessions.isEmpty {
                            Text("No agent session pinned yet.")
                                .foregroundStyle(.secondary)
                        }
                        HStack {
                            Button("New Codex worktree") { workspace.launch(.codex, for: subject) }
                            Button("New Claude worktree") { workspace.launch(.claude, for: subject) }
                        }
                        Divider()
                        Text("Pin an existing worktree or tmux session")
                            .font(.subheadline.bold())
                        HStack {
                            Picker("Agent", selection: $pinAgent) {
                                ForEach(AgentKind.allCases, id: \.self) { agent in
                                    Text(agent.rawValue.capitalized).tag(agent)
                                }
                            }
                            .frame(width: 140)
                            TextField("Absolute worktree path", text: $pinPath)
                            TextField("tmux session (optional)", text: $pinTmuxName)
                        }
                        Button("Pin session") {
                            workspace.pin(pinAgent, for: subject, path: pinPath, tmuxName: pinTmuxName)
                        }
                        .disabled(pinPath.isEmpty)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(5)
                }

                DisclosureGroup("Workspace setup") {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Local checkout for \(subject.key.repositoryNameWithOwner)")
                        HStack {
                            TextField("Absolute checkout path", text: $checkoutPath)
                            Button("Save checkout") {
                                workspace.saveCheckout(checkoutPath, for: subject.key.repositoryNameWithOwner)
                            }
                        }
                        Text("Root for new worktrees")
                        HStack {
                            TextField("Absolute worktree root", text: $worktreeRoot)
                            Button("Save root") { workspace.saveWorktreeRoot(worktreeRoot) }
                        }
                        Text("New worktrees require origin to match the PR repository.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    .padding(.top, 8)
                }

                DisclosureGroup("Manage status tags") {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(workspace.document.tags) { tag in
                            TagEditorRow(tag: tag, onSave: workspace.saveTag)
                        }
                        HStack {
                            TextField("New tag", text: $customTagName)
                            Picker("Color", selection: $customTagColor) {
                                ForEach(BoardTagColor.allCases, id: \.self) { color in
                                    Text(color.rawValue.capitalized).tag(color)
                                }
                            }
                            Button("Add") {
                                workspace.createTag(name: customTagName, color: customTagColor)
                                customTagName = ""
                            }
                        }
                    }
                    .padding(.top, 8)
                }
            }
            .padding(22)
        }
        .onAppear(perform: loadDrafts)
        .onChange(of: resolved.note) { previous, updated in
            if noteDraft == previous { noteDraft = updated }
        }
        .confirmationDialog(
            "Remove this managed worktree?",
            isPresented: Binding(
                get: { worktreeToRemove != nil },
                set: { if !$0 { worktreeToRemove = nil } }
            )
        ) {
            Button("Remove clean worktree", role: .destructive) {
                if let session = worktreeToRemove { workspace.removeWorktree(session.id) }
                worktreeToRemove = nil
            }
        } message: {
            Text("GitHubBar will refuse if the worktree has uncommitted changes. This cannot be undone here.")
        }
    }

    private func sessionRow(_ session: AgentSessionLink) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Image(systemName: "terminal")
                Text(session.agent.rawValue.capitalized).bold()
                Text(session.state.rawValue.capitalized)
                    .foregroundStyle(session.state == .running ? .green : .secondary)
                Spacer()
                Button("Jump to session") { workspace.focus(session) }
                    .disabled(session.state != .running && session.tmuxSessionName != nil)
                Button("Stop") { workspace.stopSession(session.id) }
                    .disabled(session.state != .running)
                Button("Restart") { workspace.restartSession(session.id) }
                    .disabled(session.tmuxSessionName == nil)
                Menu {
                    Button("Unpin") { workspace.unlinkSession(session.id) }
                    if session.managedWorktree {
                        Button("Remove worktree…") { worktreeToRemove = session }
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
            Text(session.worktreePath)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
            if let name = session.tmuxSessionName {
                Text("tmux: \(name)")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(8)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
    }

    private func loadDrafts() {
        noteDraft = resolved.note
        checkoutPath = workspace.document.configuration.repositoryCheckouts[
            subject.key.repositoryNameWithOwner
        ] ?? ""
        worktreeRoot = workspace.document.configuration.worktreeRoot
    }
}

private struct FlowTagsView: View {
    @Bindable var workspace: WorkspaceModel
    let subject: BoardSubject
    let selectedIDs: Set<String>

    var body: some View {
        HStack(spacing: 5) {
            ForEach(workspace.document.tags.filter { !$0.isArchived }) { tag in
                let selected = selectedIDs.contains(tag.id)
                Button {
                    workspace.setTag(
                        tag.id, enabled: !selected, currentIDs: selectedIDs, for: subject
                    )
                } label: {
                    Text(tag.name)
                        .font(.caption)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 4)
                        .background(tag.color.swiftUIColor.opacity(selected ? 0.3 : 0.08), in: Capsule())
                        .overlay { Capsule().stroke(tag.color.swiftUIColor.opacity(0.5)) }
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(tag.name), \(selected ? "selected" : "not selected")")
            }
        }
    }
}

private struct TagEditorRow: View {
    let tag: BoardTag
    let onSave: (BoardTag) -> Void
    @State private var name: String
    @State private var color: BoardTagColor

    init(tag: BoardTag, onSave: @escaping (BoardTag) -> Void) {
        self.tag = tag
        self.onSave = onSave
        _name = State(initialValue: tag.name)
        _color = State(initialValue: tag.color)
    }

    var body: some View {
        HStack {
            TextField("Name", text: $name)
            Picker("Color", selection: $color) {
                ForEach(BoardTagColor.allCases, id: \.self) { choice in
                    Text(choice.rawValue.capitalized).tag(choice)
                }
            }
            Button("Save") {
                var updated = tag
                updated.name = name
                updated.color = color
                onSave(updated)
            }
            if !tag.isBuiltIn {
                Button("Archive") {
                    var updated = tag
                    updated.isArchived = true
                    onSave(updated)
                }
            }
        }
    }
}

extension BoardSubject {
    var isStack: Bool {
        if case .stack = self { return true }
        return false
    }
}

func requestedReviewerSummary(for pullRequest: PullRequestPresentation) -> String {
    guard let requested = pullRequest.requestedReviewers else { return "Unavailable" }
    guard !requested.isEmpty else { return "None" }
    return requested.map(\.displayName).joined(separator: ", ")
}

func reviewStatusSummary(for pullRequest: PullRequestPresentation) -> String {
    if pullRequest.isDraft { return "Draft" }
    switch pullRequest.reviewDecision {
    case .approved: return "Approved"
    case .changesRequested: return "Changes requested"
    case .reviewRequired: return "Review required"
    case nil: return "Unavailable"
    }
}

private extension BoardTagColor {
    var swiftUIColor: Color {
        switch self {
        case .red: .red
        case .orange: .orange
        case .yellow: .yellow
        case .green: .green
        case .blue: .blue
        case .purple: .purple
        case .gray: .gray
        }
    }
}
