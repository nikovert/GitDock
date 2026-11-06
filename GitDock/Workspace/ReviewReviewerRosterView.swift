import GitDockCore
import SwiftUI

/// Shows individual submitted opinions separately from current review requests.
struct ReviewReviewerRosterView: View {
    let pullRequest: PullRequestPresentation

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Reviewers").workspaceFont(.caption.weight(.semibold))
            if pullRequest.reviewRoster.isEmpty {
                Text(pullRequest.reviewRosterIsComplete ? "No reviewers" : "Reviewer information unavailable")
                    .workspaceFont(.caption).foregroundStyle(.secondary)
            }
            ForEach(pullRequest.reviewRoster) { reviewer in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: symbol(for: reviewer))
                        .foregroundStyle(color(for: reviewer))
                        .accessibilityHidden(true)
                    Text(reviewer.kind == .team ? reviewer.displayName : "@\(reviewer.displayName)")
                        .workspaceFont(.caption).textSelection(.enabled)
                    Text(status(for: reviewer))
                        .workspaceFont(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if !pullRequest.reviewRosterIsComplete {
                Text("Reviewer information is incomplete. Refresh to confirm current outcomes.")
                    .workspaceFont(.caption).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func requested(_ reviewer: ReviewerPresentation) -> Bool {
        reviewer.isRequested == true
    }

    private func status(for reviewer: ReviewerPresentation) -> String {
        let opinion: String
        if reviewer.reviewState != nil && !reviewer.reviewStateIsComplete {
            opinion = "Outcome unconfirmed"
        } else {
            switch reviewer.reviewState {
            case .approved: opinion = "Approved"
            case .changesRequested: opinion = "Changes requested"
            case .dismissed: opinion = "Review dismissed"
            case nil: opinion = requested(reviewer) ? "Review requested" : "Request status unconfirmed"
            }
        }
        return reviewer.reviewState != nil && requested(reviewer) ? "\(opinion) · Review requested" : opinion
    }

    private func symbol(for reviewer: ReviewerPresentation) -> String {
        guard reviewer.reviewStateIsComplete else { return reviewer.kind == .team ? "person.2" : "person" }
        switch reviewer.reviewState {
        case .approved: return "checkmark.circle.fill"
        case .changesRequested: return "exclamationmark.bubble.fill"
        case .dismissed: return "minus.circle"
        case nil: return reviewer.kind == .team ? "person.2" : "person"
        }
    }

    private func color(for reviewer: ReviewerPresentation) -> Color {
        guard reviewer.reviewStateIsComplete else { return .secondary }
        switch reviewer.reviewState {
        case .approved: return .green
        case .changesRequested: return .orange
        case .dismissed, nil: return .secondary
        }
    }
}
