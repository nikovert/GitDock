import Foundation

public struct BoardSubjectDetails: Sendable {
    public let primary: PullRequestPresentation
    public let members: [PullRequestPresentation]

    public static func resolve(
        subject: BoardSubject,
        pullRequests: [PullRequestPresentation],
        stacks: [PullRequestStack]
    ) -> BoardSubjectDetails? {
        switch subject {
        case let .pullRequest(key):
            let candidates = pullRequests + stacks.flatMap(\.pullRequests)
            guard let pullRequest = candidates.first(where: {
                (try? PullRequestKey(url: $0.url)) == key
            }) else { return nil }
            return BoardSubjectDetails(primary: pullRequest, members: [])
        case let .stack(key):
            guard let stack = stacks.first(where: {
                $0.root.flatMap { try? PullRequestKey(url: $0.url) } == key
            }), let root = stack.root else { return nil }
            return BoardSubjectDetails(primary: root, members: stack.pullRequests)
        }
    }
}
