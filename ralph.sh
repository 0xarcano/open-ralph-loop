#!/usr/bin/env bash
# Wrapper: run Open Ralph from repository root (implementation in .ralph/).
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec "$ROOT/.ralph/ralph.sh" "$@"
