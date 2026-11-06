# Manage and review pull requests

GitDock opens its dashboard at launch and appears in the Dock and Cmd+Tab.
Closing the window leaves the menu bar app running. Click its Dock icon to restore
the same workspace. The status icon opens an anchored popover; refresh updates the
existing contents. Escape, an outside click, or the status icon closes it.

## Dashboard and layout

Use the sidebar or dashboard queue picker for needs attention, your PRs, requested
reviews, pinned, snoozed, and all PRs. Search by title, repository, author, or number.
The workload follows All/Pinned repository scope. Extended search can open a PR
outside that workload without adding it to the dashboard.

Cards show title, repository, author, review decision, requested reviewers, age,
last GitHub activity, urgency and its reason, and next action. Activity can include
bots. Automatic urgency uses requested humans and priority authors; manual PR and
stack priority takes precedence. Age is visible separately. Set priority authors
from the toolbar's **… → Priority authors…** control.

Native GitHub stacks expand into ordered open-member cards. Closed and merged PRs
stay out of active dashboard cards; their links remain in stack details. Open members
outside the current queue are labelled navigation context. Each matching open PR
appears once. No inferred relationships are added.

Confirmed merged/closed PRs and PRs absent from complete open-workload discovery are
removed even if unrelated reviewer or repository metadata is incomplete. Genuinely
unconfirmed rows remain after incomplete discovery. The dashboard shows partial or
failed refresh information rather than implying every field is current.

Approved follows the required approval count, independently of outstanding requests
to other reviewers. GitHub's explicit aggregate decision takes precedence. When it
is absent, GitDock can verify eligible approvals against the active branch rules;
unavailable policy or unverified extra review requirements remain conservative.
Conflicts, CI, and unresolved conversations are separate merge-readiness checks.

Right-click a card to set manual priority, pin, snooze for 24 hours, open GitHub, or
manage its native stack. Pins and snoozes are local and account-specific.

Drag the wide dividers between PR sidebar, content, file list, and chat. Hover gives
a resize cursor and highlight; focused dividers also support arrow keys. **Layout**
contains labelled panel visibility controls, **Focus diff**, and **Reset layout**.
Widths and visibility survive reopening; smaller windows clamp panels to the space
available without losing preferred widths.

Use **Cmd+Plus** (or **Cmd+=**) to enlarge workspace text, **Cmd+Minus** to reduce
it, and **Cmd+0** to reset. The shortcuts work while typing in the chat composer;
the **View** menu contains the same actions. Sizes range from 80% to 200% and are
saved across restarts. At larger sizes, the PR header scrolls separately so the diff
remains accessible in a small window.

The **text-size icon** beside the chat settings button changes chat independently,
including Markdown, code blocks, and the text you type. Workspace shortcuts adjust
both sizes together; Cmd+0 resets both. Resizing preserves unsent text and selection
and waits for active input-method composition to finish before changing its font.

## Review code and discussion

The review header lists the full requested/completed reviewer roster. A green tick
means a confirmed approval; changes requested, dismissed reviews, and outstanding
requests have separate labels. A reviewer can be approved and requested again.
Known requests remain visible during partial pagination, with incomplete data
disclosed. Team requests do not inherit a person's approval. Long headers scroll;
agent actions remain accessible below them.

- **Overview** shows the description, checks, urgency reason, and retained drafts
  from earlier head/base revisions.
- **Changes** shows unified or split diffs. Click a line to save a local inline
  draft or ask chat about the selection. The file sidebar groups changed files
  in expandable folders, compacting directories that have a single subfolder.
  **Filter files…** searches full paths and previous names of renamed files;
  matching folders expand while filtering. The folder menu expands or collapses
  all folders. Filename rows show viewed markers, local draft counts, and discussion
  counts; hover for the full path and change totals. Selecting a file opens its diff.
  Local drafts and anchored GitHub conversations appear beneath their exact lines.
- **Threads** shows local drafts first, inline conversations grouped by their root,
  then general PR discussion. Cards include author, time, file/line, and GitHub links.
  **Show in diff** opens the file and scrolls to the anchor. Draft edit/remove controls
  operate on the same saved record as Changes.
- **Workspace** contains local notes, tags, priorities, native stack members,
  terminal sessions, worktree configuration, and cleanup.

Outdated comments, missing roots, unknown sides, and unavailable patches remain in
Threads with an explanation. Old filenames and original lines are never guessed
as current anchors. Binary, omitted, truncated patches and API limits are disclosed.
Inline posting requires a complete current PR file list and complete file patch.

## Publish explicitly

The shared multiline composer uses **Enter** for its labelled action and
**Ctrl+Enter** for a newline. Input-method composition can finish without sending.
Inline editors **Save draft** locally; publication requires **Post to GitHub**.

Each draft's **Post to GitHub** submits only that inline or general comment as a Comment review.
Other drafts and the review summary stay untouched. **Publish all drafts…** (or **Submit review…** without drafts) opens a batch
sheet with Comment, Approve, or Request changes. Comment accepts inline comments
without a summary. Request changes requires a summary; approval may omit it.
Approving your own PR is not offered. Large batches are split into review posts within GitHub limits, with the summary and selected decision last. The sheet shows the number of posts. A single oversized comment must be shortened before publishing.

Progress and errors stay visible. Confirmed success clears only the submitted
versions of comments/summary, preserving edits made while posting, and refreshes
GitHub discussion. Failed or ambiguous writes retain drafts and are never retried
automatically. Inspect GitHub before explicitly retrying an uncertain write.

Drafts and viewed-file state are tied to account, PR, head, and base commits. New
commits or a changed base start separate state; older drafts stay in Overview and
are never transplanted. The submission sheet stays bound to its original identity.
**Mark reviewed** and successful batch reviews save a local comparison baseline;
individual comment posting does not mark the whole PR reviewed. **Since my last
review** compares that commit to the head; inline drafting is disabled in comparisons.

## Agent reviews and fixes

Configure a local repository checkout and worktree root in **Workspace**, and choose
the bundled Codex or Claude provider in chat settings. Click **Agent review** on an
open PR card or in the review header. The app fetches and verifies the captured PR
head and base, then opens a fresh detached review worktree. The reviewer receives
the complete native Git changed-file inventory and patches from merge-base to head,
full current files, and access to surrounding repository code and tests. It can
inspect files; the review prompt prohibits edits, dependency installs, test/repository
execution, commits, and publishing. Ordinary chat still uses bounded excerpts.

The PR description, published discussion, and local drafts are supplied separately
in a private context directory. The review never silently falls back to excerpts.
Missing setup, inconsistent commits, or preparation limits produce an actionable
error. Custom adapters continue to support chat; worktree reviews require the
bundled providers. **Test connection** checks chat, not worktree setup.

Findings become local drafts in **Threads** and beneath exact
available diff lines. Findings without a valid current anchor remain general drafts
with their original location explained; that explanation is preserved when posted.
No GitHub review is posted by this action. Review, edit, remove, or publish each
finding, or use **Publish all drafts…**. Repeated unchanged findings are deduplicated.
Cancellation or changing the account/PR/revision discards late results. A review
receipt shows the provider, pinned revisions, summary, and **files reported
reviewed**, with explicit reasons for skipped files and reported limitations. This
coverage is the agent's report, not proof it inspected every line. Tests are not
requested or run by the app. Zero findings in a partial review is labelled partial;
historical excerpt reviews have no full-file coverage. GitHub API patch notices
remain visible separately and do not truncate the native Git inventory.

Clean review worktrees and context files are removed after completion or cancellation.
Changed or replaced worktrees are retained with their path and a warning so local
edits are not deleted. Existing worktrees and fix sessions are not reused or removed.

**Have an agent make all fixes…** opens a sheet with editable default instructions
and a Codex/Claude picker. Configure the repository checkout, worktree root, and
local CLI in **Workspace** first. Starting re-fetches published comments, includes
all current local drafts and the review summary, verifies account/head/base, and
creates a fresh managed worktree at that exact head. Oversized comment context is
rejected rather than silently truncated.

The default prompt asks the agent to assess every comment, reject stale or incorrect
suggestions, apply justified fixes, run relevant tests, and commit locally. It asks
for a result summary and commit hash. Existing CLI permission defaults apply. The
app reports that a session started; inspect progress, tests, and the actual commit
in Terminal. Pushing, publishing reviews, and merging require separate actions.
These explicit actions use ordinary local sessions, without restoring Giles polling.

## Local chat and terminal sessions

Choose **Settings → Workspace chat → Configure chat agent**, or the chat gear.
The provider picker detects Codex and Claude, preferring Codex when both are installed,
and remembers the saved choice. Presets use your existing CLI sign-in and Python 3.
**Test connection** performs an explicit advisory request. A custom JSON adapter
remains supported; see the [protocol](agent-chat.md).

Chat sends the PR description, bounded diff context, selected code, and recent
conversation. Partial/truncated context is labelled. Answers render Markdown and
code; file citations navigate only to available current diff coordinates. **Stop**
cancels; failed/cancelled questions have an explicit retry without duplicating history.
Chat stays advisory; publishing is performed by workspace controls.

Ordinary Codex/Claude worktree and tmux actions, notes, and saved sessions remain.
The Giles background worker integration has been retired from the app: no launch,
polling, request/re-request, job status, connection, or permission controls. Legacy
worker files and external installations are left in place. The old CLI protocol
remains for compatibility and is not driven by the app.

## Worktree cleanup and old drafts

**Automatic merged-worktree cleanup is enabled by default.** After a successful
refresh, GitDock checks its managed worktrees and removes eligible merged work
with no live session. Fresh PR/stack state, origin head, repository registration,
local contents, account and ownership must agree. Uncommitted, untracked or ignored
files, extra local commits, live sessions and detected working-directory processes
retain the worktree with a reason. Ignored build caches can therefore block cleanup.
Local branches, notes and draft/review history are retained; Git removal is never forced.
Actual tracked bytes and executable/link types must match original HEAD objects;
Git filters cannot hide local changes. Unsupported or oversized content is retained
with an explanation (200,000 entries, 512 MiB per file and 2 GiB total verification limits).

Open **Review cleanup…** on Dashboard or **… → Worktree cleanup…** to inspect results
and change the automatic-cleanup switch. Dashboard shows **Recently auto-removed**
with each recorded worktree's name, PR title, path and removal time. The last completed
automatic check has its own timestamp and explicitly says when nothing was removed;
earlier removals remain visible after a later empty check or app restart.
**Recent cleanup activity** keeps up to 20 runs per account
(200 detailed entries per run, prioritizing confirmed removals; larger runs show a notice).
Consecutive automatic checks with no removals replace their previous check, so routine
refreshes do not crowd out removal history. Manual removals are labelled separately.
Completed removals remain recorded even if cleanup is stopped or the account changes.
If removal succeeds but saving session links fails, the worktree is listed as removed
with a follow-up warning and still counts as needing review.

GitDock also lists other Git-registered worktrees belonging to configured repository
checkouts, including paths outside the managed root. These require manual approval.
Unassociated worktrees must be clean and their exact head verified on a remote branch.
Main checkouts, locked/prunable registrations, ambiguous paths, unverifiable origins,
local-only commits and unrelated active sessions remain protected.

The app cannot prove whether a live agent is idle. Stopping live managed sessions
therefore requires explicit approval in the preview; unrelated sessions and terminal
windows/tabs are left alone. Local processes are checked by their working directory;
this does not identify every possible open editor buffer or file handle.

**… → Old drafts on GitHub…** lists the monitored account's own open drafts under
current repository scope. Dashboard flags drafts inactive for 30 days by default;
change the day threshold in the sheet. Inactivity uses GitHub's last-updated time,
including automation. Scan, select items, and confirm **Close drafts on GitHub** to
close the remote PRs. Before each write the app rechecks account, author, permissions,
draft/open state, head and activity against the preview. Changed drafts stay open;
ambiguous responses require inspecting GitHub before a fresh explicit retry.

Closing an old draft keeps its remote branch and local data. **Review local worktrees…**
then offers manual cleanup of verified clean closed-draft worktrees. Such worktrees
are never included in automatic merged-only removal.
