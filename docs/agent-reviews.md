# Agent reviews

> Legacy integration: the current app does not launch, poll, configure, or request
> background worker reviews. This document is retained for the compatible legacy
> CLI protocol and existing external clients. Local Codex/Claude chat and explicit
> GitHub review posting are described in [Review workspace](review-workspace.md).

GitHubBar exchanges local review requests and results with any compatible review worker
through `GitHubBarWorkspaceCLI agent`. The CLI is bundled in
`GitHubBar.app/Contents/MacOS` in validation, stable, and Xcode builds. Review workers
are installed separately. Colleagues can build GitHubBar without a worker installed.

A general-purpose coding CLI, including Claude or Codex, is **not automatically a
review worker**. It needs an adapter implementing the
[agent review protocol](agent-review-protocol.md), including queue claims, leases,
policy checks, and result updates. GitHubBar does not supply such an adapter or infer
compatibility from the executable's name.

## Configure in Settings

Under **Review agent**, choose a display name and one of these modes:

- **External worker**: run your compatible worker independently. GitHubBar does not
  start, stop, or monitor that process. This is the default for existing installations.
- **Start from GitHubBar**: enter an absolute executable path, arguments, and an existing
  absolute working directory. The executable must be a compatible foreground worker.

Arguments accept a JSON array of strings or one argument per line. For example:

```json
["--config", "/Users/you/Review Worker/config.json", "--foreground"]
```

These flags are illustrative; use your adapter's actual flags. No shell is involved:
spaces, quotes, semicolons, and `$()` remain literal argument characters. Do not quote
the executable or directory fields. `~`, `$HOME`, and globs are not expanded. Blank
argument lines are omitted; use JSON for empty arguments or embedded newlines.
Arguments are limited to 256 elements and 64 KiB total, without NUL bytes.

**Save** persists the connection and priority authors without launching anything.
**Test configuration** validates the draft's paths and argument syntax and checks for
the bundled CLI. It does not execute the worker, save changes, contact a provider,
or verify protocol compatibility. **Start** uses the saved configuration and requires
reviews enabled for the matching monitored account. Stop a running worker before saving
another connection. There is no automatic start, restart, or installation.

The app locates the bridge inside its current bundle, so moving or renaming the app
does not require a hardcoded installation path. Managed workers inherit the app's
environment, with these variables explicitly set:

| Variable | Value |
| --- | --- |
| `GITHUBBAR_WORKSPACE_CLI` | Absolute path to the bundled CLI executable |
| `GITHUBBAR_WORKSPACE_DIR` | Absolute directory used by the app's review store |

Both paths are visible in Settings for external workers. Use the same macOS account
and data directory for both clients. The default is
`~/Library/Application Support/GitHubBar`. CLI invocations accept an absolute
`GITHUBBAR_WORKSPACE_DIR` override for isolated tests. Managed workers receive the app
store's directory, overriding any inherited value.

Connection settings and `priority_authors` are additive fields in schema-1
`agent-reviews.json`, protected by its existing local lock and atomic writes. Old
documents load with no saved connection and an empty author list; jobs and policy
overrides remain intact. Workers must use CLI operations and never rewrite the document
directly. Connection arguments are local plaintext; use the worker's own credential
store rather than putting secrets in arguments.

## Lifecycle and diagnostics

“Process running; compatibility unverified” means only that the launched process has
not exited. Queue progress provides separate evidence that a worker is consuming jobs.
No connection handshake is claimed. Worker stdin is closed; stdout and stderr are
discarded. Only the latest 50 lifecycle events are retained in memory, without paths,
arguments, PR content, or worker output. For debugging, run the adapter independently
with its own private logging configuration.

**Stop** sends termination, waits up to one second, then sends a kill signal if needed
and waits up to one more second. It controls the direct process only. Compatible
workers must stay in the foreground, supervise their children, and stop them on
termination; detached subprocesses cannot be managed by GitHubBar. The app stops its
worker at shutdown and when the monitored account changes or disconnects. Switching
accounts does not migrate a queue: use separate workspace state for another account.
External workers remain the responsibility of their external supervisor.

Stopping preserves queued requests. An interrupted running job expires according to
its lease and is not automatically replayed. Inspect remote outcomes before requesting
it again. Disabling integration prevents further claims and returns an all-off
effective policy; compatible workers must recheck that policy before external writes.

## Policies and priority

Enable reviews for the monitored GitHub account separately from starting the worker.
The initial policies remain:

| Action | Own PR | Someone else's PR |
| --- | --- | --- |
| Fixes | Off | Off; requires explicit PR-level opt-in |
| Publish verified review comments | On | Off |
| Automatic replies | Off | Off |

PR overrides take precedence over stack overrides, then global defaults. Stack policy
keys use `stack:` followed by the root PR URL. A `null` field clears an override.
Fix modes are `off`, `low_risk`, and `all`; stack and global settings cannot authorize
fixes on another author's PR.

Manual priority wins, including inherited stack priority. Otherwise, a complete roster
with the monitored account as sole requested human reviewer and no requested teams is
high priority. Authors in **Priority authors** receive medium priority, compared
case-insensitively. The list defaults to empty; all others are low. The board orders
oldest GitHub updates first within a priority; queue claims order oldest requests first.
Clearing manual priority restores inherited or automatic priority.

Only one job runs per workspace. Its 180-second lease must be renewed at least every
60 seconds. Expired jobs become failed on reads and claims. Duplicate active requests
return the existing job; completed or failed jobs can be explicitly requested again.

## Publication and fixes

The bridge manages policy and queue state; it does not perform reviews or publish to
GitHub. A compatible worker must verify findings and recheck effective policy,
authenticated identity, repository authorization, and head SHA before each external
write. Label generated comments and commits with the configured worker identity.
Replies, when authorized, should target new human comments in that worker's own review
threads, excluding bots and the worker itself.

Workers implementing fixes must use separate writable worktrees, targeted checks,
commit hooks, and head-SHA guards. Low-risk fixes need a risk rationale; uncertainty
must prevent a push. Do not force-push, amend, or merge. Preserve failed worktrees and
report their location. Use an outgoing-action ledger to avoid duplicate remote writes;
ambiguous outcomes require reconciliation rather than automatic replay. These are
adapter responsibilities, not capabilities proven by the app's configuration test.

## Build and verify

From the repository root, build and run core tests with full Xcode:

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test \
  --package-path Packages/GitHubBarCore \
  --scratch-path /private/tmp/githubbar-review-build
```

For an Xcode app build, run `scripts/generate-project.sh`, then build the `GitHubBar`
scheme. Its CLI target shares the Swift package sources and embeds the executable in
`Contents/MacOS`. No worker dependency is needed to compile the app.

To build a local universal validation ZIP:

```bash
GITHUBBAR_VERSION=0.1.0 GITHUBBAR_BUILD_NUMBER=1 scripts/package-validation.sh
```

This compiles the app and CLI for arm64 and x86_64, signs them with ad-hoc signatures,
and writes a ZIP and checksum to `dist/`. Inspect the bridge with isolated state:

```bash
review_test_dir="$(mktemp -d /private/tmp/githubbar-review-check.XXXXXX)"
printf '%s\n' '{"op":"show"}' \
  | GITHUBBAR_WORKSPACE_DIR="$review_test_dir" \
    .build/validation/GitHubBar.app/Contents/MacOS/GitHubBarWorkspaceCLI agent
```

The temporary directory is retained for inspection. Packaging tests do not require
enabling a worker or sending live reviews. For stable distribution, follow the
[stable release runbook](releases/stable-release-runbook.md).
