# Search and configurable reviewers validation build

This feature adds **Search PRs…** (Command-F) and **Settings → Review agent**.

Search returns **In your list** first and **Extended results** second. It matches
titles, descriptions, changed paths and available added/removed/context code.
Extended search includes all PR states in explicitly selected repositories. It
reports incomplete patches, scan progress, throttling and cache eviction rather
than implying that unsearched code has no matches. See [PR search](../pr-search.md).

Review workers are configured locally by display name, executable, literal
arguments and working directory, or managed externally. No particular bot or
personal priority-author list is built into GitDock. Set preferred authors in
Settings. Existing review policies and queued jobs remain compatible. See
[agent reviews](../agent-reviews.md) for the generic worker protocol.

## Validation and boundaries

- Automated core and macOS app suites cover search, privacy boundaries, policy
  defaults, process configuration, priority and schema migration.
- Light and dark search renders were inspected using fixture data.
- A fresh independent review found startup cache deletion and lost partial-code
  coverage after resume; both received failing-then-passing regression tests.
- The package is universal Apple silicon/Intel and ad-hoc signed, not notarized.
- No live GitHub PR writes, merge, push, publication or installed-app replacement
  are part of this delivery.

The first history scan can consume substantial GitHub quota. Live-GitHub and
large-history stress validation remain to be done. HTTP response size limits are
checked after buffering; the reusable diff cache is bounded separately. Coverage
on resume is reconstructed from stored repository metadata, not just matching PRs.

A bare coding CLI is not a compatible review worker. Claude/Codex-based workflows
need an adapter implementing queue claims, leases, policy enforcement and result
updates. Configuration testing validates paths and arguments, not a protocol
handshake. Managed Stop controls the direct foreground worker; its adapter must
supervise and terminate its children. No third-party adapter was exercised here.

For installation, verify the adjacent SHA-256 file, unzip the app, quit your
current GitDock, and replace it in Applications. Keep the prior app available
if you want to roll back. This does not automatically install the build.
