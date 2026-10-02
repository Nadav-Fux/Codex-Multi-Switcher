#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/switcher-feature-tests.XXXXXX")"
trap 'rm -rf "$WORK_DIR"' EXIT
SDK_PATH="${CODEX_PROFILE_SDK:-$(xcrun --show-sdk-path)}"
BUILD_DIR="${CODEX_FEATURE_TEST_BUILD:-$ROOT_DIR/.build/reset-investigation}"
swift build --package-path "$ROOT_DIR" --target CodexProfileCore --sdk "$SDK_PATH" --scratch-path "$BUILD_DIR" >/dev/null
BIN_DIR="$(swift build --package-path "$ROOT_DIR" --sdk "$SDK_PATH" --scratch-path "$BUILD_DIR" --show-bin-path)"
cat > "$WORK_DIR/main.swift" <<'SWIFT'
@_spi(ForSwiftPM) import Testing
import Darwin
@main struct FeatureTestMain {
    static func main() async { let status: CInt = await Testing.__swiftPMEntryPoint(); exit(status) }
}
SWIFT
CORE_ARGS=()
if [[ -f "$BIN_DIR/CodexProfileCore.o" ]]; then
    CORE_ARGS=(-I "$BIN_DIR" "$BIN_DIR/CodexProfileCore.o")
else
    CORE_ARGS=(-I "$BIN_DIR/Modules" "$BIN_DIR/CodexProfileCore.build/"*.o)
fi
PLUGIN_ARGS=()
TESTING_PLUGIN="$(xcode-select -p)/usr/lib/swift/host/plugins/testing/libTestingMacros.dylib"
if [[ -f "$TESTING_PLUGIN" ]]; then PLUGIN_ARGS=(-load-plugin-library "$TESTING_PLUGIN"); fi
TESTING_FRAMEWORKS="$(xcode-select -p)/Library/Developer/Frameworks"
swiftc -parse-as-library -sdk "$SDK_PATH" -F "$TESTING_FRAMEWORKS" \
    -Xlinker -rpath -Xlinker "$TESTING_FRAMEWORKS" "${PLUGIN_ARGS[@]}" "${CORE_ARGS[@]}" \
    "$ROOT_DIR/Tests/AuthBlobTests/AuthCredentialUpdateTests.swift" \
    "$ROOT_DIR/Tests/AuthBlobTests/BankedResetScheduleTests.swift" "$WORK_DIR/main.swift" \
    -o "$WORK_DIR/feature-tests"
DYLD_LIBRARY_PATH="/Library/Developer/CommandLineTools/Library/Developer/usr/lib${DYLD_LIBRARY_PATH:+:$DYLD_LIBRARY_PATH}" "$WORK_DIR/feature-tests"
