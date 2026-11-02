# Local agent workspace

See [Manage and review pull requests](review-workspace.md) for the larger workspace,
diffs, local review drafts, and contextual agent chat.

This fork adds a local board and pinned Codex/Claude sessions to the menu-bar PR view.
It does not write board metadata to GitHub or Slack. The board file lives at
`~/Library/Application Support/GitHubBar/workspace.json`, with owner-only permissions.
Agents and the app coordinate edits using a local lock and atomic writes. Do not edit the
JSON file directly while GitHubBar is running.

## Set up

Build this fork with full Xcode, then open **Workspace Board…** in the menu.
Click a PR in the menu or search results to select it in the board. Right-click opens
its GitHub page directly. Stack summary rows select the displayed PR; hover or use
the right arrow to access the stack submenu. Search results outside your current list
carry their title, author and available review metadata into the board.
Under **Workspace setup**, provide an absolute path to the local checkout for each
repository and an absolute worktree root outside those checkouts. New worktrees fetch
`pull/NUMBER/head` from the checkout's `origin` remote. GitHubBar refuses to launch
unless `origin` points at the GitHub repository that owns the PR. A fork-only `origin`
may not expose its PR refs.

Install tmux and either or both agent CLIs:

```bash
brew install tmux
command -v codex
command -v claude
```

The **New Codex worktree** and **New Claude worktree** buttons fetch the PR head, create a
new local branch/worktree, and start the agent in a named tmux session. Use **Jump to
session** in the PR submenu or the board to open a running session in Terminal.
You can also pin an existing worktree and optional
tmux session name in the board. A session pinned to a stack is available from its member
PRs. Stopping kills only the linked tmux session. Restarting starts it again in the same
worktree.

**Remove worktree** is available only for worktrees created by GitHubBar. It refuses to
remove one with uncommitted or ignored files. **Unpin** removes the local link only; it does not
stop tmux or delete files.

## Let agents update the board

Every validation ZIP and stable app includes the command-line client at
`GitHubBar.app/Contents/MacOS/GitHubBarWorkspaceCLI`. Xcode's `GitHubBar` scheme also
builds and embeds it. For an app installed in `/Applications`, inspect the board with:

```bash
"/Applications/GitHubBar.app/Contents/MacOS/GitHubBarWorkspaceCLI" show
```

Use your actual app location if it is elsewhere. A separate Swift build is optional;
from the repository root:

```bash
swift build --package-path Packages/GitHubBarCore --product GitHubBarWorkspaceCLI
```

Then ask Codex or Claude to use it for their local progress. Example:

```bash
swift run --package-path Packages/GitHubBarCore GitHubBarWorkspaceCLI set \
  --pr https://github.com/OWNER/REPO/pull/123 \
  --priority high \
  --tags blocked,agent-needs-attention \
  --note "Tests pass; waiting for API decision" \
  --by codex
```

Use `--stack` with the root PR URL to set stack defaults. Omitting a field leaves its
previous value intact. `--priority none` clears the priority; `--tags ""` clears tags;
`--note ""` clears the note. Built-in tag IDs are `blocked`, `waiting-on-review`,
`needs-rework`, `ready-to-merge`, `agent-running`, and `agent-needs-attention`. Create
and edit custom tags in the board window. To inspect the current document:

```bash
swift run --package-path Packages/GitHubBarCore GitHubBarWorkspaceCLI show
```

For testing without touching your real board, set `GITHUBBAR_WORKSPACE_DIR` to an
absolute temporary directory when invoking the CLI. The app always uses its normal
Application Support location.

## Local chat and legacy worker data

Codex and Claude chat are available through the workspace provider picker. See
[Review workspace](review-workspace.md) and [Chat setup](agent-chat.md).
The app no longer launches, polls, or requests Giles background reviews. Existing
`agent-reviews.json` files and external workers are left intact; the bundled legacy
CLI protocol remains compatible but is not driven by the app. Priority-author
preferences migrate once into independent app preferences without rewriting worker data.

## Refresh and merged-worktree cleanup

The Workspace Board has **Refresh** and **Clean up merged worktrees…** controls.
Manual refresh during an existing reconciliation queues one follow-up refresh;
repeated clicks coalesce. A disconnected account is rechecked. An explicit GitHub
rate-limit reset remains respected, including after a partial refresh. One pending
manual refresh runs when GitHub permits it again.

Cleanup scans saved session links, including PRs no longer in the open workload.
The preview and results show each PR's title, repository/number, and a short
plain-text description excerpt, including stack members. PR links open GitHub for
the full description. Details are also fetched for skipped worktrees; unavailable
metadata is explicitly labelled and never makes a worktree eligible for removal.
Scanning does not stop sessions or remove worktrees. Choose either:

- **Stop and close all eligible worktrees** to explicitly approve the listed eligible
  worktrees and their managed sessions.
- **Review individually** to see PR titles, numbers, repositories, local paths, session
  names/activity, and skip reasons. Nothing is preselected; choose rows and press
  **Stop and close selected**.

Only GitHubBar-created linked worktrees under the configured root are eligible.
The PR must be verified merged, and local HEAD must exactly match the PR head freshly
fetched from origin and reported by GitHub. This also works after squash merges or
source-branch deletion. Current stack membership is checked even when a session was
originally linked to a single PR. Stacks require all members verified merged; missing,
incomplete, or over-100-member stack metadata blocks cleanup.

Modified, staged, untracked, ignored, sparse/hidden, locked, external, or unverifiable
worktrees are skipped. GitHubBar checks again before stopping sessions and before
removal. Changed configuration, HEAD, or session activity invalidates approval.
Session checks include the tmux server PID/start time and session creation time,
so restarting tmux and reusing a session ID requires a fresh scan.
Unlinked tmux sessions prevent cleanup. Remaining same-user processes with a working
directory inside the worktree also prevent removal; close them and scan again.

Sessions are stopped by exact tmux session ID, not terminal-app-wide commands.
Detached or independently started agents are not forcibly killed. Cleanup never uses
force removal and never deletes local branches. Successful removal clears the local
session links while retaining board notes, tags, priorities, and review history.
Failures retain worktrees/links for inspection; the result list reports each outcome.
Cancellation stops further operations, but completed removals cannot be undone.

Keep other tools from editing a worktree during cleanup: Git does not provide an
atomic transaction across filesystem checks and removal. Session and process checks
reduce this race but cannot lock out an independently launched editor or agent.

## Boundaries

A pinned Codex or Claude session stays local until you explicitly ask it to act.
Advisory workspace chat publishes only through explicit workspace controls.
The board and review queue can contain private notes, instructions, and paths, so do not
commit `workspace.json` or `agent-reviews.json` to a repository.
This fork currently opens linked sessions in Apple Terminal; it does not re-focus an
existing Terminal tab, but attaches to the same tmux session.
