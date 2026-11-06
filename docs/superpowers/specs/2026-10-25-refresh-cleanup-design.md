# Refresh and merged-worktree cleanup

## Intent

Make manual refresh reliable and let the user remove finished local work without
losing changes or terminating agent sessions without consent.

Approved conversation: refresh must work; cleanup targets worktrees synced with
origin whose PRs have merged. Attached sessions require a choice between stopping
and closing all eligible worktrees and reviewing a list to select individual ones.

## Refresh

Manual refresh during reconciliation schedules one follow-up reconciliation, not
one per click. Automatic triggers do not overwrite that explicit request. Account
changes invalidate old results as before. A disconnected account gets a fresh
connection check rather than a silent no-op. Show progress and failures truthfully.
Do not change the automatic cadence or bypass GitHub rate-limit protection.

## Cleanup interaction

Add **Clean up merged worktrees…** to the Workspace Board. It scans stored session
links, including those whose PRs have disappeared from the open workload.

The initial preview offers **Stop and close all eligible worktrees**, **Review
individually**, and **Cancel**. The first action is explicit destructive confirmation.
Review individually shows selectable worktrees, PR titles/numbers, repositories,
paths, linked agent names, live session state, and eligibility/skip reasons.
Selection starts empty; **Stop and close selected** confirms only the chosen rows.
Display separate removed, skipped, and failed results; preserve retryable failures.

## Safety decisions

The following are conservative implementation choices, not broader cleanup authority:

- Only GitDock-managed linked worktrees under the configured worktree root.
  Never the main checkout, pinned external worktrees, or paths escaping via symlinks.
- Confirm repository identity, registration, and fresh GitHub merged status.
  Missing from the open list is not proof of merge. For a stack, require complete,
  current membership and every member merged; otherwise skip with an explanation.
- Fetch the PR head from origin into an isolated temporary ref. Require local HEAD
  to equal both that fetched head and GitHub's reported PR head. This supports
  squash merges and deleted source branches without relying on origin/main ancestry.
- Skip modified, staged, untracked, ignored, locked, missing, or unverified worktrees.
  Keep local branches; never force-remove, force-push, reset, or recursively delete.
- Group multiple links to the same canonical worktree. Include every linked session
  in consent. Unknown session ownership or unverifiable activity blocks removal.
- Revalidate eligibility, identity, HEAD, and linked-session set before stopping
  anything. Stop only explicitly approved managed sessions. Recheck filesystem and
  Git state after stopping and immediately before ordinary `git worktree remove`.
- A failed removal leaves links intact. A successful removal unlinks affected sessions
  but retains board notes, tags, priorities, and review history.
- Serialize cleanup and managed lifecycle mutations; invalidate previews on account
  or configuration change. Cancellation never starts further removals.

## Scope

Remain agent-agnostic. No new runtime dependencies, remote GitHub writes, automatic
cleanup, terminal-app-wide quits, or deletion of actual user worktrees during tests.
Local branches and unrelated terminal windows stay intact. Package a validation
build after tests; merging, publishing, and installation are separate user actions.
