# Worktree Agent Review Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development to implement this plan task-by-task. Use tests first, one scoped review per deliverable, and preserve all user data.

**Goal:** Review the complete PR in a fresh pinned worktree and truthfully display file coverage while keeping all findings local until explicit publication.
**Architecture:** A bounded core worktree lease manager prepares a full diff manifest; an extended bundled CLI adapter reads that worktree and returns findings+coverage; the workspace coordinates lifecycle and shared draft import. Ordinary advisory chat and coding/fix sessions retain their behavior.
**Tech Stack:** Swift6/macOS14 AppKit+SwiftUI, Foundation/Git, Python3, existing Codex/Claude CLIs.
**Spec:** docs/superpowers/specs/2026-11-02-worktree-agent-review-design.md

## Global constraints

No silent excerpt fallback; no automatic publication/commits/code changes/test execution. Exact account/PR/head/base checks; preserve local drafts and concurrent edits. No forced cleanup, unrelated process termination, unbounded commands, raw diagnostic exposure, or Giles worker integration. Existing chat JSON decoding stays compatible. Reasonable implementation choices proceed within user-authorized scope without a redundant approval pause.

## Review focus

- PRs with17+ files, >24KB individual patches and >96KB aggregate context must expose every changed path with no hidden truncation.
- Stale GitHub head/base, wrong checkout origin, changed/dirty worktree and account navigation must never import findings into a different target or delete local changes.
- Deleted/renamed/binary/symlink files, omitted GitHub patches and shallow histories must be handled explicitly.
- Missing/unknown/duplicate coverage, partial providers and cancellation must never produce a whole-PR success banner.
- Provider read tools must operate in the leased tree with surrounding files available, and tests/prompts must prove no edit/publish/fix permissions are enabled.

## Fixed interfaces

Core worktree models/manager (Task1):
- `ReviewWorktreeRequest(key:PullRequestKey, accountLogin:String, headSHA:String, baseSHA:String)`.
- `ReviewWorktreeLease(id:UUID,key:PullRequestKey,accountLogin:String,headSHA:String,baseSHA:String,mergeBaseSHA:String,worktreePath:String,contextDirectory:String,manifestPath:String,changedPaths:[String])` with public initializer for fixtures.
- `ReviewWorktreeServicing: Sendable`: `prepare(_ request:ReviewWorktreeRequest) async throws -> ReviewWorktreeLease`; `validate(_ lease:ReviewWorktreeLease) async throws`; `release(_ lease:ReviewWorktreeLease) async -> String?` (nil success; retained-artifact warning otherwise).
- `ReviewWorktreeManager(store:LocalWorkspaceStore=..., commandRunner:any CommandRunning=ReviewWorktreeCommandRunner(), gitURL:URL=...)` actor.
- Manifest JSON: version1, headSHA/baseSHA/mergeBaseSHA/worktreePath, files:[{path,previousPath?,status,patchFile,baseFile?,isBinary,isSymlink}]. patchFile/baseFile are absolute paths inside contextDirectory. All changed paths, not the GitHub API subset. App may add owner-only discussion.json before launch; cleanup recognizes that app-owned file.

Wire/provider models (Task2):
- `ReviewChatTask.worktreeReview = "worktree_review"`.
- `ReviewRepositoryContext(worktreePath:String,contextDirectory:String,manifestPath:String,headSHA:String,baseSHA:String,mergeBaseSHA:String)` Codable/Equatable/Sendable.
- Add `ReviewChatRequest.repository:ReviewRepositoryContext? = nil` and `ReviewChatResponse.coverage:ReviewCoverage? = nil` with compatible default initializers/decoding.
- `ReviewUnreviewedFile(path:String,reason:String)`; `ReviewCoverage(reviewedPaths:[String],unreviewed:[ReviewUnreviewedFile],testsRun:[String],limitations:[String])`, bounded validation (testsRun must be empty for this inspection-only task) and `normalized(expectedPaths:[String]) throws -> ReviewCoverage`, appends missing paths as unreviewed and rejects unexpected/overlap/duplicate paths.
- ReviewChatClient default worktreeTimeout660s separate from ordinary timeout120s. Require valid repository context/findings/coverage for worktree_review; don't require a specific provider for ordinary custom chat.

## Task1: Complete pinned worktree lifecycle (core implementer)

Files: create LocalWorkspace/ReviewWorktreeModels.swift, ReviewWorktreeManager.swift, ReviewWorktreeCommandRunner.swift and focused core tests. Avoid editing session/fix/chat files.
- [ ] RED tests for wrong origin, captured head/base mismatch, merge-base semantics, private manifest for >17 files including >24KB patch, deleted/renamed/binary files, unsafe roots, cancellation, dirty/replaced worktree cleanup refusal.
- [ ] Implement literal bounded Git calls and owner-only artifacts. Enumerate configured filter drivers and override process to empty, clean/smudge to absolute /bin/cat, required=false; disable fsmonitor/hooks. A malicious-filter fixture must prove raw file materialization with no marker execution. The runner kills/reaps its owned group before timeout/cancel sentinels; record owned artifacts before mutations and check cancellation after awaits, shielding partial cleanup. A text/metadata resource limit fails explicitly. Use safe hooks/diff settings and fresh private refs/detached tree. Verify before returning and before accepting results; do not require tmux.
- [ ] GREEN with real local Git fixtures and fake origin/fetch routing, no network/provider calls. Report exact API and known limits. Never delete another branch/session.

## Task2: Repository-capable providers and coverage protocol (adapter implementer)

Files: ReviewChat/ReviewRepositoryModels.swift, ReviewChatModels.swift, ReviewChatClient.swift, scripts/review-chat-adapter.py, scripts/tests/test_review_chat_adapter.py and core protocol tests. Own only these.
- [ ] RED fixtures for new task, real leased cwd/manifest access, complete file reads beyond excerpt caps, native structured findings+coverage, missing/invalid coverage, old chat compatibility, large event streams/timeouts and cancellation.
- [ ] Implement fixed DTOs, normalization and extended deadline. Validate worktree HEAD, context paths/manifest identity locally. Codex read-only JSON-event mode, disabled web search; Claude restricted Read/Grep/Glob with no Bash/write/MCP/web. Preserve ordinary advisory flags, Keychain username handling and error privacy. Use native schemas for repository review responses and never turn provider errors into no findings.
- [ ] GREEN controlled CLI fixtures only. Publish recovery/error codes/root integration notes. Don't invoke a real model or private repo.

## Task3: Workspace orchestration, truthful coverage, and drafts (root)

Files: ReviewWorkspaceModel.swift, ReviewAgentContext.swift, ReviewWorkspaceState.swift, ReviewAgentActionsView.swift, ReviewDetailView.swift; focused app tests.
- [ ] RED tests for worktree request lifecycle, complete expected paths, preparing/review/verifying progress, cancellation/navigation and cleanup, changed head/base before import, incomplete coverage/no-findings text, preserved human edits and anchor fallback.
- [ ] Inject worktree service; fresh-check GitHub target, prepare lease, write full bounded discussion.json, send worktree_review with repository context and cwd lease. Validate worktree and fresh target before normalization/import. Always release via noncancelled cleanup; preserve dirty artifacts with visible warning. Guard stale generations, apply findings to current canonical draft versions as today.
- [ ] Receipt adds optional coverage, total changed-file count and pinned merge base with backward-compatible decoding. Historical excerpt receipts remain visibly partial. Display coverage and unreviewed reasons, tests reporting, provider/commit and retained-worktree note. Add setup guidance and custom-provider limitation; no fallback to excerpts.
- [ ] GREEN app fixtures and render light/dark minimum/large windows. Tests must not touch real application prefs, GitHub or installed providers.

## Task4: Review and delivery (root)

- [ ] Inspect worker diffs and obtain independent spec/safety review with exact packages; fix findings and scoped re-review.
- [ ] Run core/app/Python suites, strict repository checks and universal packaging. Native host has sometimes stalled in dyld before app code; record accurately rather than claiming unrun suites pass.
- [ ] Update workflow/protocol/setup docs and validation coverage. Merge/push verified source to main under existing delivery authorization; build a matching local validation ZIP (no public release).
