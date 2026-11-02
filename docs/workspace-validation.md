# Workspace improvements: local validation

Work branch: `feat/workspace-review-improvements`, based on `03057aa`.
This work is local; no release is published and no real review is posted by the checks.

## Automated checks

- Core suite: 183 tests passed, including review receipts, inline-only reviews,
  invalid/current/comparison coordinates, account/head/base changes, failed and
  ambiguous writes, and grouped root/reply/outdated anchors.
- App suite: 74 tests passed, including the final split-column and native popover
  regressions. The native popover test verifies real refresh publication preserves
  the open popover/hosting tree, controller toggling, and Escape; a visible native
  window supplies the anchor when the test host's status scene has zero height.
- Adapter fixtures: 11 tests passed for Codex/Claude commands, bounded output,
  failures, cancellation, timeout, and protocol/citation validation.
- `scripts/check.sh`: core executable checks, strict Swift 6 app typecheck,
  avatar/menu sizing checks, plist validation, and project generation passed.
- Independent static review: submission version cleanup and service checks reviewed;
  three interaction findings corrected and scoped re-review clean. Approval-policy
  review also caught schema naming, nullable legacy counts, and rules pagination;
  all corrected with regressions and a clean scoped re-review.

The rendered split-column regression first failed when an empty left annotation
collapsed its width; it passes with explicit left/right column containers. Screenshots
were inspected in light/dark appearances at 900, 1380, and 1800 point window widths,
including dashboard stacks, draft cards, grouped replies, and the chat code block.
Updated examples are in `docs/assets/`.

## Approval classification live check

The supplied [carbo PR #12853](https://github.com/carbon-re/carbo/pull/12853) returned
`reviewDecision: null` despite a current eligible approval and an active ruleset
requiring one approval. `mergeStateStatus: DIRTY` reflected conflicts, independently
of approval. With production hydration and the real rules client, a read-only,
single-PR reconciliation now produces `APPROVED`, section `approved`, and preserves
`yuchen-shang` as an outstanding requested reviewer. No GitHub state was changed.

Regression coverage includes one vs two required approvals, current and stale
opinions, dismissal/change requests, eligibility, incomplete review/policy pagination,
legacy nullable counts, explicit GitHub decision precedence, schema field selection,
and stricter later-page rules. Unknown or unsupported extra requirements do not
infer approval. Applicable policy is cached only within each reconciliation.

## Reproduce

Use full Xcode on this Mac:

```bash
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
export CLANG_MODULE_CACHE_PATH=/tmp/githubbar-clang-cache
export SWIFTPM_MODULECACHE_OVERRIDE=/tmp/githubbar-swift-cache
swift test --disable-sandbox --package-path Packages/GitHubBarCore
xcodebuild test -project GitHubBar.xcodeproj -scheme GitHubBar \
  -destination 'platform=macOS' -derivedDataPath .build/xcode \
  -parallel-testing-enabled NO CODE_SIGNING_ALLOWED=NO
python3 -m unittest discover -s scripts/tests -v
scripts/check.sh
GITHUBBAR_VERSION=0.7.0-workspace scripts/package-validation.sh
```

Within a restricted agent sandbox, Xcode cache access, Swift macro helpers, and the
standard check script may need execution outside the nested sandbox. Core SwiftPM
supports `--disable-sandbox` with the writable cache paths above. A cold SDK statistics
cache can take several minutes before build output resumes.

## Manual checks still required

Computer Use access was unavailable in this session. The following external UI checks
could not be performed; the implementation and native AppKit tests do not substitute
for a person trying them on the installed validation app:

1. Launch the validation app; check Dashboard is selected and GitHubBar appears in
   the Dock and Cmd+Tab. Close its window and click its Dock icon to restore it.
2. Open the status popover, scroll, refresh, and confirm it remains open at the same
   position. Close it with Escape, an outside click, and the status icon.
3. Drag each divider at normal and minimum window sizes. Confirm hover feedback and
   resize cursors. Toggle panels, use Focus diff, reopen, and verify restored widths
   and visibility; Reset layout restores the defaults.
4. Use a real signed-in provider's explicit Test connection, ask a selected-code
   question, cancel and retry. Controlled fixtures cover these paths automatically.
5. On a disposable PR, explicitly post one draft then a batch review. This session
   uses fake transports to cover publishing; it does not perform live GitHub writes.

Legacy worker files, external Giles processes, and the existing installed GitHubBar
were not deleted or terminated. The local validation app is ad-hoc signed and is not
notarized, consistent with the repository's existing validation build workflow.
