# PR lifecycle, reviewer status, and cleanup

The user approved the decisions below through fourteen grilling questions. Implement
and verify the app changes, then deliver an updated build. These decisions replace
the old manual-only merged-worktree cleanup policy.

## Dashboard and reviewers

Successful authoritative open-PR discovery must remove PRs absent from that workload
even when unrelated hydration/roster/catalog warnings make the refresh partial.
Fresh merged/closed evidence must evict stale open entries. Incomplete discovery must
still retain unconfirmed rows. Keep account/host boundaries and cache compatibility.
Merged/closed stack members are navigation history, not active dashboard PR cards;
retain their links in stack/PR details. Surface partial refresh information.

PR detail must list all requested people/teams plus completed review participants.
Approved people show a green tick, changes requested has its own status, outstanding
requests remain visible. Use effective review history rather than guessing from
absence of a request. Dismissed opinions and incomplete data must not create false
ticks. Teams remain team requests; do not infer team approval from a member.

## Automatic merged cleanup

After each successful GitHub refresh, automatically inspect registered managed
worktrees. Remove only verified merged PR worktrees (all stack members merged where
applicable), matching the current remote PR head, with no local changes/extra commits,
live sessions or other detected local processes. Clean stopped/failed links too.
Current tmux state cannot prove an agent is idle, so every live session requires
explicit manual approval. Revalidate account, configuration, ownership, registration,
Git head, cleanliness and session identities immediately before destructive steps.
Never force deletion. Keep branch refs, notes and draft/review history.

Expose an automatic-cleanup switch, default enabled for this user-approved behaviour.
Deduplicate refresh triggers; avoid overlapping auto/manual operations and stale tasks
after account/configuration changes. Report removed/retained/failed items and reasons
without modal prompts on every refresh. Persist enough activity to inspect results.
No process/session stopping in automatic mode, including newly appeared sessions.

## Other worktrees and manual sessions

Enumerate Git-registered worktrees of configured repository checkouts, including
paths outside the app's managed root. Show other worktrees for manual approval only;
never make them managed implicitly or stop unrelated sessions. Exclude main/bare,
locked/prunable, symlink-confused, foreign-repository and otherwise unsafe paths.
For a worktree without an identifiable PR, manual removal requires clean contents
and commits verified on a remote branch. Retain its local branch. Recheck all evidence
against the selected preview before removal. Unverifiable work stays flagged.

Explicit manual approval can stop verified app-owned tmux sessions. Remove their
GitDock links after successful worktree removal. Leave terminal windows/tabs alone.
If another local process prevents removal, show that reason; preserve unrelated work.

## Old drafts on GitHub

Provide an old-draft queue for the monitored account's own open drafts under current
repository scope. Flag after 30 days without activity; use GitHub updatedAt including
automation and display that date. Allow a configurable positive day threshold.
Require explicit item selection and confirmation before closing PRs on GitHub.
Recheck account, owner, draft/open state, updatedAt, head and cutoff before closing.
Reject changed/stale candidates; report individual progress/errors. Do not retry
ambiguous writes automatically. Keep remote branches and all local data.
After closing a draft, offer its local worktree for manual cleanup; automatic
cleanup remains merged-only. No live PR closes or real user worktree deletion are
part of validation; exercise mutations with controlled fixtures.

## Delivery and constraints

Keep SwiftUI/AppKit, macOS 14+, Swift 6, local data compatibility, explicit GitHub
write controls, and existing provider protocol. Use existing core transports and
session ownership checks. Validate core/app suites and repository checks; inspect
light/dark and minimum/large native layouts. Report native test-host limitations.
Publish the next universal validation build and provide a direct local ZIP link.
