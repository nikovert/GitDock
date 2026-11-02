"""Real-process adapter tests; no installed provider CLI is ever invoked."""

import json
import os
import pwd
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import time
import unittest


ADAPTER = Path(__file__).resolve().parents[1] / "review-chat-adapter.py"
REQUEST = {
    "accountLogin": "reviewer",
    "prURL": "https://github.com/example/repo/pull/7",
    "headSHA": "abc123",
    "question": "Explain this branch",
    "context": "selected diff",
    "policy": "Advisory only",
    "messages": [],
}


class ReviewChatAdapterTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="chat-adapter-tests-")
        self.addCleanup(self.temporary.cleanup)
        self.directory = Path(self.temporary.name)
        self.cli = self.directory / "fake cli ; literal"
        self.environment = {
            "HOME": str(self.directory),
            "PATH": "/usr/bin:/bin",
            "GH_TOKEN": "fixture-github-token",
            "OPENAI_API_KEY": "fixture-provider-token",
            "GITHUBBAR_WORKSPACE_CLI": "must-not-inherit",
        }

    def fake(self, body):
        prelude = """
import json,sys
def emit_answer(text):
    if '--json' in sys.argv:
        print(json.dumps({'type':'item.completed','item':{'type':'agent_message','text':text}}))
        print(json.dumps({'type':'turn.completed'}))
    else:
        print(text)
"""
        self.cli.write_text(f"#!{sys.executable}\n" + prelude + body + "\n")
        self.cli.chmod(0o700)

    def command(self, provider="codex", *extra):
        return [sys.executable, str(ADAPTER), "--provider", provider,
                "--cli", str(self.cli), *extra]

    def run_adapter(self, provider="codex", raw=None, extra=()):
        return subprocess.run(
            self.command(provider, *extra),
            input=json.dumps(REQUEST).encode() if raw is None else raw,
            stdout=subprocess.PIPE, stderr=subprocess.PIPE,
            cwd=self.directory, env=self.environment, timeout=5,
        )

    def test_large_codex_prompt_uses_events_instead_of_echoing_to_stderr(self):
        self.fake("""
import json,sys
prompt = sys.stdin.read()
if '--json' not in sys.argv:
    sys.stderr.write(prompt);sys.stderr.flush()
else:
    print(json.dumps({'type':'item.completed','item':{'type':'reasoning','text':'progress'}}))
    print(json.dumps({'type':'item.completed','item':{'type':'agent_message','text':'{"answer":"Reviewed","citations":[],"findings":[]}'}}))
    print(json.dumps({'type':'turn.completed'}))
""")
        result = self.run_adapter(raw=json.dumps({**REQUEST,"task":"review","context":"x"*96000}).encode())
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(result.stdout)["findings"], [])

    def test_codex_events_require_successful_completion_and_ignore_progress(self):
        answer = json.dumps({"answer":"Reviewed", "citations":[], "findings":[]})
        message = {"type":"item.completed","item":{"type":"agent_message","text":answer}}
        for events, success in [([{"type":"item.completed","item":{"type":"reasoning","text":"SECRET"}},message,{"type":"turn.completed"}],True),
                                ([message],False),([message,{"type":"turn.failed"}],False),
                                ([message,{"type":"error","message":"SECRET"},{"type":"turn.completed"}],False),
                                ([{"type":"turn.completed"}],False),([{"type":"turn.completed"},message],False)]:
            self.fake("import json\n" + "\n".join("print("+repr(json.dumps(event))+")" for event in events))
            result = self.review()
            self.assertEqual(result.returncode==0, success, result.stderr)
            self.assertNotIn(b'SECRET', result.stdout+result.stderr)

    def test_codex_large_progress_is_discarded_and_final_answer_remains_bounded(self):
        self.fake("""
import json
for _ in range(100):
    print(json.dumps({'type':'item.completed','item':{'type':'reasoning','text':'SECRET_PROGRESS'*100}}))
emit_answer('{"answer":"Reviewed","citations":[],"findings":[]}')
""")
        result = self.review()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertNotIn(b'SECRET_PROGRESS', result.stdout+result.stderr)
        self.assertEqual(json.loads(result.stdout)['answer'], 'Reviewed')
        self.fake("emit_answer('x' * 524289)")
        result = self.run_adapter()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn(b'providerOutputLimit', result.stderr)

    def test_codex_event_stream_flood_still_stops_at_a_finite_limit(self):
        self.fake("import json\nwhile True: print(json.dumps({'type':'item.completed','item':{'type':'reasoning','text':'x'*8192}}))")
        result = self.run_adapter()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn(b'providerOutputLimit', result.stderr)
        self.assertEqual(result.stdout, b'')

    def test_codex_split_utf8_and_final_event_without_newline(self):
        answer = json.dumps({'answer':'é'*10,'citations':[],'findings':[]},ensure_ascii=False)
        stream = json.dumps({'type':'item.completed','item':{'type':'agent_message','text':answer}},ensure_ascii=False)+'\n'+json.dumps({'type':'turn.completed'})
        self.fake("import os\nfor byte in " + repr(stream.encode()) + ": os.write(1,bytes([byte]))")
        result = self.review()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(result.stdout)['answer'], 'é'*10)

    def test_codex_wraps_answer_and_passes_context_with_read_only_flags(self):
        self.fake("""
import json, os, sys
emit_answer(json.dumps({'argv': sys.argv[1:], 'prompt': sys.stdin.read(),
                  'cwd': os.getcwd(), 'environment': dict(os.environ)}))
""")
        result = self.run_adapter()
        self.assertEqual(result.returncode, 0, result.stderr)
        response = json.loads(result.stdout)
        self.assertEqual(response["prURL"], REQUEST["prURL"])
        self.assertEqual(response["headSHA"], "abc123")
        self.assertEqual(response["citations"], [])
        observed = json.loads(response["answer"])
        argv = observed["argv"]
        self.assertEqual(argv[:4], ["--no-daemon", "--ask-for-approval", "never", "exec"])
        self.assertEqual(argv[argv.index("--sandbox") + 1], "read-only")
        for option in ["--ephemeral", "--ignore-user-config", "--ignore-rules", "--skip-git-repo-check"]:
            self.assertIn(option, argv)
        self.assertEqual(argv[-1], "-")
        self.assertIn("--json", argv)
        self.assertNotIn("--dangerously-bypass-approvals-and-sandbox", argv)
        sent = json.loads(observed["prompt"].split("\nREQUEST_JSON:\n", 1)[1])
        self.assertEqual(sent, REQUEST)
        self.assertNotEqual(observed["cwd"], str(self.directory))
        for key in ["GH_TOKEN", "OPENAI_API_KEY", "GITHUBBAR_WORKSPACE_CLI"]:
            self.assertNotIn(key, observed["environment"])
        self.assertEqual(observed["environment"]["HOME"], str(self.directory))

    def test_provider_receives_os_username_for_keychain_without_inheriting_credentials(self):
        self.fake("import json,os;print(json.dumps(dict(os.environ)))")
        self.environment.pop("USER", None)
        result = self.run_adapter("claude")
        self.assertEqual(result.returncode, 0, result.stderr)
        environment = json.loads(json.loads(result.stdout)["answer"])
        self.assertEqual(environment.get("USER"), pwd.getpwuid(os.getuid()).pw_name)
        for key in ["GH_TOKEN", "OPENAI_API_KEY", "GITHUBBAR_WORKSPACE_CLI"]:
            self.assertNotIn(key, environment)

    def test_invalid_request_reports_specific_safe_code(self):
        self.fake("raise SystemExit('must not start')")
        result = self.run_adapter(raw=b'{}')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn(b'GITHUBBAR_ADAPTER_ERROR_V1:{"code":"invalidRequest"}', result.stderr)

    def test_claude_disables_tools_and_mcp_and_uses_noninteractive_text(self):
        self.fake("import json, sys; print(json.dumps(sys.argv[1:]))")
        result = self.run_adapter("claude")
        self.assertEqual(result.returncode, 0, result.stderr)
        argv = json.loads(json.loads(result.stdout)["answer"])
        for option in ["--print", "--safe-mode", "--strict-mcp-config", "--no-session-persistence"]:
            self.assertIn(option, argv)
        for key, value in [("--tools", ""), ("--output-format", "text"),
                           ("--permission-mode", "plan"), ("--permission-prompts", "none"),
                           ("--disallowedTools", "mcp__*")]:
            self.assertEqual(argv[argv.index(key) + 1], value)
        self.assertEqual(json.loads(argv[argv.index("--mcp-config") + 1]), {"mcpServers": {}})
        self.assertNotIn("--dangerously-skip-permissions", argv)

    def test_structured_answer_preserves_valid_citations_and_request_identity(self):
        provider_response = {
            "answer": "The old branch skipped an empty batch.",
            "citations": [{"path": "Sources/Batch.swift", "line": 12, "side": "LEFT"},
                          {"path": "Sources/Batch.swift", "line": 14}],
            "prURL": "https://github.com/wrong/repo/pull/9", "headSHA": "wrong",
        }
        self.fake("emit_answer(" + repr(json.dumps(provider_response)) + ")")
        result = self.run_adapter()
        self.assertEqual(result.returncode, 0, result.stderr)
        response = json.loads(result.stdout)
        self.assertEqual(response["answer"], provider_response["answer"])
        self.assertEqual(response["citations"], [
            {"path": "Sources/Batch.swift", "line": 12, "side": "LEFT"},
            {"path": "Sources/Batch.swift", "line": 14, "side": "RIGHT"},
        ])
        self.assertEqual(response["prURL"], REQUEST["prURL"])
        self.assertEqual(response["headSHA"], REQUEST["headSHA"])

    def test_invalid_structured_citations_fall_back_to_text_without_coordinates(self):
        for citation in [
            {"path": "../secret", "line": 1}, {"path": "/secret", "line": 1},
            {"path": "file", "line": 0}, {"path": "file", "line": True},
            {"path": "file", "line": 1, "side": "OTHER"},
        ]:
            with self.subTest(citation=citation):
                raw = json.dumps({"answer": "Advice", "citations": [citation]})
                self.fake("emit_answer(" + repr(raw) + ")")
                result = self.run_adapter()
                self.assertEqual(result.returncode, 0, result.stderr)
                response = json.loads(result.stdout)
                self.assertEqual(response["answer"], raw)
                self.assertEqual(response["citations"], [])

    def test_plain_text_answer_never_invents_citation_coordinates(self):
        self.fake("print('Consider the guard in Sources/Batch.swift:12.')")
        result = self.run_adapter("claude")
        self.assertEqual(result.returncode, 0, result.stderr)
        response = json.loads(result.stdout)
        self.assertEqual(response["answer"], "Consider the guard in Sources/Batch.swift:12.")
        self.assertEqual(response["citations"], [])

    def review(self, provider="codex"):
        return self.run_adapter(provider, raw=json.dumps({**REQUEST, "task": "review"}).encode())

    def test_claude_review_uses_native_schema_and_unwraps_validated_output(self):
        marker = self.directory / "schema-argv.json"
        payload = {"answer": "Reviewed", "citations": [], "findings": [{"body": "Fix fallback", "path": None, "line": None, "side": None}]}
        envelope = {"type": "result", "is_error": False, "structured_output": payload}
        self.fake("import json,sys\nopen(" + repr(str(marker)) + ",'w').write(json.dumps(sys.argv[1:]))\nprint(" + repr(json.dumps(envelope)) + ")")
        result = self.review("claude")
        self.assertEqual(result.returncode, 0, result.stderr)
        response = json.loads(result.stdout)
        self.assertEqual(response["findings"], [{"body": "Fix fallback"}])
        argv = json.loads(marker.read_text())
        self.assertEqual(argv[argv.index("--output-format") + 1], "json")
        schema = json.loads(argv[argv.index("--json-schema") + 1])
        self.assertIn("findings", schema["required"])
        self.assertEqual(argv[argv.index("--tools") + 1], "")

    def test_claude_review_rejects_failed_or_missing_structured_output(self):
        for envelope in [{"type": "result", "is_error": True, "structured_output": {"answer": "No issues", "citations": [], "findings": []}},
                         {"type": "result", "is_error": False, "result": "No issues"}]:
            self.fake("print(" + repr(json.dumps(envelope)) + ")")
            result = self.review("claude")
            self.assertNotEqual(result.returncode, 0)
            self.assertEqual(result.stdout, b"")
            self.assertIn(b'invalidReviewResponse', result.stderr)

    def test_review_returns_structured_findings_for_both_providers(self):
        findings = [{"body": "Check empty input", "path": "src/file.swift", "line": 12, "side": "LEFT"},
                    {"body": "Document migration"}, {"body": "Need more context", "path": "missing.swift"}]
        payload = {"answer": "Reviewed supplied changes", "citations": [], "findings": findings}
        self.fake("import json,sys\npayload=" + repr(payload) + "\nemit_answer(json.dumps({'type':'result','is_error':False,'structured_output':payload} if '--json-schema' in sys.argv else payload))")
        for provider in ("codex", "claude"):
            with self.subTest(provider=provider):
                result = self.review(provider)
                self.assertEqual(result.returncode, 0, result.stderr)
                response = json.loads(result.stdout)
                self.assertEqual(response["findings"], findings)
                self.assertEqual(response["prURL"], REQUEST["prURL"])

    def test_review_accepts_explicit_empty_findings(self):
        self.fake('emit_answer(\'{"answer":"Reviewed","citations":[],"findings":[]}\')')
        result = self.review()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(result.stdout)["findings"], [])

    def test_review_rejects_legacy_prose_and_malformed_or_unbounded_findings(self):
        invalid = [None, "prose", [{"path": "file"}], [{"body": "  "}], [{"body": "x\0y"}],
                   [{"body": "x", "line": True}], [{"body": "x", "line": 0}],
                   [{"body": "x", "side": "OTHER"}], [{"body": "x", "path": "../file"}],
                   [{"body": "é" * 8193}], [{"body": "x"}] * 101,
                   [{"body": "x" * 16384}] * 17]
        outputs = ["No issues found", json.dumps({"answer": "Legacy", "citations": []})]
        outputs += [json.dumps({"answer": "Reviewed", "citations": [], "findings": value}) for value in invalid]
        outputs += [json.dumps({"answer": "Reviewed", "citations": [{"path": "file", "line": 0}], "findings": []}),
                    json.dumps({"answer": "", "citations": [], "findings": []}),
                    json.dumps({"answer": "Reviewed", "findings": []})]
        for output in outputs:
            with self.subTest(output=output[:100]):
                self.fake("emit_answer(" + repr(output) + ")")
                result = self.review()
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(result.stdout, b"")
                self.assertIn(b"review", result.stderr.lower())

    def test_review_prompt_keeps_read_only_flags_and_context_as_data(self):
        marker = self.directory / "observed.json"
        self.fake("import json,sys\nopen(" + repr(str(marker)) + ", 'w').write(json.dumps({'argv':sys.argv[1:], 'prompt':sys.stdin.read()}))\n"
                  "payload={'answer':'Reviewed','citations':[],'findings':[]}\nemit_answer(json.dumps({'type':'result','is_error':False,'structured_output':payload} if '--json-schema' in sys.argv else payload))")
        for provider in ("codex", "claude"):
            result = self.review(provider)
            self.assertEqual(result.returncode, 0, result.stderr)
            observed = json.loads(marker.read_text())
            sent = json.loads(observed["prompt"].split("\nREQUEST_JSON:\n", 1)[1])
            self.assertEqual(sent, {**REQUEST, "task": "review"})
            self.assertIn("findings", observed["prompt"])
            if provider == "codex":
                self.assertEqual(observed["argv"][observed["argv"].index("--sandbox") + 1], "read-only")
            else:
                self.assertEqual(observed["argv"][observed["argv"].index("--tools") + 1], "")

    def test_unknown_task_is_rejected_before_backend_launch(self):
        marker = self.directory / "started"
        self.fake(f"open({str(marker)!r}, 'w').close()")
        result = self.run_adapter(raw=json.dumps({**REQUEST, "task": "fix-and-publish"}).encode())
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(marker.exists())

    def test_nonzero_exit_and_invalid_utf8_do_not_leak_provider_output(self):
        for body in ["import sys; print('PRIVATE'); print('SECRET', file=sys.stderr); sys.exit(7)",
                     "import sys; sys.stdout.buffer.write(b'\\xff')"]:
            with self.subTest(body=body):
                self.fake(body)
                result = self.run_adapter()
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(result.stdout, b"")
                self.assertNotIn(b"SECRET", result.stderr)
                self.assertNotIn(b"PRIVATE", result.stderr)

    def test_output_and_diagnostics_are_bounded(self):
        for stream in ["stdout", "stderr"]:
            with self.subTest(stream=stream):
                self.fake(f"import sys\nwhile True: sys.{stream}.write('x' * 8192); sys.{stream}.flush()")
                result = self.run_adapter()
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(result.stdout, b"")
                self.assertIn(b"limit", result.stderr.lower())
                self.assertLess(len(result.stderr), 1024)

    def test_logged_out_provider_reports_login_recovery_without_echoing_output(self):
        self.fake("import sys; print('Not logged in · Please run /login');sys.exit(1)")
        result = self.run_adapter()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn(b'GITHUBBAR_ADAPTER_ERROR_V1:{"code":"providerNotAuthenticated"}', result.stderr)
        self.assertEqual(result.stdout, b'')

    def test_failed_provider_reports_only_a_known_machine_code(self):
        self.fake("import sys; print('SECRET',file=sys.stderr);sys.exit(7)")
        result = self.run_adapter()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn(b'GITHUBBAR_ADAPTER_ERROR_V1:{"code":"providerFailed"}', result.stderr)
        self.assertNotIn(b'SECRET', result.stderr)

    def test_timeout_reaps_backend_that_ignores_term(self):
        pid_file = self.directory / "pid"
        self.fake(f"import os, signal, time\nsignal.signal(signal.SIGTERM, signal.SIG_IGN)\nopen({str(pid_file)!r}, 'w').write(str(os.getpid()))\ntime.sleep(30)")
        result = self.run_adapter(extra=("--timeout", "0.3"))
        self.assertNotEqual(result.returncode, 0)
        self.assertIn(b"timed out", result.stderr)
        self.assertIn(b'GITHUBBAR_ADAPTER_ERROR_V1:{"code":"providerTimedOut"}', result.stderr)
        self.assert_gone(int(pid_file.read_text()))

    def test_termination_reaps_backend(self):
        pid_file = self.directory / "pid"
        self.fake(f"import os, time\nopen({str(pid_file)!r}, 'w').write(str(os.getpid()))\ntime.sleep(30)")
        process = subprocess.Popen(self.command(), stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                   stderr=subprocess.PIPE, cwd=self.directory, env=self.environment)
        try:
            process.stdin.write(json.dumps(REQUEST).encode())
            process.stdin.close()
            for _ in range(200):
                if pid_file.exists():
                    break
                time.sleep(0.01)
            self.assertTrue(pid_file.exists())
            pid = int(pid_file.read_text())
            process.terminate()
            process.wait(timeout=3)
            self.assert_gone(pid)
        finally:
            if process.poll() is None:
                process.kill()
                process.wait()
            process.stdout.close()
            process.stderr.close()

    def test_invalid_or_oversized_request_never_launches_backend(self):
        marker = self.directory / "started"
        self.fake(f"open({str(marker)!r}, 'w').close()")
        for raw in [b"not json", b"{}", b"x" * 1_048_577,
                    json.dumps({**REQUEST, "messages": [{"role": "system", "text": "bad"}]}).encode()]:
            with self.subTest(size=len(raw)):
                result = self.run_adapter(raw=raw)
                self.assertNotEqual(result.returncode, 0)
                self.assertFalse(marker.exists())
                self.assertEqual(result.stdout, b"")

    def test_missing_cli_is_recoverable(self):
        result = self.run_adapter()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn(b"executable", result.stderr)
        self.assertEqual(result.stdout, b"")

    def repository_request(self):
        repository = self.directory / "repository"
        repository.mkdir()
        def git(*arguments):
            return subprocess.check_output(["/usr/bin/git", *arguments], cwd=repository,
                env={"PATH": "/usr/bin:/bin", "HOME": str(self.directory),
                     "GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": "/dev/null"}).decode().strip()
        git("init", "-q")
        git("config", "user.name", "Fixture")
        git("config", "user.email", "fixture@example.invalid")
        (repository / "surrounding.txt").write_text("surrounding repository context")
        git("add", ".")
        git("commit", "-qm", "base")
        base = git("rev-parse", "HEAD")
        paths = ["file-%02d.txt" % i for i in range(18)]
        for path in paths:
            (repository / path).write_text("complete file text " * 2000)
        git("add", ".")
        git("commit", "-qm", "head")
        head = git("rev-parse", "HEAD")
        leased = self.directory / "leased worktree"
        git("worktree", "add", "--detach", str(leased), head)
        repository = leased
        context = self.directory / "context"
        context.mkdir(mode=0o700)
        files = []
        for index, path in enumerate(paths):
            patch = context / ("patch-%d.diff" % index)
            patch.write_text("untruncated patch " * 2000)
            patch.chmod(0o600)
            files.append({"path": path, "status": "A", "patchFile": str(patch),
                          "isBinary": False, "isSymlink": False})
        manifest = {"version": 1, "headSHA": head, "baseSHA": base, "mergeBaseSHA": base,
                    "worktreePath": str(repository), "files": files}
        (context / "manifest.json").write_text(json.dumps(manifest))
        (context / "discussion.json").write_text(json.dumps({"discussion": "all published and local draft context"}))
        for path in context.iterdir():
            path.chmod(0o600)
        request = {**REQUEST, "task": "worktree_review", "headSHA": head,
                   "repository": {key: manifest[key] for key in ("worktreePath", "headSHA", "baseSHA", "mergeBaseSHA")}}
        request["repository"].update(contextDirectory=str(context), manifestPath=str(context / "manifest.json"))
        return request, paths

    def worktree_review(self, request, provider="codex", extra=()):
        return self.run_adapter(provider, raw=json.dumps(request).encode(), extra=extra)

    def test_worktree_review_reads_complete_repository_and_context_with_restricted_native_schema(self):
        request, paths = self.repository_request()
        observed = self.directory / "observed.json"
        self.fake("import json,os,sys\nfrom pathlib import Path\n"
                  "request=json.loads(sys.stdin.read().split('\\nREQUEST_JSON:\\n')[1])\n"
                  "repository=request['repository']\n"
                  "manifest=json.loads(Path(repository['manifestPath']).read_text())\n"
                  "assert Path('surrounding.txt').read_text()=='surrounding repository context'\n"
                  "assert all(len(Path(item['path']).read_bytes())>24000 and len(Path(item['patchFile']).read_bytes())>24000 for item in manifest['files'])\n"
                  "assert 'all published' in (Path(repository['contextDirectory'])/'discussion.json').read_text()\n"
                  "schema=json.loads(Path(sys.argv[sys.argv.index('--output-schema')+1]).read_text()) if '--output-schema' in sys.argv else json.loads(sys.argv[sys.argv.index('--json-schema')+1])\n"
                  "Path(" + repr(str(observed)) + ").write_text(json.dumps({'argv':sys.argv[1:],'cwd':os.getcwd(),'schema':schema}))\n"
                  "payload={'answer':'Repository inspected','citations':[],'findings':[], 'coverage':{'reviewedPaths':[item['path'] for item in manifest['files']], 'unreviewed':[], 'testsRun':[], 'limitations':[]}}\n"
                  "emit_answer(json.dumps({'type':'result','is_error':False,'structured_output':payload} if '--json-schema' in sys.argv else payload))")
        for provider in ("codex", "claude"):
            result = self.worktree_review(request, provider)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(json.loads(result.stdout)["coverage"]["reviewedPaths"], paths)
            actual = json.loads(observed.read_text())
            self.assertEqual(Path(actual["cwd"]).resolve(), Path(request["repository"]["worktreePath"]).resolve())
            argv = actual["argv"]
            if provider == "codex":
                self.assertIn('web_search="disabled"', argv)
                self.assertIn("coverage", actual["schema"]["required"])
                self.assertIn("--output-schema", argv)
            else:
                self.assertIn("--restricted", argv)
                self.assertEqual(argv[argv.index("--tools")+1], "Read,Grep,Glob")
                self.assertEqual(argv[argv.index("--add-dir")+1], request["repository"]["contextDirectory"])
                schema = json.loads(argv[argv.index("--json-schema")+1])
                self.assertIn("coverage", schema["required"])

    def test_worktree_coverage_requires_valid_complete_accounting_and_no_test_execution(self):
        request, paths = self.repository_request()
        valid = {"reviewedPaths": paths[:1], "unreviewed": [], "testsRun": [], "limitations": []}
        bad = [None, {**valid, "reviewedPaths": ["unknown"]}, {**valid, "reviewedPaths": paths[:1]*2},
               {**valid, "unreviewed": [{"path": paths[0], "reason": "skip"}]},
               {**valid, "testsRun": ["pytest"]}, {**valid, "limitations": ["x"*16385]}]
        for coverage in [valid, *bad]:
            payload = {"answer": "Inspected", "citations": [], "findings": []}
            if coverage is not None:
                payload["coverage"] = coverage
            self.fake("emit_answer(" + repr(json.dumps(payload)) + ")")
            result = self.worktree_review(request)
            self.assertEqual(result.returncode == 0, coverage == valid, result.stderr)
            if coverage == valid:
                self.assertEqual([item["path"] for item in json.loads(result.stdout)["coverage"]["unreviewed"]], paths[1:])
            else:
                self.assertEqual(result.stdout, b"")
                self.assertIn(b"invalidReviewResponse", result.stderr)

    def test_worktree_invalid_identity_and_escaping_manifest_never_launch_provider(self):
        request, paths = self.repository_request()
        marker = self.directory / "started"
        self.fake("open(" + repr(str(marker)) + ",'w').close()")
        manifest_path = Path(request["repository"]["manifestPath"])
        original = json.loads(manifest_path.read_text())
        for mutate in [lambda value: value.update(headSHA="a"*40),
                       lambda value: value["files"][0].update(patchFile=str(self.directory / "outside")),
                       lambda value: value["files"][0].update(path="../outside"),
                       lambda value: value.update(mergeBaseSHA="a"*40),
                       lambda value: value["files"].pop(),
                       lambda value: value["files"][0].update(status="D")]:
            value = json.loads(json.dumps(original))
            mutate(value)
            manifest_path.write_text(json.dumps(value))
            result = self.worktree_review(request)
            self.assertNotEqual(result.returncode, 0)
            self.assertFalse(marker.exists())
            self.assertIn(b"invalidRepositoryContext", result.stderr)
        manifest_path.write_text(json.dumps(original))
        request["repository"]["headSHA"] = "a"*40
        request["headSHA"] = "a"*40
        result = self.worktree_review(request)
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(marker.exists())

    def test_worktree_empty_pinned_diff_requires_explicit_empty_coverage(self):
        request, paths = self.repository_request()
        request["repository"]["baseSHA"] = request["headSHA"]
        request["repository"]["mergeBaseSHA"] = request["headSHA"]
        manifest_path = Path(request["repository"]["manifestPath"])
        manifest = json.loads(manifest_path.read_text())
        manifest.update(baseSHA=request["headSHA"], mergeBaseSHA=request["headSHA"], files=[])
        manifest_path.write_text(json.dumps(manifest))
        payload = {"answer": "No changed files", "citations": [], "findings": [], "coverage": {"reviewedPaths": [], "unreviewed": [], "testsRun": [], "limitations": []}}
        self.fake("emit_answer(" + repr(json.dumps(payload)) + ")")
        result = self.worktree_review(request)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(result.stdout)["coverage"]["reviewedPaths"], [])

    def test_worktree_context_requires_private_regular_files_and_cancellation_stops_provider(self):
        request, paths = self.repository_request()
        context = Path(request["repository"]["contextDirectory"])
        marker = self.directory / "started"
        self.fake("open(" + repr(str(marker)) + ",'w').close()")
        discussion = context / "discussion.json"
        original = discussion.read_bytes()
        discussion.chmod(0o644)
        result = self.worktree_review(request)
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(marker.exists())
        discussion.unlink()
        outside = self.directory / "outside.json"
        outside.write_bytes(original)
        outside.chmod(0o600)
        discussion.symlink_to(outside)
        result = self.worktree_review(request)
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(marker.exists())
        discussion.unlink()
        discussion.symlink_to(discussion.name)
        result = self.worktree_review(request)
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(marker.exists())
        self.assertIn(b"invalidRepositoryContext", result.stderr)
        self.assertNotIn(b"Traceback", result.stderr)
        discussion.unlink()
        discussion.write_bytes(original)
        discussion.chmod(0o600)
        self.fake("import os,signal,time\nsignal.signal(signal.SIGTERM,signal.SIG_IGN)\nopen(" + repr(str(marker)) + ",'w').write(str(os.getpid()))\ntime.sleep(30)")
        process = subprocess.Popen(self.command(), stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                   stderr=subprocess.PIPE, cwd=self.directory, env=self.environment)
        try:
            process.stdin.write(json.dumps(request).encode())
            process.stdin.close()
            for _ in range(200):
                if marker.exists():
                    break
                time.sleep(0.01)
            self.assertTrue(marker.exists())
            pid = int(marker.read_text())
            process.terminate()
            process.wait(timeout=3)
            self.assertIn(b"cancelled", process.stderr.read())
            self.assert_gone(pid)
        finally:
            if process.poll() is None:
                process.kill()
                process.wait()
            process.stdout.close()
            process.stderr.close()

    def test_worktree_review_ignores_replacement_refs_and_grafts_for_pinned_objects(self):
        request, paths = self.repository_request()
        worktree = request["repository"]["worktreePath"]
        git_environment = {"PATH": "/usr/bin:/bin", "HOME": str(self.directory),
                           "GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": "/dev/null"}
        def git(*arguments):
            return subprocess.check_output(["/usr/bin/git", *arguments], cwd=worktree,
                                           env=git_environment).decode().strip()
        self.fake("import os,json\n"
                  "assert os.environ.get('GIT_NO_REPLACE_OBJECTS')=='1'\n"
                  "assert os.environ.get('GIT_GRAFT_FILE')=='/dev/null'\n"
                  "emit_answer(" + repr(json.dumps({"answer": "Pinned objects inspected", "citations": [], "findings": [],
                       "coverage": {"reviewedPaths": paths, "unreviewed": [], "testsRun": [], "limitations": []}})) + ")")
        git("replace", request["headSHA"], request["repository"]["baseSHA"])
        replaced = self.worktree_review(request)
        self.assertEqual(replaced.returncode, 0, replaced.stderr)
        self.assertEqual(json.loads(replaced.stdout)["coverage"]["reviewedPaths"], paths)
        git("replace", "-d", request["headSHA"])
        graft_file = Path(git("rev-parse", "--path-format=absolute", "--git-path", "info/grafts"))
        graft_file.parent.mkdir(parents=True, exist_ok=True)
        graft_file.write_text(request["headSHA"] + "\n")
        grafted = self.worktree_review(request)
        self.assertEqual(grafted.returncode, 0, grafted.stderr)
        self.assertEqual(json.loads(grafted.stdout)["coverage"]["reviewedPaths"], paths)
        # Neither validation nor the fake read-only provider changes this Git metadata.
        self.assertEqual(graft_file.read_text(), request["headSHA"] + "\n")

    def test_worktree_timeout_accepts_extended_deadline_but_legacy_stays_bounded(self):
        request, paths = self.repository_request()
        payload = {"answer": "Inspected", "citations": [], "findings": [],
                   "coverage": {"reviewedPaths": paths, "unreviewed": [], "testsRun": [], "limitations": []}}
        self.fake("emit_answer(" + repr(json.dumps(payload)) + ")")
        self.assertEqual(self.worktree_review(request, extra=("--timeout", "600")).returncode, 0)
        self.assertNotEqual(self.run_adapter(extra=("--timeout", "600")).returncode, 0)
        self.assertNotEqual(self.worktree_review(request, extra=("--timeout", "601")).returncode, 0)

    def assert_gone(self, pid):
        try:
            os.kill(pid, 0)
        except ProcessLookupError:
            return
        os.kill(pid, signal.SIGKILL)
        self.fail("Backend process survived adapter shutdown")


if __name__ == "__main__":
    unittest.main()
