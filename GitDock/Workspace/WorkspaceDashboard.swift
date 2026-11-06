import GitDockCore

struct WorkspaceDashboardMember: Identifiable {
    let pullRequest: PullRequestPresentation
    let isNavigationContext: Bool
    var id: String { pullRequest.url.absoluteString }
}
struct WorkspaceDashboardGroup: Identifiable {
    let id: String
    let stack: PullRequestStack?
    let members: [WorkspaceDashboardMember]
}

enum WorkspaceDashboard {
    static func active(_ workload: [PullRequestPresentation]) -> [PullRequestPresentation] {
        var seen = Set<String>()
        return workload.filter { $0.state == .open && seen.insert($0.url.absoluteString).inserted }
    }

    static func groups(visible: [PullRequestPresentation], stacks: [PullRequestStack]) -> [WorkspaceDashboardGroup] {
        let visible = active(visible)
        let byURL = Dictionary(uniqueKeysWithValues: visible.map { ($0.url, $0) })
        var assigned = Set<String>()
        var stackGroups: [String: WorkspaceDashboardGroup] = [:]
        for stack in stacks {
            guard stack.pullRequests.contains(where: { byURL[$0.url] != nil }) else { continue }
            let id = "stack:\(stack.pullRequests.first?.repositoryNameWithOwner ?? ""):\(stack.id)"
            var seen = Set<String>()
            let members = stack.pullRequests.sorted {
                ($0.stackMembership?.position ?? Int.max, $0.number) < ($1.stackMembership?.position ?? Int.max, $1.number)
            }.compactMap { member -> WorkspaceDashboardMember? in
                let url = member.url.absoluteString
                guard seen.insert(url).inserted, !assigned.contains(url) else { return nil }
                assigned.insert(url)
                return WorkspaceDashboardMember(pullRequest: byURL[member.url] ?? member,
                    isNavigationContext: byURL[member.url] == nil)
            }
            stackGroups[id] = WorkspaceDashboardGroup(id: id, stack: stack, members: members)
        }
        var emitted = Set<String>()
        return visible.compactMap { pr in
            if let group = stackGroups.values.first(where: { $0.members.contains { $0.pullRequest.url == pr.url } }) {
                return emitted.insert(group.id).inserted ? group : nil
            }
            let id = pr.url.absoluteString
            return emitted.insert(id).inserted ? WorkspaceDashboardGroup(id: id, stack: nil,
                members: [WorkspaceDashboardMember(pullRequest: pr, isNavigationContext: false)]) : nil
        }
    }
}
