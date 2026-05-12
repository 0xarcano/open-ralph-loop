#!/usr/bin/env bash
# Legacy helper. Open Ralph Loop is now an OpenCode plugin.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
exec "$ROOT/ralph.sh" "$@"
