#!/usr/bin/env bash
# Legacy helper. Open Ralph Loop is now an OpenCode plugin.
set -euo pipefail

cat <<'EOF'
Open Ralph Loop is now an OpenCode plugin.

Install/use it from OpenCode:

  {
    "plugin": ["open-ralph-loop"]
  }

Then run one of:

  /ralph-loop docs/specs/my-feature.json
  /ralph-loop lisa/my-feature.json
  /ralph-loop my-feature

The legacy bash outer loop is no longer the primary runtime.
EOF
