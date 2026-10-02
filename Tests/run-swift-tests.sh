#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

if [[ -z "${DEVELOPER_DIR:-}" && -d /Applications/Xcode.app ]]; then
  export DEVELOPER_DIR=/Applications/Xcode.app
fi

SDK_ARGS=()
if [[ -n "${CODEX_PROFILE_SDK:-}" ]]; then
  SDK_ARGS=(--sdk "$CODEX_PROFILE_SDK")
fi
swift test --package-path "$ROOT_DIR" ${SDK_ARGS[@]+"${SDK_ARGS[@]}"}
