#!/usr/bin/env python3
"""Token-free Claude Code statusline bridge for Codex Multi-Switcher.

Claude Code sends one JSON object on stdin. The bridge stores only the two
rate-limit windows and a one-way session identifier hash; it never reads
transcripts, credentials, or the environment for authentication material.
"""

import argparse
import datetime as _datetime
import fcntl
import hashlib
import json
import math
import os
import re
import selectors
import signal
import subprocess
import sys
import tempfile
import threading
import time


MAX_INPUT_BYTES = 1024 * 1024
MAX_CAPTURE_BYTES = 64 * 1024
COMMAND_TIMEOUT_SECONDS = 2.0
SNAPSHOT_NAME = "codex-multi-switcher-usage.json"
PROFILE_ID_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$")
SHA256_RE = re.compile(r"^[a-fA-F0-9]{64}$")


def _utc_now():
    return _datetime.datetime.now(_datetime.timezone.utc).isoformat(timespec="seconds").replace("+00:00", "Z")


def _iso_reset(value):
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        return None
    if not math.isfinite(value) or value < 0:
        return None
    try:
        return _datetime.datetime.fromtimestamp(value, _datetime.timezone.utc).isoformat(timespec="seconds").replace("+00:00", "Z")
    except (OverflowError, OSError, ValueError):
        return None


def _window(rate_limits, key):
    raw = rate_limits.get(key) if isinstance(rate_limits, dict) else None
    if not isinstance(raw, dict):
        return None
    used = raw.get("used_percentage")
    if isinstance(used, bool) or not isinstance(used, (int, float)) or not math.isfinite(used) or not 0 <= used <= 100:
        return None
    result = {"usedPercent": float(used)}
    reset_at = _iso_reset(raw.get("resets_at"))
    if reset_at is not None:
        result["resetAt"] = reset_at
    return result


def _write_snapshot(snapshot_path, config_dir, profile_id, config_directory, auth_digest, session_hash, rate_limits):
    lock_path = os.path.join(config_dir, ".codex-multi-switcher-usage.lock")
    # flock is advisory and process-scoped; holding the stable lock across the
    # read/merge/rename prevents parallel Claude sessions from losing updates.
    lock_fd = os.open(lock_path, os.O_CREAT | os.O_RDWR, 0o600)
    try:
        os.fchmod(lock_fd, 0o600)
        fcntl.flock(lock_fd, fcntl.LOCK_EX)
        updates = {}
        for source_key, output_key in (("five_hour", "fiveHour"), ("seven_day", "sevenDay")):
            candidate = _window(rate_limits, source_key)
            if candidate is not None:
                updates[output_key] = candidate
        # An absent/null/invalid rate_limits object is not a zero-usage sample.
        # Do not refresh metadata or replace a recent good snapshot in that case.
        if not updates:
            return False
        merged = {
            "schemaVersion": 1,
            "profileID": profile_id,
            "configDirectory": config_directory,
            "fetchedAt": _utc_now(),
        }
        if auth_digest is not None:
            merged["authIdentityDigest"] = auth_digest.lower()
        if session_hash is not None:
            merged["sessionIDHash"] = session_hash
        # Keep only windows present and valid in this input. Carrying a missing
        # historical window forward would make fetchedAt falsely refresh it.
        for key, value in updates.items():
            merged[key] = value
        encoded = (json.dumps(merged, separators=(",", ":"), sort_keys=True, allow_nan=False) + "\n").encode("utf-8")
        fd, temp_path = tempfile.mkstemp(prefix=".codex-multi-switcher-usage.", suffix=".tmp", dir=config_dir)
        try:
            os.fchmod(fd, 0o600)
            with os.fdopen(fd, "wb") as stream:
                stream.write(encoded)
                stream.flush()
                os.fsync(stream.fileno())
            os.replace(temp_path, snapshot_path)
            dir_fd = os.open(config_dir, os.O_RDONLY)
            try:
                os.fsync(dir_fd)
            finally:
                os.close(dir_fd)
        finally:
            try:
                os.unlink(temp_path)
            except FileNotFoundError:
                pass
        return True
    finally:
        try:
            fcntl.flock(lock_fd, fcntl.LOCK_UN)
        finally:
            os.close(lock_fd)


def _run_previous(command, payload, timeout_seconds=COMMAND_TIMEOUT_SECONDS):
    if not command:
        return b""
    try:
        process = subprocess.Popen(
            command,
            shell=True,
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            close_fds=True,
            start_new_session=True,
        )
    except OSError:
        return b""

    def write_stdin():
        try:
            process.stdin.write(payload)
            process.stdin.close()
        except (BrokenPipeError, OSError):
            pass

    group_killed = False

    def kill_group():
        nonlocal group_killed
        if group_killed:
            return
        try:
            os.killpg(process.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        group_killed = True

    def cancelled(signum, _frame):
        # Claude cancels a superseded statusline invocation with SIGTERM. The
        # chained command has its own session, so it must be cancelled explicitly.
        kill_group()
        raise SystemExit(128 + signum)

    previous_handlers = {signum: signal.getsignal(signum) for signum in (signal.SIGTERM, signal.SIGINT)}
    for signum in previous_handlers:
        signal.signal(signum, cancelled)
    writer = threading.Thread(target=write_stdin, daemon=True)
    selector = selectors.DefaultSelector()
    output = bytearray()
    try:
        writer.start()
        selector.register(process.stdout, selectors.EVENT_READ)
        deadline = time.monotonic() + timeout_seconds
        while True:
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                kill_group()
                break
            events = selector.select(min(remaining, 0.1))
            if not events:
                # A finished shell can leave a descendant holding stdout open.
                # Wait for selector readiness/EOF within the deadline; a blocking
                # read here would bypass the timeout until that descendant exits.
                continue
            chunk = os.read(process.stdout.fileno(), min(8192, MAX_CAPTURE_BYTES + 1 - len(output)))
            if not chunk:
                break
            room = MAX_CAPTURE_BYTES - len(output)
            output.extend(chunk[:room])
            if len(chunk) > room:
                kill_group()
                break
        try:
            process.wait(timeout=0.25)
        except subprocess.TimeoutExpired:
            kill_group()
            process.wait()
    finally:
        selector.close()
        try:
            process.stdout.close()
        except OSError:
            pass
        if writer.ident is not None:
            writer.join(timeout=0.1)
        if process.poll() is None:
            kill_group()
            try:
                process.wait(timeout=0.25)
            except subprocess.TimeoutExpired:
                pass
        for signum, previous in previous_handlers.items():
            signal.signal(signum, previous)
    # If output exceeded the capture cap or timed out, only the bounded captured
    # prefix is emitted. Otherwise stdout bytes (including whitespace/newlines)
    # are forwarded verbatim.
    return bytes(output)


def _native_status_line(rate_limits):
    parts = []
    for key, label in (("five_hour", "5h"), ("seven_day", "7d")):
        window = _window(rate_limits, key)
        value = "unavailable" if window is None else "{}%".format(_format_percent(window["usedPercent"]))
        parts.append("{} {}".format(label, value))
    return " | ".join(parts).encode("utf-8")


def _format_percent(value):
    return str(int(value)) if value.is_integer() else "{:.1f}".format(value)


def _previous_timeout(value):
    try:
        timeout = float(value)
    except ValueError:
        raise argparse.ArgumentTypeError("previous timeout must be between 0.1 and 15 seconds")
    if not math.isfinite(timeout) or not 0.1 <= timeout <= 15:
        raise argparse.ArgumentTypeError("previous timeout must be between 0.1 and 15 seconds")
    return timeout


def _arguments(argv):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--profile-id", required=True)
    parser.add_argument("--config-dir", required=True)
    parser.add_argument("--output")
    parser.add_argument("--auth-identity-digest", "--account-fingerprint", dest="auth_identity_digest")
    parser.add_argument("--previous-command", default="")
    parser.add_argument("--previous-timeout", type=_previous_timeout, default=COMMAND_TIMEOUT_SECONDS)
    return parser.parse_args(argv)


def main(argv=None):
    args = _arguments(argv)
    if not PROFILE_ID_RE.fullmatch(args.profile_id) or ".." in args.profile_id:
        return 2
    if args.auth_identity_digest and not SHA256_RE.fullmatch(args.auth_identity_digest):
        return 2
    try:
        config_dir = os.path.realpath(args.config_dir)
        if not os.path.isdir(config_dir):
            return 2
        expected_output = os.path.join(config_dir, SNAPSHOT_NAME)
        if args.output is not None and os.path.abspath(args.output) != expected_output:
            return 2
    except (OSError, TypeError):
        return 2

    payload = sys.stdin.buffer.read(MAX_INPUT_BYTES + 1)
    if len(payload) > MAX_INPUT_BYTES:
        return 0
    # Parse only from the in-memory capped payload. Never retain or inspect
    # transcript_path, cwd, prompt text, environment credentials, or tokens.
    try:
        parsed = json.loads(payload.decode("utf-8"))
    except (UnicodeError, ValueError):
        parsed = None
    if isinstance(parsed, dict):
        rate_limits = parsed.get("rate_limits")
        session_id = parsed.get("session_id")
        session_hash = None
        if isinstance(session_id, str) and session_id:
            session_hash = hashlib.sha256((args.profile_id + "\0" + session_id).encode("utf-8")).hexdigest()
        try:
            _write_snapshot(
                expected_output,
                config_dir,
                args.profile_id,
                config_dir,
                args.auth_identity_digest,
                session_hash,
                rate_limits,
            )
        except OSError:
            # Snapshot persistence is auxiliary; never suppress the user's
            # configured statusline because a lock or filesystem operation failed.
            pass
    output = _run_previous(args.previous_command, payload, args.previous_timeout) if args.previous_command else _native_status_line(parsed.get("rate_limits") if isinstance(parsed, dict) else None)
    try:
        sys.stdout.buffer.write(output)
        sys.stdout.buffer.flush()
    except BrokenPipeError:
        pass
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
