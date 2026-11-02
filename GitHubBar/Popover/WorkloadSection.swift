import GitHubBarCore
import SwiftUI

struct WorkloadSection: View {
    let title: String
    let pullRequests: [PullRequestPresentation]
    let emptyMessage: String
    let showsRepository: Bool
    var showsBottomDivider = true
    var stacks: [PullRequestStack] = []
    var actions: AppActions = AppActions()
    var workspaceModel: WorkspaceModel? = nil
    @State private var expandedStacks: Set<String> = []

    var body: some View {
        LazyVStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .firstTextBaseline) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .accessibilityAddTraits(.isHeader)
                Spacer()
                Text(pullRequests.count.formatted())
                    .font(.system(size: 9.5))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            .padding(.bottom, pullRequests.isEmpty ? 1 : 3)

            if pullRequests.isEmpty {
                Text(emptyMessage)
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .padding(.vertical, 2)
            } else {
                ForEach(entries) { entry in
                    row(entry.pullRequest)
                    if let stack = entry.stack {
                        DisclosureGroup(isExpanded: Binding(
                            get: { expandedStacks.contains(stack.id) },
                            set: { if $0 { expandedStacks.insert(stack.id) } else { expandedStacks.remove(stack.id) } }
                        )) {
                            VStack(alignment: .leading, spacing: 8) {
                                ForEach(stack.pullRequests) { row($0) }
                                if let root = stack.root, let key = try? PullRequestKey(url: root.url) {
                                    Button("Workspace for stack…") { actions.openWorkspace(.stack(key)) }
                                        .buttonStyle(.plain)
                                    if let workspaceModel {
                                        ForEach(workspaceModel.document.sessions(for: .stack(key)).filter { $0.state == .running }) { session in
                                            Button("Jump to \(session.agent.rawValue.capitalized) session") { workspaceModel.focus(session) }
                                                .buttonStyle(.plain)
                                        }
                                    }
                                }
                                if let url = stack.navigationURL {
                                    Button("View stack on GitHub ↗") { actions.openGitHub(url) }.buttonStyle(.plain)
                                }
                            }.padding(.vertical, 5)
                        } label: {
                            Text("Stack #\(stack.number) · \(stack.size) pull requests")
                                .foregroundStyle(.secondary)
                        }
                        .font(.system(size: 10))
                    }
                }
            }
        }
        .padding(.vertical, pullRequests.isEmpty ? 8 : 11)
        .overlay(alignment: .bottom) { if showsBottomDivider { Divider() } }
        .accessibilityElement(children: .contain)
    }

    private func row(_ pullRequest: PullRequestPresentation) -> some View {
        PullRequestRow(pullRequest: pullRequest, showsRepository: showsRepository, actions: actions, workspaceModel: workspaceModel)
    }

    var entries: [PopoverWorkloadEntry] {
        Self.entries(pullRequests: pullRequests, stacks: stacks)
    }

    static func entries(pullRequests: [PullRequestPresentation], stacks: [PullRequestStack]) -> [PopoverWorkloadEntry] {
        var representedStacks: Set<String> = []
        return pullRequests.compactMap { pullRequest in
            guard let stack = stacks.first(where: { $0.pullRequests.contains { $0.id == pullRequest.id } }) else {
                return PopoverWorkloadEntry(pullRequest: pullRequest, stack: nil)
            }
            guard representedStacks.insert(stack.id).inserted else { return nil }
            return PopoverWorkloadEntry(pullRequest: pullRequest, stack: stack)
        }
    }
}

struct PopoverWorkloadEntry: Identifiable {
    let pullRequest: PullRequestPresentation
    let stack: PullRequestStack?
    var id: String { stack.map { "stack:\($0.id)" } ?? "pr:\(pullRequest.id)" }
}
