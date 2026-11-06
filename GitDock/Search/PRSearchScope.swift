import Foundation
import GitDockCore

enum PRSearchScope {
    static func accountLogin(in state: AppPresentationState) -> String? {
        guard case let .connected(login, _) = state.accountConnection else { return nil }
        return login
    }

    static func defaultRepositories(in state: AppPresentationState) -> [String] {
        guard accountLogin(in: state) != nil else { return [] }
        let names = state.repositoryScope == .pinned
            ? state.pinnedRepositories.map(\.nameWithOwner)
            : state.availableRepositories.map(\.nameWithOwner)
        return Set(names.compactMap(normalizedRepository)).sorted()
    }

    static func activePullRequests(in state: AppPresentationState) -> [PullRequestPresentation] {
        guard accountLogin(in: state) != nil else { return [] }
        var seen: Set<String> = []
        return (state.needsYourReview + state.authoredPullRequests).filter {
            seen.insert("\($0.repositoryID)#\($0.number)").inserted
        }
    }

    static func normalizedRepository(_ input: String) -> String? {
        let value = input.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let parts = value.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2, parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }),
              parts[0].allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }),
              parts[1].allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || "-_.".contains($0)) })
        else { return nil }
        return value
    }
}
