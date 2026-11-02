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

    def assert_gone(self, pid):
        try:
            os.kill(pid, 0)
        except ProcessLookupError:
            return
        os.kill(pid, signal.SIGKILL)
        self.fail("Backend process survived adapter shutdown")


if __name__ == "__main__":
    unittest.main()
