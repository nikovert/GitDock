# Manage and review pull requests

GitHubBar opens its dashboard at launch and appears in the Dock and Cmd+Tab.
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

Native GitHub stacks expand into ordered member cards. Closed, merged, and members
outside the current queue are labelled navigation context. Each matching open PR
appears once. No inferred relationships are added.

Approved follows the required approval count, independently of outstanding requests
to other reviewers. GitHub's explicit aggregate decision takes precedence. When it
is absent, GitHubBar can verify eligible approvals against the active branch rules;
unavailable policy or unverified extra review requirements remain conservative.
Conflicts, CI, and unresolved conversations are separate merge-readiness checks.

Right-click a card to set manual priority, pin, snooze for 24 hours, open GitHub, or
manage its native stack. Pins and snoozes are local and account-specific.

Drag the wide dividers between PR sidebar, content, file list, and chat. Hover gives
a resize cursor and highlight; focused dividers also support arrow keys. **Layout**
contains labelled panel visibility controls, **Focus diff**, and **Reset layout**.
Widths and visibility survive reopening; smaller windows clamp panels to the space
available without losing preferred widths.

## Review code and discussion

- **Overview** shows the description, checks, urgency reason, and retained drafts
  from earlier head/base revisions.
- **Changes** shows unified or split diffs. Click a line to save a local inline
  draft or ask chat about the selection. Draft counts appear in the file list.
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

Click **Agent review** on an open PR card or in the review header. The configured
Codex, Claude, or custom review adapter receives bounded code and discussion context
in read-only mode. Findings become local drafts in **Threads** and beneath exact
available diff lines. Findings without a valid current anchor remain general drafts
with their original location explained; that explanation is preserved when posted.
No GitHub review is posted by this action. Review, edit, remove, or publish each
finding, or use **Publish all drafts…**. Repeated unchanged findings are deduplicated.
Cancellation or changing the account/PR/revision discards late results. A review
receipt shows the summary, provider, and whether context was incomplete.

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
