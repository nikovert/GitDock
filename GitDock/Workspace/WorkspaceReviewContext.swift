import Foundation
import GitDockCore

enum WorkspaceReviewContext {
    static func make(
        _ pullRequest: PullRequestPresentation, accountLogin: String, stackURL: String?
    ) -> AgentPRContext {
        let requested = pullRequest.requestedReviewers ?? []
        return AgentPRContext(
            prURL: (try? PullRequestKey(url: pullRequest.url))?.url.absoluteString
                ?? pullRequest.url.absoluteString,
            title: pullRequest.title,
            authorLogin: pullRequest.author?.displayName ?? "",
            accountLogin: accountLogin,
            headSHA: pullRequest.headSHA ?? "",
            updatedAt: pullRequest.updatedAt,
            requestedHumans: requested.filter { $0.kind == .person }.map(\.displayName),
            requestedTeamCount: requested.filter { $0.kind == .team }.count,
            reviewersComplete: pullRequest.requestedReviewers != nil,
            stackURL: stackURL.flatMap(URL.init(string:))
                .flatMap { try? PullRequestKey(url: $0) }?.url.absoluteString
        )
    }

    static func contexts(in state: AppPresentationState) -> [String: AgentPRContext] {
        guard case let .connected(login, _) = state.accountConnection else { return [:] }
        var roots: [String: String] = [:]
        for stack in state.pullRequestStacks {
            for member in stack.pullRequests { roots[member.id] = stack.root?.url.absoluteString }
        }
        var result: [String: AgentPRContext] = [:]
        // Workload details take precedence over stack navigation snapshots.
        for pullRequest in state.pullRequestStacks.flatMap(\.pullRequests) +
            state.needsYourReview + state.authoredPullRequests {
            let context = make(
                pullRequest, accountLogin: login, stackURL: roots[pullRequest.id]
            )
            result[context.prURL] = context
        }
        return result
    }

    static func precedes(
        _ lhs: AgentPRContext, _ rhs: AgentPRContext, in document: LocalWorkspaceDocument,
        priorityAuthors: [String] = []
    ) -> Bool {
        let left = lhs.priority(in: document, priorityAuthors: priorityAuthors).rank
        let right = rhs.priority(in: document, priorityAuthors: priorityAuthors).rank
        if left != right { return left > right }
        if lhs.updatedAt != rhs.updatedAt { return lhs.updatedAt < rhs.updatedAt }
        return lhs.prURL < rhs.prURL
    }

    static func shouldSync(_ incoming: AgentPRContext, replacing existing: AgentPRContext?) -> Bool {
        guard let existing else { return true }
        return incoming != existing && incoming.updatedAt >= existing.updatedAt
    }

    static func status(_ job: AgentReviewJob, currentSHA: String) -> String {
        let status = job.status.rawValue.capitalized
        return !currentSHA.isEmpty && job.headSHA != currentSHA
            ? "\(status) · Stale — new commits" : status
    }
}
