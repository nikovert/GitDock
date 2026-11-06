# PR Search and Configurable Reviewers Implementation Plan

> **For agentic workers:** Use test-driven development and parallel execution for the disjoint core search, reviewer configuration, and app presentation tasks.

**Goal:** Deliver two-section PR search and a colleague-friendly, provider-neutral local review connection.

**Architecture:** A separate core search actor owns authenticated discovery and private cached search data. The app owns window lifecycle and presentation. Reviewers use the existing JSON queue protocol; a configurable local executable can start a compatible worker without shell interpolation.

**Tech Stack:** Swift 6, SwiftUI/AppKit, Foundation URLSession, system SQLite.

**Spec:** `docs/superpowers/specs/2026-10-22-pr-search.md` and the user's additional requirement for provider-neutral reviewer Settings.

## Global Constraints

- Preserve existing workload reconciliation, review policies, and queue compatibility.
- No provider-specific bot names or personal priority authors in shipped defaults.
- Search performs no GitHub writes and launches no agents.
- Account and repository boundaries must hide/purge stale private search data.
- Use the existing isolated feature worktree; no merge, push, install, or release.

## Review Focus

- Account changes during network responses must not resurrect private results.
- Code-only matches and incomplete patches must not imply exhaustive coverage.
- Executable arguments containing spaces or metacharacters must remain literal.
- Existing schema-1 review documents must load without new configuration fields.
- Settings must distinguish an enabled queue from an actually connected worker.

## Task 1: Core search

**Files:** New `Packages/GitDockCore/Sources/GitDockCore/Search/` and core search tests.

**Interfaces:** Produce `PRSearchEngine` with async state stream, context update, query, submitted scan, pause, and clear-cache operations. Publish exact signatures before UI integration. Accept explicit selected account, active PRs and repository selection. Keep authentication and private cache logic inside core.

- [x] Add failing ranking, section/dedup, code-only, coverage, account-switch, pagination, cancellation, and cache tests.
- [x] Implement literal search/ranking, ephemeral authenticated REST discovery, revision-safe file hydration, and bounded SQLite cache with scan checkpoints.
- [x] Run core tests with full Xcode selected; document any spec gaps honestly.

## Task 2: Provider-neutral review connection

**Files:** Existing review core and views; new reviewer configuration/launcher and Settings section; review documentation/tests.

**Interfaces:** A shared `ReviewAgentModel` exposes saved executable/argument/working-directory configuration and explicit start/stop/status. Settings embeds `ReviewAgentSettingsView`. Workers consume the unchanged `GitDockWorkspaceCLI agent` JSON protocol.

- [x] Add failing migration, literal argv, validation, process-status and configurable-priority tests.
- [x] Implement optional local worker launcher; external workers remain supported. Never execute from editable draft Settings before Save/Start.
- [x] Remove provider-specific strings throughout tracked source and docs. Explain that arbitrary CLIs require a compatible worker adapter.
- [x] Verify existing review-policy tests and new tests.

## Task 3: Search window and application integration

**Files:** New `GitDock/Search/`; `AppDelegate`, `AppActions`, menus, Settings, and app tests.

**Interfaces:** Consume core search state; keep “In your list” before “Extended results”; expose repository selection, explicit search/resume/pause, coverage, cache clearing and links.

- [x] Add failing presentation tests for sections, scope defaults, and stale-account hiding.
- [x] Implement native reusable Search window and Cmd-F/menu entry, synchronize workload changes without replacing existing callbacks.
- [x] Embed reviewer Settings and connect shared lifecycle.
- [x] Run all core/app tests and build universal validation archive.

## Task 4: Verification and handoff

- [x] Independently review the complete change for privacy, policy and lifecycle regressions.
- [x] Fix significant findings with regression tests; rerun the complete Swift suites.
- [x] Verify provider-neutral tracked tree, update user docs, commit and package the feature branch.
- [x] Record capabilities, remaining limitations and artifact path without implying publication.

## Verification record

Implementation commit: `921cebf66b04`. Core suite: 83 passed; native app suite:
30 passed. `scripts/check.sh` passed. Both light/dark renders were inspected.
Independent review's two Important findings were fixed with regression tests.
No provider-specific bot references remain in the tracked tree.

Artifact: `dist/GitHubBar-validation-0.4.0-921cebf66b04.zip` (arm64 and x86_64,
including the bundled CLI). SHA-256:
`8d6dcd5feede126f9bc2a87bd9a4ddde106c08e778587b641ce0d318c066a503`.
Ad-hoc signed, not notarized. Not merged, pushed, published or installed.
Limitations are recorded in `docs/releases/search-and-reviewers-validation.md`.
