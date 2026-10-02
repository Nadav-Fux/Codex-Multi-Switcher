#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export CODEX_MULTI_SWITCHER_BUILD_MODE=local
exec bash "$SCRIPT_DIR/package_preview.sh" "$@"
