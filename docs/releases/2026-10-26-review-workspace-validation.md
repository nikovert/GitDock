# Review workspace validation

The 0.6.0 validation build implements the approved native management and review
workspace. See [the user guide](../review-workspace.md) and
[agent chat configuration](../agent-chat.md).

## Verification

- 154 core tests passed, including review transport, diff parsing, account and
  revision guards, process cancellation, and existing worktree cleanup regressions.
- 59 app tests passed, including persistence, stale result suppression, submission
  identity, partial diff handling, and light/dark rendering at minimum window width.
- 11 Python adapter tests passed without invoking a real provider.
- `scripts/check.sh` passed, including Swift 6 strict concurrency checks.
- Management, unified review, split review, and minimum-width renders were inspected.
- A read-only live load of `nikovert/GitDock#2` returned nine files, creation time,
  and checks successfully. No comments or reviews were published.

## Independent review

All six findings were addressed before packaging:

- Capture the account, PR, head, and base when opening the submission sheet.
- Keep drafts for changed base commits separate, even when the head is unchanged.
- Disable inline drafting when the file list or selected patch is incomplete.
- Preserve editor text and avoid success messages when local saving is unavailable.
- Avoid repeating stack sessions in the embedded workspace details.
- Distinguish unavailable reviewer metadata from a known empty reviewer list.

The affected behaviors have regression coverage. Live review mutations and real
Codex/Claude inference were not exercised. Local CLI authentication remains the
user's configuration; custom adapters are trusted local executables. Answers arrive
when complete, and viewed-file state is local rather than synchronized to GitHub.

## Artifact checks

Package with `GITHUBBAR_VERSION=0.6.0 scripts/package-validation.sh` after committing.
The script checks both architectures for the app and CLI, verifies ad-hoc signatures,
bundles the chat adapter and guide, and emits a ZIP with a SHA-256 file. Verify the
archive and checksum from the output directory before sharing it.
