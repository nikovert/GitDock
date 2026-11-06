# Searching pull requests

Choose **Search PRs…** in the menu bar, or press Command-F while GitDock is active.
Type words, code identifiers, paths, or a quoted phrase. Search is literal and
case-insensitive, not AI semantic search; it does not send code to a model.

## Results and scope

**In your list** always comes first: matching PRs in your current GitDock list.
**Extended results** contains other matching PRs in the repositories selected in
the search window. Extended search includes open, draft, merged and closed PRs.
It does not search every public repository on GitHub.

In Pinned mode, the initial repository selection comes from your pins. In All
mode, it comes from repositories represented in your account workload. Add another
accessible repository using `owner/repository`, or remove repositories from the
search selection. The selection is visible before a scan starts.

Click Search (or press Return) to fetch descriptions and changed files. Extended
search must enumerate repository history to find code-only matches, so its first
scan can take time. Typing alone searches data already available locally. Pause
stops network work; reopening the window does not silently restart a paused scan.

Each match shows its title, repository, author, state and matching excerpt. File
and code matches offer a Files changed link. Click a result to open the PR in the workspace; right-click to go directly to
GitHub. Searching does not post comments, request reviews, run agents, or check
out code.

## Coverage and privacy

Check the progress and coverage text before interpreting an empty result. GitHub
can omit binary or large patches, and its PR-files endpoint is limited to 3,000
files. Partial code coverage is not proof that a PR contains no matching code.
Added, removed and available context lines are searchable, not entire unchanged
files. Changed head/base revisions invalidate previously fetched code.

Search uses the explicitly monitored GitHub account. Local cached content is
private to the current macOS user and excluded from backups, but is not encrypted
by GitDock. Account changes/disconnects and explicit repository removal purge
the corresponding search data. Clear search cache stops work before clearing it.
Search does not expose historical private cached content while offline.

History scans consume GitHub API quota. They pause when throttled and preserve
quota for the ordinary PR list. The reusable diff cache is bounded; a new query
may need to fetch older, evicted diffs again. Matching snippets for a submitted
search are retained separately so cache eviction does not erase found matches.
