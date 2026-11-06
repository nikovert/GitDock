import AppKit
import GitDockCore
import SwiftUI

struct ReviewWorkspaceView: View {
    @Bindable var workspace: WorkspaceModel
    @Bindable var appModel: AppModel
    @State var review = ReviewWorkspaceModel()
    @State var layout = WorkspaceLayout()
    @State var textSize = WorkspaceTextSize()
    @AppStorage("githubbar.chat.configuration") private var configurationData = Data()
    @State private var showsCleanup = false
    @State private var showsStaleDrafts = false
    @State private var opensCleanupAfterDrafts = false
    @State private var staleDraftCleanup = StaleDraftCleanupModel()
    @AppStorage("staleDraftInactiveDays") private var staleDraftInactiveDays = 30
    @State private var showsChatSettings = false
    @State private var showsPriorityAuthors = false
    @State private var priorityAuthorsText = ""

    private var account: String? { workspace.monitoredAccountLogin }
    private var allPRs: [PullRequestPresentation] {
        return WorkspaceDashboard.active(appModel.state.needsYourReview + appModel.state.authoredPullRequests)
            .sorted {
                WorkspaceReviewContext.precedes(workspace.reviewContext(for: $0), workspace.reviewContext(for: $1),
                    in: workspace.document, priorityAuthors: workspace.priorityAuthors)
            }
    }
    private var selectedPR: PullRequestPresentation? {
        (workspace.pullRequests(in: appModel.state) + appModel.state.pullRequestStacks.flatMap(\.pullRequests)).first { $0.url == workspace.selectedSubject?.key.url }
    }
    private var filtered: [PullRequestPresentation] {
        rows(in: review.queue).filter {
            review.search.isEmpty || "\($0.title) \($0.repositoryNameWithOwner) #\($0.number) \($0.author?.displayName ?? "")"
                .localizedCaseInsensitiveContains(review.search)
        }
    }
    private var navigationID: String {
        "\(account ?? "")|\(workspace.selectedSubject?.key.description ?? "")|\(selectedPR?.headSHA ?? "")"
    }
    private var oldDraftCount: Int {
        guard let account, staleDraftInactiveDays > 0 else { return 0 }
        let cutoff = Date.now.addingTimeInterval(-Double(staleDraftInactiveDays) * 86_400)
        return appModel.state.authoredPullRequests.filter {
            $0.state == .open && $0.isDraft && $0.author?.displayName.lowercased() == account.lowercased() && $0.updatedAt <= cutoff
        }.count
    }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            GeometryReader { geometry in
                let widths = layout.resolvedWidths(availableWidth: geometry.size.width,
                    minimumCenterWidth: review.mode == .manage ? 580 : 440, includesInspector: review.mode == .review)
                HStack(spacing: 0) {
                    if layout.showsSidebar {
                        sidebar.frame(width: widths.sidebar)
                        WorkspaceResizeDivider(width: Binding(get: { widths.sidebar }, set: { layout.sidebarWidth = $0 }),
                            minimum: 180, maximum: min(520, geometry.size.width - 440 - (review.mode == .review ? widths.inspector : 0) - 20))
                            .frame(width: WorkspaceLayout.dividerWidth)
                    }
                    if review.mode == .manage {
                        management
                    } else {
                        ReviewDetailView(review: review, workspace: workspace, pullRequest: selectedPR,
                            stacks: appModel.state.pullRequestStacks, layout: layout)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                        if layout.showsInspector {
                            WorkspaceResizeDivider(width: Binding(get: { widths.inspector }, set: { layout.inspectorWidth = $0 }),
                                minimum: 240, maximum: min(720, geometry.size.width - widths.sidebar - 440 - 20), direction: -1)
                                .frame(width: WorkspaceLayout.dividerWidth)
                            ReviewChatPanel(review: review, workspace: workspace, pullRequest: selectedPR,
                                showsSettings: $showsChatSettings, textSize: textSize).frame(width: widths.inspector)
                        }
                    }
                }
            }
            if let error = review.errorMessage ?? workspace.errorMessage ?? review.local.errorMessage {
                Divider()
                HStack(alignment: .top) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    Text(error).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                    Button("Dismiss") { review.errorMessage = nil; workspace.errorMessage = nil }
                }
                .padding(12).background(Color(nsColor: .windowBackgroundColor))
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .workspaceTextSizing(textSize.workspaceScale)
        .frame(minWidth: 900, minHeight: 650)
        .sheet(isPresented: $showsCleanup) { WorktreeCleanupView(model: workspace.cleanup) }
        .sheet(isPresented: $showsStaleDrafts, onDismiss: {
            if opensCleanupAfterDrafts { opensCleanupAfterDrafts = false; openCleanup() }
        }) {
            StaleDraftCleanupView(model: staleDraftCleanup, accountLogin: account,
                workload: appModel.state.authoredPullRequests,
                onClosed: {
                    appModel.send(.manualRefresh); review.refresh()
                    await workspace.reload()
                }, onManualCleanup: { opensCleanupAfterDrafts = true })
        }
        .sheet(isPresented: $showsChatSettings) { ReviewChatSettingsView() }
        .sheet(isPresented: $showsPriorityAuthors) {
            VStack(alignment: .leading, spacing: 16) {
                Text("Priority authors").workspaceFont(.title2.bold())
                Text("Give these authors medium automatic priority. Separate GitHub logins with commas.").foregroundStyle(.secondary)
                TextField("GitHub logins", text: $priorityAuthorsText).textFieldStyle(.roundedBorder)
                HStack {
                    Button("Cancel") { showsPriorityAuthors = false }
                    Spacer()
                    Button("Save") {
                        workspace.setPriorityAuthors(priorityAuthorsText.split(separator: ",").map(String.init))
                        showsPriorityAuthors = false
                    }.buttonStyle(.borderedProminent)
                }
            }.padding(24).frame(width: 460)
        }
        .onAppear {
            if workspace.selectedSubject != nil { review.mode = .review }
        }
        .onChange(of: workspace.selectedSubject) { _, subject in
            if subject != nil { review.mode = .review }
        }
        .task(id: navigationID) {
            review.select(workspace.selectedSubject?.key, account: account, force: true)
        }
    }

    private var toolbar: some View {
        HStack(spacing: 16) {
            Image(systemName: "arrow.triangle.pull").workspaceFont(.title3).foregroundStyle(.blue)
            Text("GitDock Workspace").workspaceFont(.headline)
            Picker("Mode", selection: $review.mode) {
                ForEach(ReviewWorkspaceMode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }.pickerStyle(.segmented).labelsHidden().frame(width: 240)
            Spacer()
            if appModel.state.isRefreshing || review.loading { ProgressView().controlSize(.small) }
            Button { appModel.send(.manualRefresh); review.refresh(); Task { await workspace.reload() } } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }.help("Refresh GitHub and local workspace status")
            Menu {
                Button("Worktree cleanup…") { openCleanup() }
                    .disabled(account == nil)
                Button("Old drafts on GitHub (\(oldDraftCount))…") { showsStaleDrafts = true }
                    .disabled(account == nil)
                Button("Priority authors…") {
                    priorityAuthorsText = workspace.priorityAuthors.joined(separator: ", ")
                    showsPriorityAuthors = true
                }
                Button("Configure chat agent…") { showsChatSettings = true }
            } label: { Image(systemName: "ellipsis.circle") }.menuStyle(.borderlessButton).frame(width: 28)
            Menu("Layout") {
                Toggle("Show PR sidebar", isOn: $layout.showsSidebar)
                Toggle("Show file list", isOn: $layout.showsFileList)
                Toggle("Show chat", isOn: $layout.showsInspector)
                Divider()
                Button("Focus diff") {
                    review.mode = .review; review.tab = .changes
                    layout.showsSidebar = false; layout.showsFileList = false; layout.showsInspector = false
                }
                Button("Reset layout") { layout.reset() }
            }

        }.padding(.horizontal, 18).padding(.vertical, 12)
            .background(Color(nsColor: .controlBackgroundColor))
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("YOUR WORK").workspaceFont(.caption.weight(.semibold)).foregroundStyle(.secondary).padding(.top, 8)
            ForEach(ReviewWorkspaceQueue.allCases, id: \.self) { queue in
                Button { review.queue = queue } label: {
                    HStack {
                        Label(queue.rawValue, systemImage: queue.icon)
                        Spacer()
                        Text("\(rows(in: queue).count)").monospacedDigit().foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 9).padding(.vertical, 7)
                    .background(review.queue == queue ? Color.accentColor.opacity(0.13) : .clear,
                        in: RoundedRectangle(cornerRadius: 7))
                    .contentShape(Rectangle())
                }.buttonStyle(.plain)
            }
            Divider()
            TextField("Find a PR…", text: $review.search).textFieldStyle(.roundedBorder)
            ScrollView {
                LazyVStack(spacing: 7) {
                    ForEach(filtered) { pr in
                        Button { select(pr, openReview: true) } label: {
                            VStack(alignment: .leading, spacing: 5) {
                                HStack {
                                    Text("#\(pr.number)").workspaceFont(.caption).foregroundStyle(.secondary)
                                    Spacer()
                                    if review.local.isPinned(identity(pr)) { Image(systemName: "pin.fill").workspaceFont(.caption2) }
                                }
                                Text(pr.title).workspaceFont(.subheadline.weight(.medium)).lineLimit(3)
                                Text("@\(pr.author?.displayName ?? "unknown") · \(pr.repositoryNameWithOwner)")
                                    .workspaceFont(.caption2).foregroundStyle(.secondary).lineLimit(1)
                                Text(nextAction(pr)).workspaceFont(.caption2).foregroundStyle(.secondary).lineLimit(2)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading).padding(10)
                            .background(workspace.selectedSubject?.key.url == pr.url ? Color.accentColor.opacity(0.13) : .clear,
                                in: RoundedRectangle(cornerRadius: 8))
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .contextMenu { prActions(pr) }
                    }
                    if filtered.isEmpty { Text("No PRs in this view.").foregroundStyle(.secondary).padding(.top, 20) }
                }
            }
            Text(account.map { "@\($0)" } ?? "Connect GitHub in Settings")
                .workspaceFont(.caption).foregroundStyle(.secondary)
        }.padding(12).background(Color(nsColor: .controlBackgroundColor))
    }

    private var management: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text("Pull request dashboard").workspaceFont(.largeTitle.weight(.semibold))
                        Text("\(allPRs.count) open · \(rows(in: .requested).count) requested reviews · \(rows(in: .mine).count) authored")
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                HStack {
                    Picker("Queue", selection: $review.queue) {
                        ForEach(ReviewWorkspaceQueue.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }.frame(maxWidth: 260)
                    TextField("Search title, repository, author or number", text: $review.search)
                        .textFieldStyle(.roundedBorder)
                }
                refreshNotice
                VStack(alignment: .leading, spacing: 10) {
                    AutomaticCleanupActivityView(model: workspace.cleanup)
                    HStack {
                        Button("Review cleanup…") { openCleanup() }.controlSize(.small)
                        if oldDraftCount > 0 {
                            Button("\(oldDraftCount) old drafts…") { showsStaleDrafts = true }.controlSize(.small)
                        }
                    }
                }.padding(12).background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
                Text("\(review.queue.rawValue) · \(filtered.count) pull requests").workspaceFont(.headline)
                let groups = WorkspaceDashboard.groups(visible: filtered, stacks: appModel.state.pullRequestStacks)
                ForEach(groups.filter { $0.stack != nil }) { group in
                    DisclosureGroup(isExpanded: stackExpansion(group.id)) {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 270), alignment: .top)], alignment: .leading, spacing: 12) {
                            ForEach(group.members.filter { $0.pullRequest.state == .open }) { member in prCard(member.pullRequest, contextOnly: member.isNavigationContext) }
                        }.padding(.top, 10)
                    } label: {
                        HStack {
                            Label("Stack #\(group.stack?.number ?? 0)", systemImage: "square.stack.3d.up")
                            Text(group.members.first?.pullRequest.repositoryNameWithOwner ?? "").foregroundStyle(.secondary)
                            Spacer()
                            Text("\(group.members.filter { !$0.isNavigationContext }.count) matching · \(group.stack?.size ?? group.members.count) members")
                                .workspaceFont(.caption).foregroundStyle(.secondary)
                        }.workspaceFont(.subheadline.weight(.semibold))
                    }.padding(14).background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
                }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 270), alignment: .top)], alignment: .leading, spacing: 12) {
                    ForEach(groups.filter { $0.stack == nil }) { group in
                        if let member = group.members.first { prCard(member.pullRequest) }
                    }
                }
                if filtered.isEmpty { ContentUnavailableView("No pull requests in this view", systemImage: "tray", description: Text("Choose another queue or adjust the search.")) }
                Text("Urgency follows manual priority, requested reviewers and priority authors. Age and GitHub activity are shown separately; activity may include bots.")
                    .workspaceFont(.caption).foregroundStyle(.secondary)
            }.padding(22).frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func openCleanup() {
        workspace.cleanup.scan()
        showsCleanup = true
    }

    @ViewBuilder private var refreshNotice: some View {
        switch appModel.state.refreshHealth {
        case .partial(let message), .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle")
                .workspaceFont(.caption).foregroundStyle(.orange).textSelection(.enabled)
        case .restoredSnapshot:
            Text("Showing saved PR data while GitHub refreshes.").workspaceFont(.caption).foregroundStyle(.secondary)
        default: EmptyView()
        }
    }

    @State private var collapsedStacks: Set<String> = []
    private func stackExpansion(_ id: String) -> Binding<Bool> {
        Binding(get: { !collapsedStacks.contains(id) }, set: { if $0 { collapsedStacks.remove(id) } else { collapsedStacks.insert(id) } })
    }

    private func prCard(_ pr: PullRequestPresentation, contextOnly: Bool = false) -> some View {
        let priority = workspace.reviewPriority(for: workspace.reviewContext(for: pr))
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("#\(pr.number)").workspaceFont(.caption.monospaced()).foregroundStyle(.secondary)
                Spacer()
                if review.local.isPinned(identity(pr)) { Image(systemName: "pin.fill").workspaceFont(.caption) }
                Text(reviewStatusSummary(for: pr)).workspaceFont(.caption.weight(.medium))
            }
            Button { select(pr, openReview: true) } label: {
                Text(pr.title).workspaceFont(.headline).foregroundStyle(.primary)
                    .frame(maxWidth: .infinity, alignment: .leading).multilineTextAlignment(.leading)
            }.buttonStyle(.plain)
            Text("\(pr.repositoryNameWithOwner) · @\(pr.author?.displayName ?? "unknown")")
                .workspaceFont(.caption).foregroundStyle(.secondary)
            if contextOnly {
                Label("\(pr.state == .open ? "Outside this queue" : pr.state.rawValue.capitalized) · navigation context", systemImage: "link")
                    .workspaceFont(.caption).foregroundStyle(.secondary)
            } else {
                Text("Requested: \(requestedReviewerSummary(for: pr))").workspaceFont(.caption).foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 3) {
                    Text("\(priority.label) urgency").workspaceFont(.subheadline.weight(.semibold))
                        .foregroundStyle(priority.rank >= 3 ? Color.orange : Color.secondary)
                    Text(priority.reason).workspaceFont(.caption).foregroundStyle(.secondary)
                }
                VStack(alignment: .leading, spacing: 3) {
                    if let created = pr.createdAt { Text("Opened \(created, style: .relative) ago") }
                    else { Text("Age unavailable") }
                    Text("Last activity \(pr.updatedAt, style: .relative) ago")
                }.workspaceFont(.caption).foregroundStyle(.secondary)
                Divider()
                Text(nextAction(pr)).workspaceFont(.subheadline)
            }
            HStack {
                Button(contextOnly ? "Open PR" : "Review PR") { select(pr, openReview: true) }
                if !contextOnly {
                    Button("Agent review") { requestAgentReview(pr) }.disabled(review.reviewing || account == nil)
                }
                Spacer()
                Link(destination: pr.url) { Image(systemName: "arrow.up.right.square") }.help("Open on GitHub")
            }.controlSize(.small)
        }.padding(14).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
            .overlay { RoundedRectangle(cornerRadius: 10).stroke(Color.secondary.opacity(0.18)) }
            .contextMenu { prActions(pr) }
    }

    private func requestAgentReview(_ pr: PullRequestPresentation) {
        guard let key = try? PullRequestKey(url: pr.url) else { return }
        let configuration = (try? JSONDecoder().decode(ReviewChatConfiguration.self, from: configurationData)) ?? ReviewChatConfiguration()
        guard (try? configuration.validated()) != nil else { showsChatSettings = true; return }
        review.requestAgentReview(for: key, account: account, configuration: configuration)
        workspace.openPullRequest(pr)
    }

    private func identity(_ pr: PullRequestPresentation) -> ReviewIdentity {
        ReviewIdentity(account: account ?? "", prURL: pr.url.absoluteString, headSHA: pr.headSHA ?? "")
    }
    private func rows(in queue: ReviewWorkspaceQueue) -> [PullRequestPresentation] {
        allPRs.filter { pr in
            let id = identity(pr)
            let snoozed = review.local.isSnoozed(id)
            switch queue {
            case .all: return true
            case .snoozed: return snoozed
            case .pinned: return review.local.isPinned(id)
            case .mine: return !snoozed && pr.author?.displayName.lowercased() == account?.lowercased()
            case .requested: return !snoozed && appModel.state.needsYourReview.contains { $0.url == pr.url }
            case .attention:
                return !snoozed && (appModel.state.needsYourReview.contains { $0.url == pr.url }
                    || pr.reviewDecision == .changesRequested)
            }
        }
    }
    private func nextAction(_ pr: PullRequestPresentation) -> String {
        if pr.isDraft { return "Draft in progress" }
        if pr.reviewDecision == .changesRequested { return "Address review feedback" }
        if appModel.state.needsYourReview.contains(where: { $0.url == pr.url }) { return "Your review is requested" }
        if pr.reviewDecision == .approved { return "Approved · check merge readiness" }
        if pr.requestedReviewers?.isEmpty == true && pr.reviewDecision == nil { return "Request reviewers" }
        return "Waiting for reviewers"
    }
    private func select(_ pr: PullRequestPresentation, openReview: Bool) {
        workspace.openPullRequest(pr)
        if openReview { review.mode = .review }
    }
    @ViewBuilder private func prActions(_ pr: PullRequestPresentation) -> some View {
        Button("Open review") { select(pr, openReview: true) }
        Link("Open on GitHub", destination: pr.url)
        if let key = try? PullRequestKey(url: pr.url) {
            Menu("Manual priority") {
                ForEach(BoardPriority.allCases, id: \.self) { priority in
                    Button(priority == .none ? "Automatic" : priority.rawValue.capitalized) { workspace.setPriority(priority, for: .pullRequest(key)) }
                }
            }
        }
        Button(review.local.isPinned(identity(pr)) ? "Unpin PR" : "Pin PR") {
            review.local.setPinned(!review.local.isPinned(identity(pr)), for: identity(pr))
        }
        Button(review.local.isSnoozed(identity(pr)) ? "Unsnooze" : "Snooze for 24 hours") {
            review.local.snooze(until: review.local.isSnoozed(identity(pr)) ? nil : Date.now.addingTimeInterval(86400), for: identity(pr))
        }
        if let stack = appModel.state.pullRequestStacks.first(where: { $0.pullRequests.contains { $0.url == pr.url } }),
           let root = stack.root, let key = try? PullRequestKey(url: root.url) {
            Button("Manage stack") { workspace.selectedSubject = .stack(key); review.mode = .review; review.tab = .workspace }
        }
    }
}

extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
