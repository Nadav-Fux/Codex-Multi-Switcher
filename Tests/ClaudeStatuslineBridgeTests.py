#!/usr/bin/env python3
"""Isolated tests for ClaudeStatuslineBridge; never reads real Claude settings."""

import json
import os
import pathlib
import shlex
import subprocess
import sys
import tempfile
import time
import unittest


REPO = pathlib.Path(__file__).resolve().parents[1]
BRIDGE = REPO / "Scripts" / "ClaudeStatuslineBridge.py"
SNAPSHOT = "codex-multi-switcher-usage.json"
PROFILE = "test-profile"


class ClaudeStatuslineBridgeTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="claude-bridge-test-")
        self.config_dir = pathlib.Path(self.temp.name) / "profile-config"
        self.config_dir.mkdir(mode=0o700)

    def tearDown(self):
        self.temp.cleanup()

    def run_bridge(self, payload, *extra, profile=PROFILE, check=True):
        return subprocess.run(
            [sys.executable, str(BRIDGE), "--profile-id", profile, "--config-dir", str(self.config_dir), *extra],
            input=payload,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=check,
            timeout=5,
        )

    @property
    def snapshot_path(self):
        return self.config_dir / SNAPSHOT

    def read_snapshot(self):
        return json.loads(self.snapshot_path.read_text(encoding="utf-8"))

    def test_passes_exact_stdin_and_stdout_through_previous_command(self):
        payload = b'{ "cwd":"/private/project", "transcript_path":"/private/transcript", "x":1 }\n'
        result = self.run_bridge(payload, "--previous-command", "cat")
        self.assertEqual(result.stdout, payload)
        self.assertFalse(self.snapshot_path.exists())

    def test_extracts_allowlisted_usage_and_hashes_session_without_storing_private_fields(self):
        payload = json.dumps({
            "session_id": "secret-session-id",
            "cwd": "/private/project",
            "transcript_path": "/private/transcript.jsonl",
            "rate_limits": {
                "five_hour": {"used_percentage": 12.5, "resets_at": 1790985600},
                "seven_day": {"used_percentage": 30, "resets_at": 1791417600},
                "spend_limit": {"used_percentage": 77},
            },
        }).encode()
        result = self.run_bridge(payload, "--account-fingerprint", "a" * 64)
        self.assertEqual(result.stdout, b"5h 12.5% | 7d 30%")
        snapshot = self.read_snapshot()
        self.assertEqual(snapshot["schemaVersion"], 1)
        self.assertEqual(snapshot["profileID"], PROFILE)
        self.assertEqual(snapshot["configDirectory"], str(self.config_dir.resolve()))
        self.assertEqual(snapshot["authIdentityDigest"], "a" * 64)
        self.assertEqual(snapshot["fiveHour"]["usedPercent"], 12.5)
        self.assertEqual(snapshot["sevenDay"]["usedPercent"], 30.0)
        self.assertRegex(snapshot["fiveHour"]["resetAt"], r"^20\d\d-\d\d-\d\dT.*Z$")
        self.assertNotIn("secret-session-id", self.snapshot_path.read_text())
        self.assertNotIn("transcript_path", snapshot)
        self.assertNotIn("cwd", snapshot)
        self.assertNotIn("spend_limit", snapshot)
        self.assertEqual(os.stat(self.snapshot_path).st_mode & 0o777, 0o600)

    def test_missing_or_null_rate_limits_does_not_replace_recent_valid_snapshot(self):
        self.run_bridge(json.dumps({"rate_limits": {"five_hour": {"used_percentage": 40}}}).encode())
        original = self.snapshot_path.read_bytes()
        for payload in (b'{"session_id":"s"}', b'{"rate_limits":null}', b'{"rate_limits":{}}', b"not-json"):
            self.run_bridge(payload)
            self.assertEqual(self.snapshot_path.read_bytes(), original)

    def test_partial_update_drops_historical_missing_window_and_bad_percent(self):
        self.run_bridge(json.dumps({"rate_limits": {
            "five_hour": {"used_percentage": 9}, "seven_day": {"used_percentage": 25},
        }}).encode())
        self.run_bridge(json.dumps({"rate_limits": {
            "five_hour": {"used_percentage": 110}, "seven_day": {"used_percentage": 31},
        }}).encode())
        snapshot = self.read_snapshot()
        self.assertNotIn("fiveHour", snapshot)
        self.assertEqual(snapshot["sevenDay"]["usedPercent"], 31.0)

    def test_native_statusline_shows_current_values_and_unavailable_windows(self):
        payload = json.dumps({"rate_limits": {
            "five_hour": {"used_percentage": 12.5},
        }}).encode()
        result = self.run_bridge(payload)
        self.assertEqual(result.stdout, b"5h 12.5% | 7d unavailable")
        empty = self.run_bridge(b'{"session_id":"x"}')
        self.assertEqual(empty.stdout, b"5h unavailable | 7d unavailable")

    def test_snapshot_lock_error_does_not_suppress_previous_command_output(self):
        (self.config_dir / ".codex-multi-switcher-usage.lock").mkdir()
        payload = b'{"rate_limits":{"five_hour":{"used_percentage":12}}}\n'
        result = self.run_bridge(payload, "--previous-command", "cat")
        self.assertEqual(result.stdout, payload)

    def test_rejects_path_like_profile_and_unexpected_output_path(self):
        invalid = self.run_bridge(b"{}", profile="../escape", check=False)
        self.assertEqual(invalid.returncode, 2)
        invalid_output = self.run_bridge(b"{}", "--output", str(self.config_dir / "elsewhere.json"), check=False)
        self.assertEqual(invalid_output.returncode, 2)
        self.assertFalse(self.snapshot_path.exists())

    def test_oversized_input_is_rejected_without_persistence_or_command_capture(self):
        payload = b"x" * (1024 * 1024 + 1)
        result = self.run_bridge(payload, "--previous-command", "cat")
        self.assertEqual(result.stdout, b"")
        self.assertFalse(self.snapshot_path.exists())

    def test_previous_command_output_is_bounded(self):
        command = "python3 -c 'import sys; sys.stdout.write(\"x\" * 1000000)'"
        result = self.run_bridge(b"{}", "--previous-command", command)
        self.assertEqual(len(result.stdout), 64 * 1024)

    def test_extended_timeout_preserves_slow_previous_command_output(self):
        command = "sleep 2.2; printf 'slow legacy statusline\\n'"
        result = self.run_bridge(b"{}", "--previous-command", command, "--previous-timeout", "3")
        self.assertEqual(result.stdout, b"slow legacy statusline\n")

    def test_previous_timeout_rejects_invalid_or_unbounded_values(self):
        for value in ("0.05", "15.1", "nan", "inf", "not-a-number"):
            with self.subTest(value=value):
                result = self.run_bridge(b"{}", "--previous-timeout", value, check=False)
                self.assertEqual(result.returncode, 2)
        self.assertFalse(self.snapshot_path.exists())

    def test_cancelling_wrapper_kills_previous_command_process_group(self):
        pid_path = self.config_dir / "previous-child.pid"
        helper = self.config_dir / "slow-previous.py"
        helper.write_text("import pathlib,subprocess,sys,time\n"
                          "child=subprocess.Popen(['sleep','30'])\n"
                          "pathlib.Path(sys.argv[1]).write_text(str(child.pid))\n"
                          "time.sleep(30)\n", encoding="utf-8")
        command = " ".join(shlex.quote(value) for value in (sys.executable, str(helper), str(pid_path)))
        process = subprocess.Popen(
            [sys.executable, str(BRIDGE), "--profile-id", PROFILE, "--config-dir", str(self.config_dir),
             "--previous-command", command, "--previous-timeout", "10"],
            stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
        )
        child_pid = None
        try:
            process.stdin.write(b'{"rate_limits":{"five_hour":{"used_percentage":12}}}')
            process.stdin.close()
            deadline = time.monotonic() + 3
            while not pid_path.exists() and time.monotonic() < deadline:
                time.sleep(0.01)
            self.assertTrue(pid_path.exists(), "previous-command helper did not start")
            child_pid = int(pid_path.read_text())
            self.assertTrue(self.snapshot_path.exists(), "usage should persist before slow previous statusline")
            process.terminate()
            exit_code = process.wait(timeout=2)
            self.assertEqual(exit_code, 143, process.stderr.read().decode("utf-8", errors="replace"))
            deadline = time.monotonic() + 1
            while True:
                state = subprocess.run(["ps", "-o", "stat=", "-p", str(child_pid)], capture_output=True, text=True).stdout.strip()
                if not state or state.startswith("Z") or time.monotonic() >= deadline:
                    break
                time.sleep(0.01)
            self.assertTrue(not state or state.startswith("Z"), "previous-command child survived wrapper cancellation: " + state)
        finally:
            if process.poll() is None:
                process.kill()
                process.wait(timeout=2)
            process.stdout.close()
            process.stderr.close()
            if child_pid is not None:
                try:
                    os.kill(child_pid, 9)
                except ProcessLookupError:
                    pass

    def test_timeout_kills_previous_command_process_group(self):
        command = "python3 -c 'import subprocess,time; p=subprocess.Popen([\"sleep\",\"30\"]); print(p.pid,flush=True); time.sleep(30)'"
        start = time.monotonic()
        result = self.run_bridge(b"{}", "--previous-command", command)
        self.assertLess(time.monotonic() - start, 4)
        child_pid = int(result.stdout.decode().strip())
        state = subprocess.run(["ps", "-o", "stat=", "-p", str(child_pid)], capture_output=True, text=True).stdout.strip()
        self.assertTrue(not state or state.startswith("Z"), "previous-command child survived timeout: " + state)

    def test_timeout_bounds_exited_parent_with_descendant_holding_stdout(self):
        command = "python3 -c 'import subprocess; p=subprocess.Popen([\"sleep\",\"30\"]); print(p.pid,flush=True)'"
        start = time.monotonic()
        result = self.run_bridge(b"{}", "--previous-command", command)
        self.assertLess(time.monotonic() - start, 4)
        child_pid = int(result.stdout.decode().strip())
        state = subprocess.run(["ps", "-o", "stat=", "-p", str(child_pid)], capture_output=True, text=True).stdout.strip()
        self.assertTrue(not state or state.startswith("Z"), "stdout-holding child survived timeout: " + state)

    def test_concurrent_updates_merge_without_corrupting_json(self):
        payloads = [
            json.dumps({"rate_limits": {"five_hour": {"used_percentage": 18}}}).encode(),
            json.dumps({"rate_limits": {"seven_day": {"used_percentage": 67}}}).encode(),
        ]
        commands = [
            subprocess.Popen(
                [sys.executable, str(BRIDGE), "--profile-id", PROFILE, "--config-dir", str(self.config_dir)],
                stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
            )
            for _ in payloads
        ]
        for process, payload in zip(commands, payloads):
            process.stdin.write(payload)
            process.stdin.close()
        for process in commands:
            self.assertEqual(process.wait(timeout=5), 0, process.stderr.read())
            process.stdout.close()
            process.stderr.close()
        snapshot = self.read_snapshot()
        self.assertTrue(
            (snapshot.get("fiveHour", {}).get("usedPercent") == 18.0 and "sevenDay" not in snapshot)
            or (snapshot.get("sevenDay", {}).get("usedPercent") == 67.0 and "fiveHour" not in snapshot)
        )
        self.assertEqual(os.stat(self.snapshot_path).st_mode & 0o777, 0o600)


if __name__ == "__main__":
    unittest.main()
