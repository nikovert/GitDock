# PR lifecycle and cleanup Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development or superpowers:executing-plans. Steps use checkbox syntax.

**Goal:** Keep active PRs current, show individual review outcomes, and implement the agreed automatic/manual cleanup workflow.

**Architecture:** Carry authoritative discovery and effective reviewer evidence through the core snapshot. Extend the existing cleanup coordinator with execution intent and external registration discovery. Add an independent stale-draft service with preview-bound explicit remote writes; app models integrate refresh scheduling, policy, progress and UI.

**Tech Stack:** Swift 6, SwiftUI/AppKit, Foundation, Git/tmux CLI, existing GitHub transports.

**Spec:** `docs/superpowers/specs/2026-11-05-pr-lifecycle-cleanup-design.md`

## Global Constraints

- macOS 14+, Swift 6, backward-compatible local data decoding.
- Automatic cleanup: merged only, registered managed assets only, no live session kills.
- Preserve local changes/extra commits, branch refs, notes and review drafts; never force deletion.
- External worktrees and remote draft closes require explicit selected preview approval.
- No live GitHub mutations or real user worktree removals in validation.
- Keep unrelated processes, sessions and terminal windows/tabs intact.

## Review Focus

- Partial refresh caused by unrelated metadata warnings must still remove known-finished PRs.
- Account/configuration changes or new live sessions during awaited work must prevent stale cleanup.
- External Git registrations and paths must not permit main checkout, symlink or foreign-repo removal.
- Dismissed/partial reviewer history must not produce false approval ticks.
- Draft changed after preview, failed or ambiguous remote writes must stay visible and not auto-retry.

### Task 1: Workload and reviewer evidence

**Files:** core Domain/WorkloadSnapshot.swift, Domain/PullRequestPresentation.swift,
GitHub/GraphQLGitHubWorkloadClient.swift, relevant core checks/tests; new app reviewer
roster component and ReviewDetailView.swift.

**Interfaces:** Preserve existing constructors with defaults. Add Codable evidence
for authoritative workload membership and individual effective review states with
completeness. Reviewer detail consumes the completed model; no cleanup dependencies.

- [x] Add failing partial-refresh and effective-opinion regression cases.
- [x] Implement authoritative disappearance/terminal-state eviction without deleting unconfirmed rows.
- [x] Carry approval/change-request/dismissal semantics and completeness; render full detail roster.
- [x] Verify core checks/tests and backward decoding; report evidence for independent review.

### Task 2: Core worktree discovery and cleanup intent

**Files:** LocalWorkspace/WorktreeCleanup.swift, WorktreeCleanupLocal.swift,
WorktreeCleanupGitHubClient.swift, new focused helpers/tests as needed.

**Interfaces:** Retain existing WorktreeCleanupServicing.preview/execute; add
WorktreeCleanupIntent (`automatic`, `manual`) and `execute(_:accountLogin:intent:)`
with backward-compatible default forwarding for existing fake services. Expose
candidate managed/manual provenance, live-session information, and explicit reasons.
Preview includes configured repositories' unlinked Git registrations. Manual cleanup
permits clean remote-backed external registrations and verified closed draft worktrees;
automatic remains managed+merged+no-live-session only, enforced again at execution.

- [x] Add failing discovery, automatic no-kill, session/head/config race and manual external tests.
- [x] Implement enumeration, fresh origin/head evidence and ordinary Git removal.
- [x] Preserve ownership boundaries and branches; extend GitHub state for closed-draft manual policy.
- [x] Run targeted core suite/checks and report verification plus exact public interfaces.

### Task 3: Explicit stale-draft close service and UI

**Files:** new core LocalWorkspace/StaleDraftCleanup.swift (and client/helper),
new app Workspace/StaleDraftCleanupModel.swift and StaleDraftCleanupView.swift,
new core/app fixture tests.

**Interfaces:** service previews the monitored account's scoped authored PR candidates
with a configurable default 30-day updatedAt cutoff, and closes an explicitly approved
preview only after fresh account/author/open/draft/head/date/permission checks. App view
accepts scoped workload plus account and an on-completion callback to refresh and offer
manual local cleanup. Keep remote branches. Coordinate exact constructor with root.

- [x] Add failing stale selection, freshness/account drift, permission, failure and ambiguous-write tests.
- [x] Implement explicit close controls, selection/confirmation, progress and retained results.
- [x] Confirm no automatic closing, no branch deletion, and test with fake transports only.
- [x] Run relevant tests and report exact app integration API.

### Task 4: App scheduling, cleanup UI and dashboard

**Files:** WorkspaceModel.swift, WorktreeCleanupModel.swift, WorktreeCleanupView.swift,
ReviewWorkspaceView.swift, app cleanup/lifecycle tests and rendering fixtures.

- [x] Add failing refresh deduplication, account/config cancellation, auto-versus-manual, activity persistence tests.
- [x] Schedule default-enabled automatic cleanup once per successful refreshedAt, never while manual work is active.
- [x] Expose policy switch, activity/reasons, external manual review and live-session approval.
- [x] Integrate stale-draft queue and manual cleanup after close; remove finished stack cards from active dashboard.
- [x] Show refresh completeness; verify app model and light/dark/minimum native rendering.

### Task 5: Review, verification and delivery

- [x] Independently review each implemented boundary and cross-component account/race semantics.
- [x] Run core/app/adapter suites and scripts/check.sh; document native host exclusions precisely.
- [ ] Update guides/screenshots; build universal next validation version and verify signatures/checksum.
- [ ] Fast-forward main, push, publish notes/ZIP/checksum, and provide a direct local ZIP link.
