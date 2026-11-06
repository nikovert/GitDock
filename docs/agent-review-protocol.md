# Agent review protocol

> Legacy integration: the current app does not launch, poll, configure, or request
> background worker reviews. This document is retained for the compatible legacy
> CLI protocol and existing external clients. Local Codex/Claude chat and explicit
> GitHub review posting are described in [Review workspace](review-workspace.md).

The bundled `GitDockWorkspaceCLI agent` command provides local review state and queue
operations for GitDock and compatible review workers. See
[Agent reviews](agent-reviews.md) for connection setup, policy defaults, and packaging.

## Transport and storage

Invoke the executable once per request. Write one JSON object to stdin and close stdin;
the CLI reads through EOF. The required `op` string selects the operation. A successful
request prints one JSON value to stdout and exits with status 0. Invalid requests and
storage errors exit with status 2 and a diagnostic on stderr. Requests larger than
2,000,000 bytes are rejected. Do not interpret stderr as a JSON response.

```bash
workspace_cli="/Applications/GitDock.app/Contents/MacOS/GitDockWorkspaceCLI"
printf '%s\n' '{"op":"show"}' | "$workspace_cli" agent
```

The default directory is `~/Library/Application Support/GitHubBar`. Set
`GITHUBBAR_WORKSPACE_DIR` to an absolute directory to isolate a client's state. Review
state is stored in `agent-reviews.json`, with `agent-reviews.lock` for process locking
and atomic file replacement. The ordinary CLI `show`/`set` commands use the separate
`workspace.json` board document. The `priority` agent operation updates that board.

Keys use snake_case. Enum values use snake_case except the operation name
`effective-policy`, which contains a hyphen. Dates are JSON numbers representing Unix
seconds, including fractional seconds. Optional response fields may be omitted rather
than emitted as `null`; clients should accept either when reading optional values.

## Operations

Every request includes `op`. Fields below are required unless marked optional.
“Document” means the full review document described in the next section.

| `op` | Request fields | Response and behavior |
| --- | --- | --- |
| `show` | None | Document, including computed context priority |
| `configure` | Optional `enabled` boolean, `account_login` string, and `priority_authors` string array | Document; merges only supplied values |
| `sync` | `contexts` array of context objects | Document; upserts contexts unless their `updated_at` is older than the stored context; retains other contexts |
| `policy` | `scope`: `global`, `pr`, or `stack`; `policy` patch; `pr_url` for `pr` or `stack` | Document; merges the patch at the selected scope |
| `effective-policy` | `context` object | Object with concrete `fix_mode`, `comments`, and `replies` values |
| `priority` | `pr_url`; `priority`: `high`, `medium`, `low`, or `none`; optional `by` string, default `review-agent` | Document; updates board priority while preserving notes and tags; `none` clears the PR override |
| `enqueue` | `context`; optional `source`: `board` or `slack`; optional `focuses`, `instructions`, `slack_channel`, `slack_thread_ts` | New or existing active job; omitted `source` defaults to `board` |
| `claim` | Nonempty `worker_id` string | Claimed job or JSON `null` if none can be claimed |
| `heartbeat` | `job_id` and `worker_id` strings | Job with renewed lease |
| `update` | `job_id`, `worker_id`; optional `status`: `running`, `completed`, or `failed`; optional result fields below | Updated job; omitted fields retain their values |

`configure` requires a nonempty account login before enabling integration. Login
characters are letters, digits, or hyphens. Once configured, the account cannot be
changed to another account in the same workspace; use separate state for that account.
Account comparisons are case-insensitive.

`priority_authors` replaces the configured list; `[]` clears it. Logins must be nonempty,
at most 39 bytes, and contain only letters, digits, or hyphens. Up to 256 logins are
accepted; duplicates are removed and values stored in lowercase. Omitting the field
preserves the list. This setting does not grant review or publication permissions.

`sync` ignores contexts for a different account once the document account is configured.
For an existing PR, an incoming context with an older `updated_at` is ignored so stale
refreshes cannot overwrite newer data. Context updates do not rewrite queued or running
jobs; expired leases are handled separately as described below.
`enqueue` requires integration enabled and a matching context account. `effective-policy`
returns fixes off, comments false, and replies false if integration is disabled or the
context account differs from the configured account.

Optional `enqueue` fields are `focuses` (array of strings, default `[]`), `instructions`
(string, default empty), and `slack_channel`/`slack_thread_ts` (strings). Supply the Slack
destination fields for Slack requests so the worker can report to the original thread.

Optional `update` result fields are strings: `summary`, `error`, `head_sha`, `github_url`,
`slack_url`, and `worktree_path`. Updating a job does not replace its original context.
A job cannot be moved back to `queued` through this operation.

## Review document

| Field | Type and meaning |
| --- | --- |
| `schema_version` | Integer; current version is `1` |
| `enabled` | Boolean; defaults to `false` |
| `account_login` | Monitored GitHub login; empty before configuration |
| `default_policy` | Partial policy object; initially empty |
| `policy_overrides` | Dictionary of partial policies keyed by PR URL or `stack:` plus root PR URL |
| `contexts` | Dictionary of context objects keyed by canonical PR URL |
| `jobs` | Array of queued, running, completed, and failed jobs |
| `priority_authors` | Optional string array; defaults to `[]` in older documents |
| `review_agent_connection` | Optional app connection settings; absent in older documents |

Document responses include computed `priority_rank` and `priority_reason` on contexts.
These are presentation fields; callers do not set them through `sync`.

Connection settings contain `display_name`, `mode` (`external` or `managed`),
`executable`, `arguments` (string array), and `working_directory`. The app saves these
locally; the `configure` bridge operation does not change the launch connection. Workers
must tolerate these additive schema-1 fields and use bridge operations rather than
rewriting the file, so future settings are preserved. No existing job or policy field
has changed format.

## PR context

| Field | Type and meaning |
| --- | --- |
| `pr_url` | Required valid GitHub PR URL |
| `account_login` | Required nonempty monitored account login |
| `title` | String; defaults to empty |
| `author_login` | GitHub author login; defaults to empty, so ownership is not assumed |
| `head_sha` | PR head commit SHA string; defaults to empty |
| `updated_at` | Unix seconds; defaults to a distant-past timestamp |
| `requested_humans` | Array of requested human reviewer logins, excluding bots; defaults to `[]` |
| `requested_team_count` | Integer count of requested teams; defaults to `0` |
| `reviewers_complete` | Boolean indicating a complete reviewer roster; defaults to `false` |
| `stack_url` | Optional root PR URL in the same repository |
| `priority_rank` | Output-only integer: high `3`, medium `2`, low `1` |
| `priority_reason` | Output-only description of the priority decision |

Supply the full context when known, particularly the head SHA and reviewer roster.
Missing data does not establish ownership or a sole-reviewer request. PR and stack
URLs are normalized before storage.

Manual board priority takes precedence, including inherited stack priority. Otherwise,
a complete roster containing only the monitored account as a requested human and no
requested teams gives high priority. Authors in `priority_authors` receive medium
priority, compared case-insensitively; other contexts receive low priority.
Clearing a PR priority override
restores inherited stack priority or automatic priority. The board sorts by oldest
`updated_at` within each priority; queue claims use oldest request time within priority.

## Policies

A policy object has three optional fields:

| Field | Accepted patch values | Fallback |
| --- | --- | --- |
| `fix_mode` | `off`, `low_risk`, `all`, or `null` | `off` |
| `comments` | Boolean or `null` | True only when author and monitored account match |
| `replies` | Boolean or `null` | `false` |

Each field resolves independently: PR override, then stack override, then global
default, then fallback. For fixes on another author's PR, only an explicit PR-level
`fix_mode` can authorize work; stack and global fix settings are ignored. Omitting a
field preserves its setting. Setting it to `null` clears the setting at that scope.
For a stack patch, `pr_url` identifies the root PR.

Example request to disable comments on one PR and clear its fix override:

```json
{
  "op": "policy",
  "scope": "pr",
  "pr_url": "https://github.com/OWNER/REPO/pull/123",
  "policy": {"comments": false, "fix_mode": null}
}
```

Policy permits an action; it does not itself post, reply, or push. The worker checks
policy, identity, head SHA, and authorization before external writes. See
[publication and fixes](agent-reviews.md#publication-and-fixes) for worker behavior.

## Job fields and lifecycle

| Field | Type and meaning |
| --- | --- |
| `id` | UUID string; use as `job_id` in worker requests |
| `context` | PR context captured when the job was enqueued |
| `source` | `board` or `slack` |
| `requested_at`, `updated_at` | Unix seconds |
| `status` | `queued`, `running`, `completed`, or `failed` |
| `worker_id` | Optional claiming worker identifier |
| `lease_until` | Optional Unix seconds; present while running |
| `summary`, `error` | Strings; initially empty |
| `head_sha` | Reviewed/result commit SHA; initially the context head SHA |
| `github_url`, `slack_url`, `worktree_path` | Optional result links and local path |
| `focuses` | Array of strings; initially the requested focuses |
| `instructions` | String; initially the requested instructions |
| `slack_channel`, `slack_thread_ts` | Optional Slack destination strings |

An enqueue for a PR already queued or running with an unexpired lease returns the
existing job without replacing its fields. Expired running jobs are persisted as failed
before deduplication. Once the job is completed or failed, a new explicit request may
create a new job, including for the same head SHA.

Only one job may run at a time in a workspace. `claim` chooses the highest effective
priority, with oldest `requested_at` first for ties, and gives the worker a 180-second
lease. It uses the latest synced context for priority when available. Workers should
send `heartbeat` at least every 60 seconds. A heartbeat or running update extends the
lease by 180 seconds.

Both `heartbeat` and `update` reject an unknown job, a different worker, a job no longer
running, or an expired lease. Completing or failing a job clears its lease. Expired
running jobs are persisted as failed with an interruption message during reads/loads,
including `show`, and during `enqueue` as well as `claim`. This allows an immediate
explicit re-request after lease expiry even when the worker has stopped; no worker
claim is needed to clear the stale running job. Failed jobs are never automatically
requeued. A disabled workspace cannot claim a new job. After interruption, inspect
remote outcomes before explicitly requesting another run.
