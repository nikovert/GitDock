# Refresh and Worktree Cleanup Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox syntax for tracking.

**Goal:** Reliable manual refresh and explicitly confirmed cleanup of merged,
origin-synced managed worktrees, with bulk or individual session-stop choices.

**Architecture:** Keep refresh scheduling in WorkloadEngine. Add a core cleanup
coordinator with injected GitHub verification and command-running boundaries;
expose a preview/execute model through a dedicated SwiftUI sheet. Reuse account
resolution, workspace persistence, and agent lifecycle code.

**Tech Stack:** Swift, SwiftUI/AppKit, SwiftPM/XCTest, Git, existing GitHub transport.

**Spec:** `docs/superpowers/specs/2026-10-25-refresh-cleanup-design.md`

## Global Constraints

- Remain agent-agnostic; no new runtime dependencies or GitHub writes.
- Remove only confirmed, clean, origin-synced, GitDock-managed linked worktrees.
- No forced removal, recursive deletion, branch deletion, or automatic cleanup.
- Stop only sessions explicitly approved in the bulk or individual confirmation.
- Tests use temporary repositories and fake network boundaries, never user worktrees.

## Review Focus

- Squash merges and deleted source branches: compare to fetched PR head, not main.
- A dirty worktree or changed session set after preview: skip without stopping agents.
- A stack root merged while another member is open: block cleanup of the stack.
- Symlinks, duplicate links, locked/main worktrees: never broaden deletion targets.
- An account switch or refresh already in flight: no stale publication or lost request.

## Task 1: Reliable manual refresh

**Files:**
- Modify `Packages/GitDockCore/Sources/GitDockCore/Workload/WorkloadEngine.swift`.
- Extend `Packages/GitDockCore/Tests/GitDockCoreTests/WorkloadEngineTests.swift`.
- Extend app-level menu tests if action routing needs changes.

**Interfaces:** Preserve `WorkloadEngine.send(_:)` and existing presentation state.

- [x] Add suspended-client regression tests: manual refresh during an active request
  produces exactly one subsequent request, repeated clicks coalesce, automatic
  triggers do not erase it, and final published data comes from the second request.
- [x] Add disconnected-account and account-switch tests; assert selected identity
  is respected and the old account cannot publish after invalidation.
- [x] Run the focused suite and record the intended failure before implementation.
- [x] Update manual-trigger scheduling and connection recovery, keeping automatic
  refresh coalescing and rate-limit behavior intact.
- [x] Verify menu click and Command-R reach the same command, with visible progress
  and failure state; run core and affected app tests, then commit.

## Task 2: Safe core cleanup

**Files:**
- Create `Packages/GitDockCore/Sources/GitDockCore/LocalWorkspace/WorktreeCleanup.swift`.
- Create `Packages/GitDockCore/Sources/GitDockCore/LocalWorkspace/WorktreeCleanupGitHubClient.swift`.
- Modify `Packages/GitDockCore/Sources/GitDockCore/LocalWorkspace/AgentSessionManager.swift`.
- Create `Packages/GitDockCore/Tests/GitDockCoreTests/WorktreeCleanupTests.swift`.
- Extend `Packages/GitDockCore/Tests/GitDockCoreTests/AgentSessionSafetyTests.swift`.

**Interfaces:**
- `WorktreeCleanupCandidate`: Identifiable, Equatable, Sendable preview containing
  canonical path, all linked sessions, PR metadata, verified HEAD, and skip reason.
- `WorktreeCleanupResult`: removed/skipped/failed outcomes with messages per path.
- `WorktreeCleanupCoordinator.preview(accountLogin: String) async throws -> [WorktreeCleanupCandidate]`.
- `WorktreeCleanupCoordinator.execute(_ approved: [WorktreeCleanupCandidate], accountLogin: String) async -> [WorktreeCleanupResult]`.
- Inject a `WorktreeCleanupGitHubChecking` dependency for fresh PR/stack metadata;
  production implementation resolves the monitored account using existing auth.

- [x] Write temporary-repository tests for clean merged success, open/closed-unmerged
  refusal, local ahead/diverged HEAD, dirty/untracked/ignored files, squash merge,
  deleted source branch, fetch failure, wrong origin, main/locked/external worktrees,
  symlink escape, and complete versus incomplete/partially merged stacks.
- [x] Add stale-preview tests: changed HEAD, configuration, account, or session set
  must stop no sessions and remove nothing. Test multiple links to one worktree.
- [x] Add tests proving no stop on failed preflight, post-stop edits prevent removal,
  failures retain links, success preserves branch/history, and bulk results continue
  reporting independent failures. Cover concurrent launch/restart/cleanup exclusion.
- [x] Run the focused tests to demonstrate missing behavior before implementation.
- [x] Implement preview using fresh remote metadata and exact fetched-head equality;
  use a uniquely named temporary ref and remove only that ref with a SHA guard.
- [x] Implement serialized execution with pre-stop and pre-remove validation.
  Use ordinary Git worktree removal from the owning checkout; never `--force`.
- [x] Make existing single-worktree removal check safety before stopping a session
  and share the new validated removal boundary where appropriate.
- [x] Run the complete core suite and commit.

## Task 3: Confirmation, selection, and validation build

**Files:**
- Create `GitDock/Workspace/WorktreeCleanupModel.swift` and `WorktreeCleanupView.swift`.
- Modify `GitDock/Workspace/WorkspaceBoardView.swift`, `WorkspaceModel.swift`,
  and `GitDock/App/AppDelegate.swift` for wiring and board reload after removal.
- Create `GitDockTests/WorktreeCleanupModelTests.swift` and rendering tests.
- Update `docs/agent-workspace.md` and regenerate `GitDock.xcodeproj` with XcodeGen.

**Interfaces:** Main-actor observable model owns scan/preview/selection/execution
state and delegates to the coordinator. No Git commands or safety policy in views.

- [x] Write tests proving scan/cancel do not stop anything, bulk approval passes only
  eligible rows, selection starts empty, and individual execution passes only selected
  rows. Test disabled controls while busy, stale account/configuration, retryable
  failures, and successful board reload without losing notes or review history.
- [x] Run tests red, then implement the sheet with the exact choices in the spec.
  Render PR title/number/repository, path, agents, live states, and skip reasons.
- [x] Render and inspect both light/dark appearances with fake data; no real deletion.
- [x] Run all core tests, all app tests, `scripts/check.sh`, and `git diff --check`.
  Use `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer` for Swift/Xcode.
- [x] Obtain an independent safety review, resolve findings with regression tests,
  and repeat affected verification before committing.
- [x] Package a universal validation ZIP using `scripts/package-validation.sh`;
  verify signatures, architectures, checksum, and document installation instructions.
  Do not merge, publish, install, or clean live worktrees without separate approval.
