#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/claude-integration-tests.XXXXXX")"
trap 'rm -rf "$WORK_DIR"' EXIT
SDK_PATH="${CODEX_PROFILE_SDK:-/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk}"
if [[ ! -d "$SDK_PATH" ]]; then SDK_PATH="$(xcrun --show-sdk-path)"; fi
BUILD_DIR="${CODEX_CLAUDE_TEST_BUILD:-$WORK_DIR/build}"
swift build --package-path "$ROOT_DIR" --target CodexProfileCore \
    --sdk "$SDK_PATH" --scratch-path "$BUILD_DIR" >/dev/null
BIN_DIR="$(swift build --package-path "$ROOT_DIR" --sdk "$SDK_PATH" \
    --scratch-path "$BUILD_DIR" --show-bin-path)"
if [[ -f "$BIN_DIR/CodexProfileCore.o" ]]; then
    swiftc -parse-as-library -sdk "$SDK_PATH" -I "$BIN_DIR" \
        "$ROOT_DIR/Sources/CodexMultiSwitcherApp/ClaudeProfileStore.swift" \
        "$ROOT_DIR/Tests/ClaudeIntegrationSmoke.swift" "$BIN_DIR/CodexProfileCore.o" \
        "$ROOT_DIR/Tests/ClaudeCurrentUsageChecks.swift" \
        -o "$WORK_DIR/claude-integration-smoke"
else
    swiftc -parse-as-library -sdk "$SDK_PATH" -I "$BIN_DIR/Modules" \
        "$ROOT_DIR/Sources/CodexMultiSwitcherApp/ClaudeProfileStore.swift" \
        "$ROOT_DIR/Tests/ClaudeIntegrationSmoke.swift" "$BIN_DIR/CodexProfileCore.build/"*.o \
        "$ROOT_DIR/Tests/ClaudeCurrentUsageChecks.swift" \
        -o "$WORK_DIR/claude-integration-smoke"
fi
"$WORK_DIR/claude-integration-smoke"
