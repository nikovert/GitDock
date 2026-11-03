# GitHubBar validation release

This fork's validation build is universal (`arm64` and `x86_64`), targets macOS 14
or newer, is ad-hoc signed, and is intentionally not notarized. It uses the separate
`com.nikovert.githubbar` bundle ID, so it can coexist with the upstream app. It is
not part of GitHubBar's future trusted Developer ID/Sparkle update channel.

## Fork additions

- Follow system appearance or choose Light or Dark in Settings.
- Keep local priorities, status tags, and notes for PRs and stacks.
- See PR titles, authors, requested reviewers, review status, and stack members on the board.
- Pin or create Codex/Claude worktree sessions and jump to them from the menu.
- Manage PRs in a larger window with attention queues, pins, snoozes, and activity.
- Review unified or split diffs, save inline drafts, and explicitly submit reviews.
- Navigate changed files in a GitHub-style folder tree, filter by path, and see
  viewed markers, draft counts, and discussion counts beside filenames.
- Ask a configured local agent about the selected PR or diff line. Configure this in
  Settings → Workspace chat; see the bundled `agent-chat.md` guide.
- Run **Agent review** in a fresh pinned PR worktree with complete native patches
  and surrounding code. Configure a checkout in Workspace and use Codex or Claude.
  Threads shows files reported reviewed, skipped-file reasons, and limitations.
  Findings remain local drafts; publish each or **Publish all drafts…** explicitly.
- Use **Have an agent make all fixes…** to edit the default assess/fix/test/commit
  prompt and start a fresh Codex/Claude PR worktree session. Commits stay local.
- Recognize GitHubBar by its new emerald branch app icon.
- Preview merged-worktree cleanup with PR titles, descriptions, and session choices.

Agent sessions use local tmux and the configured terminal. Chat is advisory; publishing
a review requires an explicit workspace action. The app no longer launches or polls
background review workers; existing worker data and external installations are retained.

## Install and launch

1. Download the validation ZIP from the [fork's GitHub prerelease](https://github.com/nikovert/GitHubBar/releases) and verify its adjacent SHA-256 file.
2. Quit the running GitHubBar, unzip the download, and replace `GitHubBar.app` in `/Applications`.
3. Ensure [GitHub CLI](https://cli.github.com/) is installed and connected to the accounts you want GitHubBar to inspect.
4. Open GitHubBar. The dashboard opens, and the app appears in the Dock, Cmd+Tab, and menu bar. Closing the workspace keeps the menu bar app running; click its Dock icon to reopen it.

Because this build is not Developer ID signed or notarized, macOS Gatekeeper may block the first launch after download. Control-click the app and choose Open; if macOS still blocks it, use System Settings → Privacy & Security → Open Anyway after confirming that the downloaded checksum matches the release checksum. This limitation is expected only for validation builds.

Automatic updates are explicitly disabled. Install a later validation build by replacing the app manually.

## Privacy and local data

GitHubBar retrieves a temporary token from GitHub CLI into process memory. It never stores that token. Preferences contain the selected account login, repository scope, cadence, and general settings. The active PR snapshot is stored in Application Support with owner-only permissions. Local OSLog diagnostics contain refresh reason, timing, cost, counts, completeness, and failure categories—not tokens, headers, GraphQL bodies, repository names, PR titles, or usernames.

## Maintainer verification

Run from a clean checkout:

```sh
scripts/check.sh
GITHUBBAR_VERSION=0.9.1 scripts/package-validation.sh
lipo -archs .build/validation/GitHubBar.app/Contents/MacOS/GitHubBar
codesign --verify --deep --strict --verbose=2 .build/validation/GitHubBar.app
plutil -extract CFBundleIdentifier raw .build/validation/GitHubBar.app/Contents/Info.plist
```

Expected architecture output contains `arm64` and `x86_64`; the bundle ID is
`com.nikovert.githubbar`. The packaging script also validates the plist, checks the
ad-hoc signature, scans the executable for test credential markers, and emits an
adjacent SHA-256 file.

After installing the latest build, test these paths in order:

1. **Launch and reopen:** confirm Dashboard opens and GitHubBar appears in Dock and
   Cmd+Tab. Close the workspace, then reopen it from the Dock; the menu bar app
   should keep running.
2. **Approval classification:** refresh PR `carbon-re/carbo#12853`. If it still has
   the required approval, it should appear under Approved even with another reviewer
   requested. Conflicts and CI remain separate merge-readiness checks.
3. **Persistent popover:** open the status icon, scroll, and refresh. It should stay
   open at the same position. Check Escape, outside click, and status-icon closing.
4. **Layout:** drag the PR, file, and chat dividers; check the resize cursor/hover
   feedback. Hide each panel, try Focus diff, reopen, and check saved widths and
   visibility. Reset layout should restore defaults. Try a small window and dark mode.
5. **Drafts and Threads:** save an inline draft on each diff side, switch unified/split,
   and navigate using Threads → Show in diff. Editing/removing should update both views.
   Outdated conversations must stay labelled rather than attaching to guessed lines.
6. **Local chat:** choose Codex or Claude, Test connection, and ask about a selected
   line. Test Stop, Retry, code rendering, citations, Enter to send, and Ctrl+Enter
   for a newline.
7. **Agent review:** configure a repository checkout/worktree root in Workspace and
   choose Codex or Claude in chat settings. Review a PR with more than six changed
   files or a large patch. Check that Threads reports the full changed-file count,
   any skipped files/limitations, and no claim of tests running. Inspect both diff layouts.
   Findings must stay local until you explicitly post them. Test cancellation,
   editing/removing findings, individual posting, and Publish all. Unavailable
   locations must remain labelled general drafts. Clean temporary review worktrees
   should disappear; retained worktrees must have a visible warning/path. A missing
   checkout must offer setup rather than silently run an excerpt review.
8. **Fix session on a disposable PR:** configure a local checkout/worktree root,
   open **Have an agent make all fixes…**, inspect/reset/edit its prompt, choose
   Codex/Claude, and start. Confirm Terminal opens at the PR head. Check that it
   assessed published comments and local drafts, tested changes, and committed
   locally. Check the commit yourself; the app does not claim completion or push it.
9. **Optional live publishing on a disposable PR:** create two drafts and a summary.
   Post one draft individually; the other and summary must remain. Then submit the
   remaining draft as a Comment without a summary. Check GitHub for exactly the
   intended comments. Changes made during a submission should remain local.

Existing account selection, repository scope, pins/snoozes, notes, terminal sessions,
refresh health, and merged-worktree cleanup should continue to work. Automatic updates
remain disabled in validation builds. See [the validation record](../workspace-validation.md)
for automated coverage and the manual checks that could not be performed in the agent session.

## Publish a prerelease

Push a tag matching `validation-v*` (for example `validation-v0.2.0-1`). The
validation release workflow builds the artifact from that commit and creates a GitHub
prerelease with the ZIP, checksum, and these notes. The workflow can also be started
manually with a new validation tag.
