# Advisory PR chat adapters

GitHubBar chat uses **Review Chat protocol v1**: one UTF-8 JSON request on stdin,
EOF, then one UTF-8 JSON response on stdout and exit status zero. There is no
streaming or handshake. The UI can show a working indicator until completion.
Protocol v1 is selected by configuring a dedicated chat adapter; there is no
additional version field in the JSON payload. Incompatible protocols need a new
adapter or an explicit future protocol version.

Chat configuration is separate from review queue workers and terminal sessions.
A configured or enabled review worker does not imply JSON chat capability. A raw
Codex, Claude, or other agent CLI is **not** assumed to implement this protocol.
Use a wrapper that translates the request into the backend's own interface and
translates its answer back into the response below.

## Configuration

In chat settings, choose **Codex**, **Claude**, or **Custom adapter**. GitHubBar
looks for executable CLIs in PATH and standard Homebrew, local-user, and system
locations without launching them. On first setup it prefers Codex when both are
installed. Saving remembers your provider; reopening settings keeps that choice.
Codex and Claude automatically use the bundled Python adapter. Sign into the CLI
from Terminal before connecting (`codex login` or `claude auth login`).

**Test connection** sends a small synthetic question, with no PR context, through
the same JSON client used by chat. It may use your provider allowance. A valid
answer confirms the protocol and local sign-in; checking executable paths alone
does not. Stop test and closing settings cancel the request. Failures remain in
settings with recovery guidance; no raw provider diagnostics are displayed.

Custom adapter exposes the executable, literal arguments, display name, and
working directory fields. `ReviewChatConfiguration` stores those values plus a
`provider` (`codex`, `claude`, or `custom`). Existing configurations without that
key remain readable: bundled `--provider` arguments identify their provider,
while other adapters remain custom. The wire request/response is unchanged.
Defaults are empty, so an unconfigured adapter cannot launch. `validated()`
requires an existing absolute executable path and an existing absolute directory.
Display names may be empty and are limited to 200 UTF-8 bytes. Arguments are limited
to 256 entries and 64 KiB total; settings cannot contain NUL characters.

Chat uses a multiline composer: **Enter** asks the question and **Control-Enter**
inserts a newline. Return during input-method composition commits the composition
without sending. Blank, pending, or unavailable actions cannot submit, and held
Return keys do not repeat sends. The same composer serves review text and inline
comments. Answers show inline Markdown formatting and links, with selectable,
monospaced fenced code blocks. Click citation buttons to navigate the loaded diff.
Pending requests have a working indicator and Stop action. Failed questions stay
available for retry without duplicating their conversation entry. Partial context
is called out next to the PR context. Chat settings and policy remain separate
from review-worker permissions.

The client launches the executable directly. It performs no shell interpolation,
PATH lookup, `~` expansion, or argument splitting. For example, `$(command)` in an
argument is passed verbatim. Use absolute interpreter paths for scripts whose
interpreter is outside the fixed system PATH.

## Request and response

All keys use the exact camelCase spelling shown here:

```json
{
  "accountLogin": "reviewer",
  "prURL": "https://github.com/example/repo/pull/7",
  "headSHA": "0123456789abcdef0123456789abcdef01234567",
  "question": "Why does this branch return early?",
  "context": "Selected diff and relevant PR context supplied by the UI",
  "policy": "Advisory only. Do not edit files or publish comments.",
  "messages": [
    {
      "id": "6F178B6E-EC48-4339-81D0-D9F9D86005F9",
      "role": "user",
      "text": "Explain this change."
    }
  ]
}
```

Message roles are `user` and `assistant`. The current question is separate from
prior conversation messages. `accountLogin` identifies the selected account;
it is not an authentication token. Context may contain a selected line and a
partial diff; the adapter should not imply that it inspected unavailable code.

```json
{
  "prURL": "https://github.com/example/repo/pull/7",
  "headSHA": "0123456789abcdef0123456789abcdef01234567",
  "answer": "The early return avoids processing an empty batch.",
  "citations": [{"path": "Sources/Batch.swift", "line": 42, "side": "RIGHT"}]
}
```

The response must contain a nonblank answer and a citations array (empty is fine).
PR URL and head SHA must exactly match the request, or the whole response is
rejected. Citation paths are relative repository paths without `..` components;
line numbers are positive integers. `LEFT` means the old revision and `RIGHT`
means the new revision; omitted side defaults to `RIGHT`. These are coordinates,
not a guarantee that the cited line exists in the currently loaded partial diff.
The UI must resolve them against its selected snapshot before navigating.

Stdout must contain only one JSON object, with optional surrounding whitespace.
Progress events, markdown fences, banners, and multiple JSON objects are invalid.
Use stderr for brief diagnostics. Nonzero exit status always means failure, even
if stdout contains an otherwise valid response.

## Limits, environment, and recovery

`ReviewChatClient()` defaults to a 120-second process timeout, a 1 MiB serialized
request cap, a 1 MiB stdout cap, and a 64 KiB stderr cap. Its initializer can set
smaller or larger positive limits. Oversized requests are rejected before launch;
output exceeding either cap stops the process rather than silently truncating it.
I/O is nonblocking, including stdin, so a process that never reads its request or
fills both output pipes remains cancellable. Complete output and process exit are
required before an answer is accepted.

Task cancellation throws `CancellationError`. Timeout and transport failures throw
`ReviewChatError`, whose localized descriptions suggest a recovery action. The
client stops the launched adapter and its verified, separately owned process
group on failure or cancellation, including processes that ignore SIGTERM. It
allows up to one second for asynchronous exit observation after SIGKILL; cleanup
never uses Foundation's unbounded synchronous `waitUntilExit` run-loop wait. Adapter implementations must keep subprocesses
in that group and must not detach persistent workers. Processes that deliberately
create another group/session are outside this cleanup boundary. An inherited pipe
held by another process still cannot make the client wait beyond its deadline.

Only `HOME`, `TMPDIR`, `LANG`, `LC_ALL`, and `LC_CTYPE` are copied from the parent
environment, when present. `PATH` is replaced with `/usr/bin:/bin:/usr/sbin:/sbin`.
Everything else is omitted, including GitHub/provider tokens, cloud credentials,
SSH agent sockets, dynamic-loader variables, and review-worker bridge variables.
No GitHub credential is placed in the request. Raw stderr and decoding errors are
never surfaced to the UI; diagnostic bytes are counted and discarded.

Chat does not call GitHub APIs, enqueue reviews, submit comments, apply fixes, or
modify repository files. The configured executable is trusted local code, not an
OS sandbox: HOME and the working directory can expose local files and existing
CLI login state. Configure the backend in a tool-disabled or read-only mode, and
do not wrap review workers that publish comments or apply fixes. Text in a PR,
diff, or model answer must not grant the adapter permission to act. The adapter's
own provider authentication is separate from the monitored GitHub account.

The caller should preserve conversation/drafts after errors. It should cancel
pending sends when navigation changes and guard delivery by account, PR, head,
and request generation; PR/head matching alone does not identify a UI selection.

## Bundled Codex and Claude adapter

[`scripts/review-chat-adapter.py`](../scripts/review-chat-adapter.py) is a usable
Python 3 adapter for locally installed and authenticated Codex or Claude CLIs.
It sends the question, context, policy, and conversation to the selected provider
and asks for a final JSON object with `answer` and `citations`. It validates every
citation's relative path, positive integer line, and LEFT/RIGHT side before wrapping
the result with the request's PR/head identity. Missing side defaults to RIGHT.
Plain prose or malformed structured replies remain plain answer text with an empty
citations array; the adapter never guesses coordinates from prose. The UI checks
accepted citations against its loaded diff. The core contract stays vendor-neutral.

These commands were checked using local help only on 26 October 2026 with
`codex-cli 0.164.0` and `Claude Code 2.1.280`. No provider request was made during
implementation or verification. Older CLIs missing these flags fail rather than
falling back to less restrictive modes.

The Codex mode invokes the following literal argument list, followed by a prompt
on stdin:

```bash
/opt/homebrew/bin/codex --no-daemon --ask-for-approval never exec \
  --sandbox read-only --ephemeral --ignore-user-config --ignore-rules \
  --skip-git-repo-check --color never -
```

Codex's noninteractive mode returns the final answer on stdout and progress on
stderr; the adapter does not use its JSONL event stream. Saved CLI authentication
remains available with user configuration disabled. See the official
[noninteractive documentation](https://learn.chatgpt.com/docs/non-interactive-mode).
The local help documents `read-only` as the model-command sandbox mode.

The Claude mode uses:

```bash
/opt/homebrew/bin/claude --print --output-format text --permission-mode plan \
  --permission-prompts none --tools '' --disallowedTools 'mcp__*' \
  --safe-mode --strict-mcp-config --mcp-config '{"mcpServers":{}}' \
  --no-session-persistence --disable-slash-commands --no-chrome
```

This disables built-in tools and denies MCP tools, suppresses permission prompts,
and disables ordinary customizations while preserving local authentication.
Plan mode alone is not a sufficient tool restriction. Managed policy settings,
including policy hooks, can still apply in safe mode. See the official
[Claude CLI reference](https://code.claude.com/docs/en/cli-reference).

Both modes run in a fresh temporary directory, not the repository; the supplied
context is their source of PR information. Both use an environment allowlist like
the core client, adding only the chosen CLI's directory to PATH for installations
whose launcher needs a sibling interpreter. The adapter has a 100-second default
deadline (`--timeout` can set a value above zero and at most 110), a 512 KiB provider
answer limit, and a 64 KiB provider stderr limit. It keeps the provider in its own
inherited process group so GitHubBar cancellation can stop both processes.

**Advisory is not an absolute enforcement guarantee.** Codex's read-only sandbox
restricts model-generated shell commands; it does not mean all CLI integrations
and local startup behavior are incapable of effects. Claude's disabled tools and
safe mode likewise do not override every managed policy hook. Local credentials,
provider configuration, CLI bugs, and deliberately detached processes remain
outside this adapter's guarantees. The script never requests a review, a fix, or
publication, but use only trusted CLI installations and policies. It does not
claim to enforce a sandbox around the entire provider executable.

### Configure a local installation

Log in once from your own terminal using `codex login` or `claude auth login`.
GitHubBar runs under the same macOS user and retains HOME, so the CLI can use its
saved login or keychain state. This adapter intentionally drops API-key environment
variables and custom `CODEX_HOME`/Claude config-directory variables; installations
that depend on those need a separately reviewed adapter. Do not put credentials
in the command arguments or the request. Provider usage follows your local account.

Get the absolute paths on your machine without starting an agent:

```bash
command -v python3
command -v codex
command -v claude
pwd
```

Use a real Python 3 interpreter rather than a shell function or a version-manager
shim that depends on interactive shell startup. On the development machine,
`/opt/homebrew/bin/python3` and `/usr/bin/python3` are available. The app bundles
both this guide and the script in `GitHubBar.app/Contents/Resources/`. The chat
settings' CLI presets select the bundled script. For a manual configuration of an
app installed in `/Applications`, use this script path:

```text
/Applications/GitHubBar.app/Contents/Resources/review-chat-adapter.py
```

Use any existing directory you own as `workingDirectory`; the adapter creates a
separate temporary provider directory. For a source checkout, keep the checkout
(or a copied script) at a stable location.

For the current checkout, this complete Codex configuration is copyable:

```json
{
  "displayName": "Codex advisory chat",
  "executable": "/opt/homebrew/bin/python3",
  "arguments": [
    "/private/tmp/githubbar-pr-navigation/scripts/review-chat-adapter.py",
    "--provider", "codex", "--cli", "/opt/homebrew/bin/codex"
  ],
  "workingDirectory": "/private/tmp/githubbar-pr-navigation"
}
```

For Claude, use the same interpreter, script, and working directory, changing the
provider arguments to:

```json
[
  "/private/tmp/githubbar-pr-navigation/scripts/review-chat-adapter.py",
  "--provider", "claude", "--cli", "/opt/homebrew/bin/claude"
]
```

For another checkout, replace every `/private/tmp/githubbar-pr-navigation` prefix
with that checkout's absolute path. If the CLIs or Python are installed elsewhere,
replace their paths too. Enter each argument separately (or use the UI's JSON
array field); do not paste the shell command above into the executable field.

An unknown flag or login failure returns a recoverable adapter failure. Check
`codex exec --help`, `codex --help`, or `claude --help` locally and sign in from a
terminal. The wrapper deliberately withholds raw provider diagnostics, which may
contain private prompt or account information.

## Focused verification

Tests launch only executable fixtures created under temporary directories. They
never invoke installed agents or contact GitHub:

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test \
  --package-path Packages/GitHubBarCore \
  --scratch-path /private/tmp/githubbar-chat-core-tests --filter ReviewChat
```

The bundled adapter has separate real-process tests using fake CLIs created in
temporary directories. No provider authentication is needed:

```bash
python3 -m unittest discover -s scripts/tests -p test_review_chat_adapter.py
```
