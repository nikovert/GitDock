import GitHubBarCore
import SwiftUI

struct ReviewDetailView: View {
    @Bindable var review: ReviewWorkspaceModel
    @Bindable var workspace: WorkspaceModel
    let pullRequest: PullRequestPresentation?
    let stacks: [PullRequestStack]
    @Bindable var layout: WorkspaceLayout
    @State private var submissionTarget: ReviewSubmissionTarget?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let subject = workspace.selectedSubject {
                header(subject)
                Picker("PR detail", selection: $review.tab) {
                    ForEach(ReviewWorkspaceTab.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }.pickerStyle(.segmented).labelsHidden().padding(.horizontal, 20).padding(.bottom, 14)
                Divider()
                if review.tab == .workspace {
                    WorkspaceDetailView(workspace: workspace, subject: subject,
                        stackRoot: subject.isStack ? nil : stacks.first { $0.pullRequests.contains { $0.url == subject.key.url } }?
                            .root.flatMap { try? PullRequestKey(url: $0.url) },
                        details: BoardSubjectDetails.resolve(subject: subject,
                            pullRequests: pullRequest.map { [$0] } ?? [], stacks: stacks))
                        .id(subject)
                } else if review.loading {
                    VStack(spacing: 12) { ProgressView(); Text("Loading PR, changes, and discussion…").foregroundStyle(.secondary) }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let snapshot = review.snapshot {
                    switch review.tab {
                    case .overview: overview(snapshot)
                    case .changes: ReviewDiffView(review: review, layout: layout)
                    case .threads: threads(snapshot)
                    case .workspace: EmptyView()
                    }
                } else {
                    ContentUnavailableView("PR details unavailable", systemImage: "network",
                        description: Text("Connect GitHub in Settings or refresh to retry."))
                    Button("Retry") { review.refresh() }.padding()
                }
                footer
            } else {
                ContentUnavailableView("Choose a pull request", systemImage: "arrow.triangle.pull",
                    description: Text("Select a PR from your queues to read its code, review, or ask an agent."))
            }
        }
        .sheet(item: $submissionTarget) { target in ReviewSubmissionView(review: review, target: target) }
    }

    private func header(_ subject: BoardSubject) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Link(subject.key.description, destination: subject.key.url).font(.caption)
                Spacer()
                if let identity = review.identity {
                    Button {
                        review.local.setPinned(!review.local.isPinned(identity), for: identity)
                    } label: { Image(systemName: review.local.isPinned(identity) ? "pin.fill" : "pin") }
                    .help("Pin this PR")
                }
                Link(destination: subject.key.url) { Image(systemName: "arrow.up.right.square") }
                    .help("Open PR on GitHub")
            }
            Text(review.snapshot?.title ?? pullRequest?.title ?? subject.key.description)
                .font(.title2.weight(.semibold)).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 10) {
                Text("@\(review.snapshot?.author ?? pullRequest?.author?.displayName ?? "unknown")")
                if let created = review.snapshot?.createdAt ?? pullRequest?.createdAt {
                    Text("Opened \(created, style: .relative) ago")
                }
                if subject.isStack { Text("Stack root") }
            }.font(.caption).foregroundStyle(.secondary)
            if let pr = pullRequest {
                HStack {
                    Text(pr.reviewDecision?.rawValue.replacingOccurrences(of: "_", with: " ").capitalized ?? (pr.isDraft ? "Draft" : "Awaiting review"))
                        .font(.caption).padding(.horizontal, 8).padding(.vertical, 4)
                        .background(Color.accentColor.opacity(0.1), in: RoundedRectangle(cornerRadius: 5))
                    Text("Reviewers: \(requestedReviewerSummary(for: pr))")
                        .font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
            }
            if let snapshot = review.snapshot {
                Text(snapshot.checksSummary).font(.caption).foregroundStyle(.secondary)
            }
            ReviewAgentActionsView(review: review, workspace: workspace,
                allowsActions: !subject.isStack && pullRequest?.state != .closed && pullRequest?.state != .merged)
        }.padding(20)
    }

    private func overview(_ snapshot: PRReviewSnapshot) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                if let pr = pullRequest {
                    let priority = workspace.reviewPriority(for: workspace.reviewContext(for: pr))
                    GroupBox {
                        HStack(alignment: .top) {
                            Image(systemName: "flag.fill").foregroundStyle(.orange)
                            VStack(alignment: .leading, spacing: 4) {
                                Text("\(priority.label) priority").font(.headline)
                                Text(priority.reason).foregroundStyle(.secondary)
                            }
                            Spacer()
                        }.padding(7)
                    }
                }
                Text("Description").font(.headline)
                Text(snapshot.body.isEmpty ? "No description provided." : snapshot.body)
                    .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                if !snapshot.notices.isEmpty {
                    ForEach(snapshot.notices, id: \.self) { Text($0).font(.caption).foregroundStyle(.secondary) }
                }
                if let identity = review.identity {
                    let older = review.local.previousDraftIdentities(identity)
                    if !older.isEmpty {
                        DisclosureGroup("Drafts retained from earlier diffs (\(older.count))") {
                            ForEach(older, id: \.self) { oldIdentity in
                                let draft = review.local.draft(for: oldIdentity)
                                VStack(alignment: .leading, spacing: 5) {
                                    Text("Commit \(oldIdentity.headSHA.prefix(8)) · Base \(oldIdentity.baseSHA.isEmpty ? "unrecorded" : String(oldIdentity.baseSHA.prefix(8)))").font(.caption.bold())
                                    Text(draft.body).textSelection(.enabled)
                                    ForEach(draft.comments) { comment in
                                        Text("\(comment.path):\(comment.line) · \(comment.body)").textSelection(.enabled)
                                    }
                                    ForEach(draft.generalComments) { comment in Text(comment.body).textSelection(.enabled) }
                                }.padding(.vertical, 8)
                            }
                        }
                    }
                }
                Text("Notes, tags, stacks, and pinned terminal sessions are available in Workspace.")
                    .font(.caption).foregroundStyle(.secondary)
            }.padding(20)
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func threads(_ snapshot: PRReviewSnapshot) -> some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 16) {
                HStack {
                    Text("Your local drafts (\(review.draft.allDraftCount))").font(.headline)
                    Spacer()
                    if review.draft.hasUnsubmittedComments { Button("Publish all…") { openSubmission() }.controlSize(.small).disabled(review.submitting || !review.local.canSave) }
                }
                if let last = review.draft.lastAgentReview {
                    Text(last.coverageLabel).font(.subheadline.weight(.medium))
                        .foregroundStyle(last.coverage == nil || last.contextIncomplete ? Color.orange : Color.secondary)
                    DisclosureGroup("Latest \(last.provider) review · \(last.findingCount) findings") {
                        Text(last.completedAt, style: .relative).font(.caption).foregroundStyle(.secondary)
                        AgentMarkdownView(text: last.summary)
                        ReviewCoverageSummary(receipt: last, headSHA: snapshot.headSHA, baseSHA: snapshot.baseSHA)
                    }
                }
                if review.draft.allDraftCount == 0 { Text("No local draft comments.").foregroundStyle(.secondary) }
                ForEach(review.draft.generalComments) { comment in
                    ReviewGeneralDraftCard(review: review, draftID: comment.id)
                }
                ForEach(review.draft.comments) { comment in
                    ReviewInlineDraftCard(review: review, draftID: comment.id)
                }
                let threads = snapshot.threads
                Text("Inline discussions").font(.headline).padding(.top, 6)
                if !threads.contains(where: \.isInline) { Text("No inline discussions available.").foregroundStyle(.secondary) }
                ForEach(threads.filter(\.isInline)) { thread in ReviewConversationCard(review: review, thread: thread) }
                Text("General PR discussion").font(.headline).padding(.top, 6)
                if !threads.contains(where: { !$0.isInline }) { Text("No general discussion available.").foregroundStyle(.secondary) }
                ForEach(threads.filter { !$0.isInline }) { thread in ReviewConversationCard(review: review, thread: thread) }
            }.padding(20).frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 6) {
            Divider()
            if let notice = review.submissionMessage ?? review.notice { Text(notice).font(.caption).foregroundStyle(.secondary).padding(.horizontal, 16) }
            HStack {
                Text("\(review.draft.comments.count) inline · \(review.draft.generalComments.count) general drafts · Saved locally")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                if review.submitting { ProgressView().controlSize(.small) }
                Button("Mark reviewed") { review.markReviewed() }
                    .disabled(review.snapshot == nil || review.submitting || !review.local.canSave)
                Button(review.draft.hasUnsubmittedComments ? "Publish all drafts…" : "Submit review…") { openSubmission() }
                    .buttonStyle(.borderedProminent)
                    .disabled(review.snapshot == nil || review.sinceLastReview || review.submitting || !review.local.canSave)
            }.padding(12)
        }
    }
    private func openSubmission() {
        if let identity = review.identity, let snapshot = review.snapshot {
            submissionTarget = ReviewSubmissionTarget(identity: identity, title: snapshot.title,
                ownPR: snapshot.author.lowercased() == identity.account.lowercased())
        }
    }

}

struct ReviewSubmissionTarget: Identifiable {
    let identity: ReviewIdentity
    let title: String
    let ownPR: Bool
    var id: String { identity.revisionKey }
}

struct ReviewSubmissionView: View {
    @Bindable var review: ReviewWorkspaceModel
    let target: ReviewSubmissionTarget
    @State private var event = "COMMENT"
    @Environment(\.dismiss) private var dismiss
    private var valid: Bool { review.identity == target.identity && review.local.canSave }
    private var publicationPlan: [ReviewPublicationBatch]? {
        guard let choice = PRReviewEvent(rawValue: event) else { return nil }
        return try? ReviewPublicationPlan.make(draft: draft, event: choice)
    }
    private var publicationError: String? {
        guard let choice = PRReviewEvent(rawValue: event) else { return nil }
        do { _ = try ReviewPublicationPlan.make(draft: draft, event: choice); return nil }
        catch { return error.localizedDescription }
    }
    private var canSubmit: Bool { valid && !review.submitting && publicationPlan != nil }
    private var draft: WorkspaceReviewDraft { review.local.draft(for: target.identity) }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Submit review to GitHub").font(.title2.bold())
            Text(target.title).font(.headline)
            Text("\(draft.comments.count) inline · \(draft.generalComments.count) general comments · @\(target.identity.account) · Commit \(target.identity.headSHA.prefix(8))")
                .foregroundStyle(.secondary)
            if !valid {
                Text("The PR, account, or diff changed. Cancel and reopen this sheet after reviewing the current changes. Your original draft is retained.")
                    .foregroundStyle(.orange)
            }
            MultilineComposer(text: Binding(get: { draft.body }, set: { value in if valid { review.editDraft { $0.body = value } } }),
                placeholder: "Review summary", isEnabled: canSubmit, actionLabel: "Post to GitHub", allowsEmpty: true) { post() }
                .frame(height: 150).disabled(!valid)
            if !draft.generalComments.isEmpty {
                DisclosureGroup("General draft comments included in this review (\(draft.generalComments.count))") {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 10) {
                            ForEach(draft.generalComments) { comment in AgentMarkdownView(text: comment.publicationBody); Divider() }
                        }
                    }.frame(maxHeight: 160)
                }
            }
            Picker("Review decision", selection: $event) {
                Text("Comment").tag("COMMENT")
                if !target.ownPR { Text("Approve").tag("APPROVE"); Text("Request changes").tag("REQUEST_CHANGES") }
            }.pickerStyle(.radioGroup)
            if let plan = publicationPlan, plan.count > 1 {
                Text("GitHub's size limits require \(plan.count) review posts. The selected decision and summary are posted last. Confirmed parts are saved separately; a failed part stops further publication.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let publicationError { Text(publicationError).font(.caption).foregroundStyle(.orange) }
            Text("This posts your review and all included drafts to GitHub as your monitored account.")
                .font(.caption).foregroundStyle(.secondary)
            if event == "REQUEST_CHANGES" {
                Text("Request changes requires a summary above.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let status = review.submissionMessage {
                HStack { if review.submitting { ProgressView().controlSize(.small) }; Text(status).font(.caption).textSelection(.enabled) }
            }
            HStack {
                Button(review.submitting ? "Close" : "Done") { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("Post to GitHub") { post() }.buttonStyle(.borderedProminent).disabled(!canSubmit)
            }
        }.padding(24).frame(width: 560)
    }
    private func post() {
        if canSubmit, let choice = PRReviewEvent(rawValue: event) { review.submit(event: choice, target: target.identity) }
    }
}

private struct ReviewCoverageSummary: View {
    let receipt: WorkspaceAgentReviewReceipt
    let headSHA: String
    let baseSHA: String

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let coverage = receipt.coverage {
                Text("Coverage is reported by the agent. Reviewing every file does not prove the PR is defect-free.")
                    .font(.caption).foregroundStyle(.secondary)
                Text("Head \(headSHA.prefix(12)) · Base \(baseSHA.prefix(12)) · Merge base \((receipt.mergeBaseSHA ?? baseSHA).prefix(12))")
                    .font(.caption.monospaced()).textSelection(.enabled)
                Text("Test execution was not requested. The agent reported no tests run.")
                    .font(.caption).foregroundStyle(.secondary)
                DisclosureGroup("Files reported reviewed (\(coverage.reviewedPaths.count))") {
                    ForEach(coverage.reviewedPaths, id: \.self) { path in
                        Text(path).font(.caption.monospaced()).textSelection(.enabled)
                    }
                }
                if !coverage.unreviewed.isEmpty {
                    Text("Files not reviewed (\(coverage.unreviewed.count))").font(.subheadline.bold()).foregroundStyle(.orange)
                    ForEach(coverage.unreviewed, id: \.path) { file in
                        VStack(alignment: .leading, spacing: 3) {
                            Text(file.path).font(.caption.monospaced())
                            Text(file.reason).font(.caption).foregroundStyle(.secondary)
                        }.textSelection(.enabled)
                    }
                }
                if !coverage.limitations.isEmpty {
                    Text("Reported limitations").font(.subheadline.bold()).foregroundStyle(.orange)
                    ForEach(coverage.limitations, id: \.self) { value in Text(value).font(.caption).textSelection(.enabled) }
                }
            } else {
                Text("This historical review used patch excerpts. Full-file coverage was not recorded; an empty findings list is not a whole-PR review.")
                    .font(.caption).foregroundStyle(.orange)
            }
            if let notices = receipt.sourceNotices, !notices.isEmpty {
                DisclosureGroup("Additional GitHub API context notices") {
                    ForEach(notices, id: \.self) { value in Text(value).font(.caption).foregroundStyle(.secondary) }
                }
            }
        }.frame(maxWidth: .infinity, alignment: .leading).padding(.top, 8)
    }
}
