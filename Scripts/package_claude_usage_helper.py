#!/usr/bin/env python3
"""Keep the exact authorized helper executable when its implementation is unchanged."""

import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile


IDENTIFIER = "com.codexmultiswitcher.claude-usage-helper"
BINARY = "claude-usage-helper"
MANIFEST = "claude-usage-helper.json"
SCHEMA = 1


def sha256(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def command_output(*arguments):
    return subprocess.check_output(arguments, stderr=subprocess.STDOUT).decode().strip()


def fingerprint(root, build_arguments):
    sdk = os.environ.get("CODEX_PROFILE_SDK") or command_output("xcrun", "--show-sdk-path")
    inputs = {
        "schemaVersion": SCHEMA,
        "identifier": IDENTIFIER,
        "compiler": command_output("swift", "--version"),
        "sdk": str(Path(sdk).resolve()),
        "sdkSettings": sha256(Path(sdk) / "SDKSettings.json"),
        "developerDirectory": os.environ.get("DEVELOPER_DIR", ""),
        "buildArguments": build_arguments,
        "files": {},
    }
    files = list((root / "Sources/CodexProfileCore").rglob("*.swift"))
    files += list((root / "Sources/ClaudeUsageHelper").rglob("*.swift"))
    files += [root / "Package.swift", Path(__file__).resolve()]
    for path in sorted(files):
        inputs["files"][str(path.relative_to(root))] = sha256(path)
    return hashlib.sha256(json.dumps(inputs, sort_keys=True).encode()).hexdigest()


def valid(directory, source_fingerprint, manifest=None):
    binary = directory / BINARY
    manifest = manifest or directory / MANIFEST
    try:
        if binary.is_symlink() or manifest.is_symlink() or not binary.is_file() or not manifest.is_file():
            return False
        metadata = json.loads(manifest.read_text())
        if (metadata.get("schemaVersion") != SCHEMA
                or metadata.get("sourceFingerprint") != source_fingerprint
                or metadata.get("sha256") != sha256(binary)):
            return False
        subprocess.run(["codesign", "--verify", "--strict", str(binary)],
                       check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        details = command_output("codesign", "-d", "--verbose=4", str(binary))
        return f"Identifier={IDENTIFIER}" in details.splitlines()
    except (OSError, ValueError, subprocess.SubprocessError):
        return False


def copy_pair(source, destination, manifest=None):
    destination.mkdir(parents=True, exist_ok=True)
    for name in (BINARY, MANIFEST):
        shutil.copyfile(manifest if name == MANIFEST and manifest is not None else source / name, destination / name)
    (destination / BINARY).chmod(0o700)
    (destination / MANIFEST).chmod(0o600)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, required=True)
    parser.add_argument("--built-binary", type=Path, required=True)
    parser.add_argument("--destination", type=Path, required=True)
    parser.add_argument("--reuse-bundle", type=Path)
    parser.add_argument("--build-argument", action="append", default=[])
    args = parser.parse_args()
    root = args.root.resolve()
    source_fingerprint = fingerprint(root, args.build_argument)
    cache_root = root / ".build/claude-usage-helper-cache"
    cache_root.mkdir(parents=True, exist_ok=True, mode=0o700)
    cache_root.chmod(0o700)
    cache = cache_root / source_fingerprint
    if cache.exists() and not valid(cache, source_fingerprint):
        # A mismatch is never accepted as a reusable authorization identity.
        print("Claude usage helper cache mismatch; rebuilding the helper identity.")
        if cache.is_symlink() or not cache.is_dir():
            cache.unlink()
        else:
            shutil.rmtree(cache)
    if not valid(cache, source_fingerprint):
        installed = args.reuse_bundle / "Contents/Helpers" if args.reuse_bundle else None
        installed_manifest = args.reuse_bundle / "Contents/Resources" / MANIFEST if args.reuse_bundle else None
        with tempfile.TemporaryDirectory(prefix=".helper-", dir=cache_root) as temporary:
            staging = Path(temporary)
            if installed is not None and valid(installed, source_fingerprint, installed_manifest):
                copy_pair(installed, staging, installed_manifest)
                print("Reusing the matching installed Claude usage helper identity.")
            else:
                binary = staging / BINARY
                shutil.copyfile(args.built_binary, binary)
                binary.chmod(0o700)
                subprocess.run(["codesign", "--force", "--sign", "-", "--identifier", IDENTIFIER,
                                str(binary)], check=True)
                metadata = {"schemaVersion": SCHEMA, "sourceFingerprint": source_fingerprint,
                            "sha256": sha256(binary)}
                (staging / MANIFEST).write_text(json.dumps(metadata, sort_keys=True) + "\n")
                (staging / MANIFEST).chmod(0o600)
                if not valid(staging, source_fingerprint):
                    raise RuntimeError("New Claude usage helper failed signature or manifest verification")
            # Preserve the original signed bytes. Never re-sign a cached helper.
            cache.mkdir(mode=0o700)
            copy_pair(staging, cache)
    copy_pair(cache, args.destination)
    if not valid(args.destination, source_fingerprint):
        raise RuntimeError("Packaged Claude usage helper differs from its verified cache")
    print(f"Claude usage helper source identity: {source_fingerprint}")


if __name__ == "__main__":
    main()
