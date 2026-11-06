# PR review workspace implementation plan

> **For agentic workers:** Use superpowers:executing-plans for integration and
> superpowers:dispatching-parallel-agents for the independent core components.

**Goal:** Implement the approved management, diff review, and agent-chat workspace.

**Architecture:** Native SwiftUI shell consumes an account-bound review client and
local review state. Existing workspace controls are embedded as a tab. Chat runs
through a separate, bounded JSON command contract without shell interpolation.

**Tech Stack:** Swift 6, SwiftUI/AppKit, Foundation, XCTest, existing XcodeGen project.

**Spec:** `docs/superpowers/specs/2026-10-26-review-workspace-design.md`

## Global constraints

- macOS 14+, no new dependencies, vendor-neutral agent configuration.
- No live comments, real agent launches, or worktree removal during verification.
- Keep old workspace controls, navigation behavior, and account isolation.
- Explicit partial data and stale revision errors; preserve drafts after failure.

## Review focus

- Late network/chat responses after account or PR switch must not populate another PR.
- PR head changes, omitted patches, and compare diffs must not misplace comments.
- Huge output, hung subprocesses, and malformed adapter replies must not hang the app.
- Disk errors and invalid local state must not silently erase review drafts.
- Narrow windows and long filenames/titles must keep review and cancellation usable.

### Task 1: GitHub review data and diff model

Files: new `Packages/GitDockCore/Sources/GitDockCore/Review/` files and
`Packages/GitDockCore/Tests/GitDockCoreTests/PRReviewTests.swift`; extend optional
createdAt in the existing presentation and its workload/search producers.

Interfaces: `PRReviewServicing.load(key:accountLogin:sinceSHA:) async throws ->
PRReviewSnapshot`; `submit(key:accountLogin:headSHA:baseSHA:event:body:comments:) async throws`.
Snapshot contains title/body/author, created/update dates, head/base SHA, files,
coverage notices, review comments, and checks summary. Diff parser provides old/new
line numbers, line kind, and source text. Inline comment uses path/line/side/body.

- [x] Write fixture tests for multi-hunk numbering, deletions, missing patches,
  paginated data, account mismatch, changing head, and review submission payload.
- [x] Run focused core tests and observe failure before implementation.
- [x] Implement bounded read/submit transport and parser; no automatic writes.
- [x] Run `swift test --package-path Packages/GitDockCore --filter PRReview`.
  Expected: all selected tests pass.

### Task 2: Agent chat command contract

Files: new `ReviewChat` core files/tests and `docs/agent-chat.md` only.

Interfaces: `ReviewChatConfiguration`, `ReviewChatRequest`, `ReviewChatResponse`,
`ReviewChatMessage`, `ReviewChatCitation`, and `ReviewChatServicing.send`.
Configuration has displayName, executable, arguments, workingDirectory. Request
has accountLogin, prURL, headSHA, question, context, messages, and policy description.
Response includes matching prURL/headSHA, answer, and file/line citations.

- [x] Write tests for real temporary adapter processes, request serialization,
  missing executable, malformed/wrong-revision responses, cancellation and limits.
- [x] Run focused tests and observe failure before implementation.
- [x] Implement no-shell JSON stdin/stdout transport with timeout/output cap.
- [x] Run `swift test --package-path Packages/GitDockCore --filter ReviewChat`.
  Expected: all selected tests pass; no real agents invoked.

### Task 3: Local review state and workspace shell

Files: new `GitDock/Workspace/ReviewWorkspaceModel.swift`,
`ReviewWorkspaceView.swift`, `ReviewDiffView.swift`, `ReviewChatPanel.swift`,
local state helper, related app tests; modify WorkspaceWindowController and expose
the existing WorkspaceDetailView for reuse. Parent owns these files.

Interfaces: model owns selected snapshot, load/send tasks and generation guards;
draft state key includes account, PR, head, and base. UI receives WorkspaceModel and AppModel.

- [x] Write tests proving independent account/head drafts, viewed-file persistence,
  pin/snooze state, and old-result suppression on navigation.
- [x] Implement local persistence and filtering, then render the management shell.
- [x] Add Overview/Changes/Threads/Workspace tabs and unified/split diff selection.
- [x] Wire explicit review submission, comparison baseline, and agent panel/settings.
- [x] Run targeted app tests with Xcode; expect passing model and light/dark render
  tests, including a minimum-width review window.

### Task 4: Integrate and deliver

- [x] Generate the project, run core/app tests and `scripts/check.sh`.
- [x] Inspect rendered management/review views in light/dark and minimum width.
- [x] Have an independent reviewer inspect the integrated diff for the focus areas;
  fix substantive findings and rerun affected tests.
- [x] Document configuration and limits; commit the implementation.
After committing, build a universal validation ZIP with
`scripts/package-validation.sh`, verify signatures, architectures, archive/checksum,
and report the exact artifact. Delivery evidence is recorded with the artifact.
