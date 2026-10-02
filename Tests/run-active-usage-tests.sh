#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/active-usage-tests.XXXXXX")"
trap 'rm -rf "$WORK_DIR"' EXIT
SDK_PATH="${CODEX_PROFILE_SDK:-/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk}"
BUILD_DIR="${CODEX_ACTIVE_USAGE_TEST_BUILD:-$WORK_DIR/build}"
swift build --package-path "$ROOT_DIR" --target CodexProfileCore --sdk "$SDK_PATH" --scratch-path "$BUILD_DIR" >/dev/null
BIN_DIR="$(swift build --package-path "$ROOT_DIR" --sdk "$SDK_PATH" --scratch-path "$BUILD_DIR" --show-bin-path)"
CORE_ARGS=()
if [[ -f "$BIN_DIR/CodexProfileCore.o" ]]; then
    CORE_ARGS=(-I "$BIN_DIR" "$BIN_DIR/CodexProfileCore.o")
else
    CORE_ARGS=(-I "$BIN_DIR/Modules" "$BIN_DIR/CodexProfileCore.build/"*.o)
fi
APP_SOURCES=()
for SOURCE in "$ROOT_DIR/Sources/CodexMultiSwitcherApp/"*.swift; do
    [[ "${SOURCE##*/}" == "Main.swift" ]] || APP_SOURCES+=("$SOURCE")
done
swiftc -parse-as-library -DTESTING -DCODEX_MULTI_SWITCHER_LOCAL -sdk "$SDK_PATH" "${CORE_ARGS[@]}" \
    "${APP_SOURCES[@]}" "$ROOT_DIR/Tests/ActiveUsageSmoke.swift" -o "$WORK_DIR/active-usage-smoke"
"$WORK_DIR/active-usage-smoke"
