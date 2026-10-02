#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/usage-normalization-tests.XXXXXX")"
trap 'rm -rf "$WORK_DIR"' EXIT
SDK_PATH="${CODEX_PROFILE_SDK:-$(xcrun --show-sdk-path)}"
BUILD_DIR="${CODEX_USAGE_TEST_BUILD:-$WORK_DIR/build}"
swift build --package-path "$ROOT_DIR" --target CodexProfileCore --sdk "$SDK_PATH" --scratch-path "$BUILD_DIR" >/dev/null
BIN_DIR="$(swift build --package-path "$ROOT_DIR" --sdk "$SDK_PATH" --scratch-path "$BUILD_DIR" --show-bin-path)"
if [[ -f "$BIN_DIR/CodexProfileCore.o" ]]; then
    swiftc -parse-as-library -sdk "$SDK_PATH" -I "$BIN_DIR" "$ROOT_DIR/Tests/UsageNormalizationSmoke.swift" "$BIN_DIR/CodexProfileCore.o" -o "$WORK_DIR/usage-normalization-smoke"
else
    swiftc -parse-as-library -sdk "$SDK_PATH" -I "$BIN_DIR/Modules" "$ROOT_DIR/Tests/UsageNormalizationSmoke.swift" "$BIN_DIR/CodexProfileCore.build/"*.o -o "$WORK_DIR/usage-normalization-smoke"
fi
"$WORK_DIR/usage-normalization-smoke"
