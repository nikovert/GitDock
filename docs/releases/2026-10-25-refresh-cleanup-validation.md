# Refresh and merged-worktree cleanup validation

The v0.5.0 validation build contains reliable manual refresh and explicitly confirmed
cleanup of merged, origin-synced, GitDock-managed worktrees. Build source commit:
`22954b16a6ee` on `feature/refresh-worktree-cleanup` (base `f96b72a`).

## Behavior

- Refresh during an active request queues one follow-up; repeated clicks coalesce.
  Disconnected accounts are rechecked. Partial rate-limited results preserve one
  pending manual refresh until GitHub's reset deadline.
- The Workspace Board has a cleanup scan with PR titles, repositories, local paths,
  attached agent sessions, and reasons why a worktree cannot be removed.
- Choose **Stop and close all eligible worktrees** or **Review individually**.
  Individual selection starts empty. Scanning and canceling perform no session stop
  or worktree removal.
- Cleanup checks current PR/stack state, fetches the PR head from origin, and requires
  exact local HEAD equality. Local changes, ignored files, uncertain ownership, and
  unexpected sessions block cleanup. Session identity includes tmux server lifetime.
- Removal preserves local branches, notes, priorities, tags, and review history.

## Verification

After the independent safety review and regression fixes:

- Core XCTest suite: **110 tests, zero failures**.
- App XCTest suite: **37 tests, zero failures**.
- `scripts/check.sh`: core checks, strict Swift concurrency typechecking, avatar cache,
  menu sizing, plist validation, and XcodeGen all passed.
- `git diff --check` passed. Both light and dark cleanup previews were inspected.
- Universal app and CLI contain `arm64` and `x86_64`; strict ad-hoc signature checks,
  plist validation, ZIP integrity, and checksum verification passed. The bundled CLI
  loaded an empty workspace from an isolated temporary directory successfully.
- Real temporary Git repositories exercise removal, squash merges, deleted source
  branches, dirty/ignored files, locks, symlinks, stale approvals, failed fetches,
  changed sessions, and writes during session shutdown. No user worktrees were removed.

The independent reviewer found four Important issues, all reproduced before fixing:
current stack membership for ordinary PR links; the full remaining session set before
each stop; tmux server restarts reusing session IDs; and partial rate-limit refresh
bypass. The first three regressions failed with five assertions, then all 16 cleanup
tests passed. The rate-limit regression failed with premature request counts, then
all ten workload-engine tests passed. No Critical or Minor findings were reported.

## Implementation decisions and limitations

1. Split local Git/tmux checks into `WorktreeCleanupLocal.swift` to keep orchestration
   readable. Cost: one additional internal file to maintain.
2. Check same-user process working directories with `lsof` after stopping sessions.
   Cost: an exiting process may require a fresh scan before removal can proceed.
3. Wire through the existing `WorkspaceModel` rather than changing `AppDelegate`.
   Cost if wrong: a missed lifecycle transition; account/configuration invalidation
   is covered by model tests.
4. Independent filesystem writers cannot be atomically excluded. Keep pre/post-stop
   checks and document the limit. Cost: external edits can race removal; avoid editing
   during cleanup.
5. Preserve automatic refresh cadence and existing standalone session-removal behavior
   beyond the requested preflight ordering fix. Cost: their existing limitations
   remain outside this bulk-cleanup/manual-refresh audit. Retry sleeps now respect
   known reset deadlines even when more than 30 minutes away.
6. Stack API behavior is covered by transport fixtures; the live read-only probe used
   a merged PR without a stack. Cost: non-null live stack behavior is not independently
   confirmed; incomplete or unverifiable metadata blocks cleanup. Packaging is checked
   locally, and the validation build remains ad-hoc signed and unnotarized.

Deferred minors: none.

## Install and try

The ZIP and checksum are produced locally; this work does not publish a GitHub release.
Artifact: `GitHubBar-validation-0.5.0-22954b16a6ee.zip`.
SHA-256: `30a87438177490632a14198bddaead414c4c4d909e3358990d9d6150080e0644`.

Quit the installed app, unzip the validation build, and replace `GitDock.app` in
`/Applications`. Reopen it and use the Workspace Board's **Refresh** button, then
**Clean up merged worktrees…** to inspect the preview. Review individual entries
before approving any removal. See [validation installation notes](validation-release.md)
for the expected macOS signing prompt.

This branch has not been merged, pushed, or installed automatically.
