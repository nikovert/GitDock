import AppKit
import GitHubBarCore
import SwiftUI

struct PopoverView: View {
    static let preferredWidth: CGFloat = 440
    static let fallbackHeight: CGFloat = 700
    static let minimumResponsiveHeight: CGFloat = 640
    static let maximumHeight: CGFloat = 900
    static let screenEdgeClearance: CGFloat = 120

    static func resolvedHeight(forVisibleScreenHeight visibleScreenHeight: CGFloat?) -> CGFloat {
        guard let visibleScreenHeight else { return Self.fallbackHeight }
        return min(
            Self.maximumHeight,
            max(Self.minimumResponsiveHeight, floor(visibleScreenHeight - Self.screenEdgeClearance))
        )
    }

    @Bindable var appModel: AppModel
    let actions: AppActions
    let avatarImageCache: AvatarImageCache
    let workspaceModel: WorkspaceModel?

    init(
        appModel: AppModel,
        actions: AppActions = AppActions(),
        avatarImageCache: AvatarImageCache,
        workspaceModel: WorkspaceModel? = nil
    ) {
        self.appModel = appModel
        self.actions = actions
        self.avatarImageCache = avatarImageCache
        self.workspaceModel = workspaceModel
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            MenuActionRow(title: "Search PRs…", systemImage: "magnifyingglass", shortcut: "⌘ F") { actions.openSearch() }
            insetDivider
            if isConnected {
                RepositoryScopeControl(appModel: appModel, onManage: actions.openSettings)
                ScrollView {
                    LazyVStack(spacing: 0) {
                        if isInitialLoading {
                            InitialWorkloadLoadingView()
                        }
                        if case let .connected(_, accessCoverage) = appModel.state.accountConnection,
                           !accessCoverage.isComplete {
                            AccessCoverageBanner(accessCoverage: accessCoverage)
                        }
                        if appModel.state.repositoryScope == .pinned, appModel.state.pinnedRepositories.isEmpty {
                            VStack(alignment: .leading, spacing: 8) {
                                Text("No pinned repositories").font(.headline)
                                Text("Choose the repositories you care about on this Mac.")
                                    .font(.caption).foregroundStyle(.secondary)
                                Button("Choose repositories in Settings…") { actions.openSettings() }
                            }.frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 20)
                        } else if !isInitialLoading {
                            workloadSection(title: "Needs your review", pullRequests: appModel.state.needsYourReview,
                                            emptyMessage: "Nothing is waiting for your review.")
                            ForEach(AuthoredPullRequestSection.allCases, id: \.self) { section in
                                workloadSection(title: sectionTitle(section), pullRequests: appModel.state.authoredPullRequests.filter {
                                    $0.authoredSection == section
                                }, emptyMessage: "No pull requests in this section.")
                            }
                            let legacy = appModel.state.authoredPullRequests.filter { $0.authoredSection == nil }
                            if !legacy.isEmpty {
                                workloadSection(title: "My PRs", pullRequests: legacy, emptyMessage: "")
                            }
                        }
                    }
                    .padding(.horizontal, 18)
                }
            } else {
                AccountConnectionView(
                    accountConnection: appModel.state.accountConnection,
                    send: appModel.send
                )
            }
            footer
        }
        .frame(width: Self.preferredWidth)
        .frame(minHeight: 470, idealHeight: Self.fallbackHeight, maxHeight: Self.maximumHeight)
        .background(VisualEffectBackground())
        .environmentObject(avatarImageCache)
    }

    private func workloadSection(title: String, pullRequests: [PullRequestPresentation], emptyMessage: String) -> some View {
        WorkloadSection(title: title, pullRequests: pullRequests, emptyMessage: emptyMessage,
                        showsRepository: showsRepositoryInRows, stacks: appModel.state.pullRequestStacks,
                        actions: actions, workspaceModel: workspaceModel)
    }

    private func sectionTitle(_ section: AuthoredPullRequestSection) -> String {
        switch section {
        case .returnedToYou: "Returned to you"
        case .needsReviewers: "Needs reviewers"
        case .waitingForReviewers: "Waiting for reviewers"
        case .approved: "Approved"
        case .drafts: "Drafts"
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text("GitHubBar")
                    .font(.system(size: 14, weight: .bold))
                Text(updatedLabel)
                    .font(.system(size: 10))
                    .foregroundStyle(updatedLabelColor)
                    .help(updatedLabelHelp)
                    .accessibilityLabel("Refresh status: \(updatedLabel)")
            }
            Spacer(minLength: 8)
            Text(accountLabel)
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(.horizontal, 18)
        .padding(.top, 13)
        .padding(.bottom, 9)
    }

    private var insetDivider: some View {
        Divider().padding(.horizontal, 18)
    }

    private var footer: some View {
        VStack(spacing: 0) {
            Divider().padding(.horizontal, 18)
            MenuActionRow(title: "Open Workspace", systemImage: "rectangle.split.3x1") { actions.openWorkspace(nil) }
            if isConnected {
                MenuActionRow(title: "Refresh", systemImage: "arrow.clockwise", shortcut: "⌘ R") {
                    appModel.send(.manualRefresh)
                }
            }
            MenuActionRow(title: "Settings…", systemImage: "gearshape", shortcut: "⌘ ,") {
                actions.openSettings()
            }
            MenuActionRow(title: "About GitHubBar", systemImage: "info.circle") {
                actions.openAbout()
            }
            MenuActionRow(title: "Quit", systemImage: "rectangle.portrait.and.arrow.right", shortcut: "⌘ Q") {
                NSApp.terminate(nil)
            }
        }
        .padding(.vertical, 5)
    }

    private var updatedLabel: String {
        switch appModel.state.accountConnection {
        case .notChecked, .checking:
            return "Checking GitHub CLI…"
        case .connectionRequired:
            return "Account connection required"
        case .selectionRequired:
            return "Choose monitored account"
        case .connected:
            break
        }
        if appModel.state.isRefreshing { return "Refreshing…" }
        guard let lastUpdatedAt = appModel.state.lastUpdatedAt else { return "Ready" }
        switch appModel.state.refreshHealth {
        case .restoredSnapshot:
            return "Snapshot \(lastUpdatedAt.formatted(.relative(presentation: .named)))"
        case .partial:
            return "Partial update · \(lastUpdatedAt.formatted(.relative(presentation: .named)))"
        case .failed:
            return "Refresh failed · \(lastUpdatedAt.formatted(.relative(presentation: .named)))"
        case .rateLimited:
            return "Rate limited · \(lastUpdatedAt.formatted(.relative(presentation: .named)))"
        case .idle, .fresh:
            return "Updated \(lastUpdatedAt.formatted(.relative(presentation: .named)))"
        }
    }

    private var updatedLabelColor: Color {
        switch appModel.state.refreshHealth {
        case .partial, .rateLimited:
            .orange
        case .failed:
            .red
        case .idle, .restoredSnapshot, .fresh:
            .secondary
        }
    }

    private var updatedLabelHelp: String {
        switch appModel.state.refreshHealth {
        case .idle, .fresh:
            "The active workload is up to date."
        case .restoredSnapshot:
            "Showing the saved Snapshot while GitHubBar reconciles in the background."
        case let .partial(message), let .failed(message):
            message
        case let .rateLimited(until):
            until.map { "GitHubBar will retry after \($0.formatted(date: .omitted, time: .shortened))." }
                ?? "GitHubBar will retry automatically."
        }
    }

    private var accountLabel: String {
        switch appModel.state.accountConnection {
        case let .connected(login, _):
            return "@\(login) ›"
        case .selectionRequired:
            return "GitHub.com ›"
        case .notChecked, .checking, .connectionRequired:
            return "GitHub CLI ›"
        }
    }

    private var isConnected: Bool {
        if case .connected = appModel.state.accountConnection { return true }
        return false
    }

    private var isInitialLoading: Bool {
        isConnected && appModel.state.isRefreshing && appModel.state.lastUpdatedAt == nil
    }

    private var showsRepositoryInRows: Bool {
        if appModel.state.repositoryScope == .pinned,
           appModel.state.pinnedRepositoryIDs.count == 1 {
            return false
        }
        return true
    }

}

private struct InitialWorkloadLoadingView: View {
    var body: some View {
        VStack(spacing: 9) {
            ProgressView()
                .controlSize(.small)
            Text("Loading your pull requests…")
                .font(.system(size: 11, weight: .medium))
            Text("GitHubBar will keep this workload available for instant launches after the first refresh.")
                .font(.system(size: 9.5))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 250)
        }
        .frame(maxWidth: .infinity, minHeight: 250)
        .accessibilityElement(children: .combine)
    }
}

private struct VisualEffectBackground: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .popover
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}

private struct AccessCoverageBanner: View {
    let accessCoverage: AccessCoverage

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle")
                .foregroundStyle(.yellow)
            VStack(alignment: .leading, spacing: 2) {
                Text("Incomplete access")
                    .font(.system(size: 10.5, weight: .semibold))
                Text(accessCoverage.summary ?? "Some organizations or repositories may not be visible.")
                    .font(.system(size: 9.5))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(9)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 7))
        .overlay {
            RoundedRectangle(cornerRadius: 7).stroke(Color.primary.opacity(0.12))
        }
        .padding(.top, 7)
        .accessibilityElement(children: .combine)
    }
}
