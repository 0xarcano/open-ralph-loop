#!/usr/bin/env bash
# Open Ralph — autonomous AI loop for OpenCode only (Ralph-style).
# Inspired by https://github.com/snarktank/ralph
#
# Usage: ./ralph.sh [max_iterations]
#
# Requires: opencode (https://opencode.ai/), jq
# Optional env:
#   RALPH_MODEL   — passed to opencode run as --model (e.g. anthropic/claude-sonnet-4-20250514)
#   RALPH_AGENT   — passed to opencode run as --agent
#   RALPH_ATTACH  — URL for opencode run --attach (e.g. http://localhost:4096)

set -euo pipefail

MAX_ITERATIONS=10
while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help)
      echo "Usage: $0 [max_iterations]"
      echo "Env: RALPH_MODEL, RALPH_AGENT, RALPH_ATTACH"
      exit 0
      ;;
    *)
      if [[ "$1" =~ ^[0-9]+$ ]]; then
        MAX_ITERATIONS="$1"
      else
        echo "Unknown argument: $1" >&2
        exit 1
      fi
      shift
      ;;
  esac
done

if ! command -v opencode >/dev/null 2>&1; then
  echo "Error: 'opencode' not found. Install OpenCode: https://opencode.ai/ or https://github.com/opencode-ai/opencode" >&2
  exit 1
fi

if ! command -v jq >/dev/null 2>&1; then
  echo "Error: 'jq' not found. Install jq (e.g. apt install jq, brew install jq)." >&2
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PRD_FILE="$SCRIPT_DIR/prd.json"
PROMPT_FILE="$SCRIPT_DIR/prompt.md"
PROGRESS_FILE="$SCRIPT_DIR/progress.txt"
ARCHIVE_DIR="$SCRIPT_DIR/archive"
LAST_BRANCH_FILE="$SCRIPT_DIR/.last-branch"

if [[ ! -f "$PROMPT_FILE" ]]; then
  echo "Error: Missing $PROMPT_FILE" >&2
  exit 1
fi

# Archive previous run if PRD branch changed (same behavior as upstream Ralph)
if [[ -f "$PRD_FILE" && -f "$LAST_BRANCH_FILE" ]]; then
  CURRENT_BRANCH="$(jq -r '.branchName // empty' "$PRD_FILE" 2>/dev/null || echo "")"
  LAST_BRANCH="$(cat "$LAST_BRANCH_FILE" 2>/dev/null || echo "")"

  if [[ -n "$CURRENT_BRANCH" && -n "$LAST_BRANCH" && "$CURRENT_BRANCH" != "$LAST_BRANCH" ]]; then
    DATE="$(date +%Y-%m-%d)"
    FOLDER_NAME="$(echo "$LAST_BRANCH" | sed 's|^ralph/||')"
    ARCHIVE_FOLDER="$ARCHIVE_DIR/$DATE-$FOLDER_NAME"

    echo "Archiving previous run: $LAST_BRANCH"
    mkdir -p "$ARCHIVE_FOLDER"
    [[ -f "$PRD_FILE" ]] && cp "$PRD_FILE" "$ARCHIVE_FOLDER/"
    [[ -f "$PROGRESS_FILE" ]] && cp "$PROGRESS_FILE" "$ARCHIVE_FOLDER/"
    echo "   Archived to: $ARCHIVE_FOLDER"

    echo "# Open Ralph Progress Log" > "$PROGRESS_FILE"
    echo "Started: $(date)" >> "$PROGRESS_FILE"
    echo "---" >> "$PROGRESS_FILE"
  fi
fi

if [[ -f "$PRD_FILE" ]]; then
  CURRENT_BRANCH="$(jq -r '.branchName // empty' "$PRD_FILE" 2>/dev/null || echo "")"
  if [[ -n "$CURRENT_BRANCH" ]]; then
    echo "$CURRENT_BRANCH" > "$LAST_BRANCH_FILE"
  fi
fi

if [[ ! -f "$PROGRESS_FILE" ]]; then
  echo "# Open Ralph Progress Log" > "$PROGRESS_FILE"
  echo "Started: $(date)" >> "$PROGRESS_FILE"
  echo "---" >> "$PROGRESS_FILE"
fi

RUN_ARGS=(run)
if [[ -n "${RALPH_MODEL:-}" ]]; then
  RUN_ARGS+=(--model "$RALPH_MODEL")
fi
if [[ -n "${RALPH_AGENT:-}" ]]; then
  RUN_ARGS+=(--agent "$RALPH_AGENT")
fi
if [[ -n "${RALPH_ATTACH:-}" ]]; then
  RUN_ARGS+=(--attach "$RALPH_ATTACH")
fi

PROMPT_CONTENT="$(cat "$PROMPT_FILE")"

echo "Starting Open Ralph — max iterations: $MAX_ITERATIONS"
echo "OpenCode: $(command -v opencode)"
echo "Working directory: $SCRIPT_DIR"
if [[ -n "${RALPH_MODEL:-}" ]]; then echo "RALPH_MODEL=$RALPH_MODEL"; fi
if [[ -n "${RALPH_AGENT:-}" ]]; then echo "RALPH_AGENT=$RALPH_AGENT"; fi
if [[ -n "${RALPH_ATTACH:-}" ]]; then echo "RALPH_ATTACH=$RALPH_ATTACH"; fi

cd "$SCRIPT_DIR"

for i in $(seq 1 "$MAX_ITERATIONS"); do
  echo ""
  echo "==============================================================="
  echo "  Open Ralph iteration $i of $MAX_ITERATIONS (OpenCode)"
  echo "==============================================================="

  # Fresh non-interactive run; capture output for completion detection.
  # Do not wrap the pipeline in $(...): the subshell used for command substitution
  # does not populate the parent's PIPESTATUS, so ${PIPESTATUS[0]} here would be wrong.
  # With pipefail (set at top), $? after the pipeline reflects opencode if it failed.
  set +e
  TMP_OUT="$(mktemp)"
  opencode "${RUN_ARGS[@]}" "$PROMPT_CONTENT" 2>&1 | tee /dev/stderr | tee "$TMP_OUT" >/dev/null
  RC=$?
  OUTPUT="$(cat "$TMP_OUT")"
  rm -f "$TMP_OUT"
  set -e

  if [[ "$RC" -ne 0 ]]; then
    echo "Warning: opencode run exited with status $RC (continuing loop)." >&2
  fi

  if echo "$OUTPUT" | grep -q "<promise>COMPLETE</promise>"; then
    echo ""
    echo "Open Ralph completed all tasks."
    echo "Finished at iteration $i of $MAX_ITERATIONS"
    exit 0
  fi

  echo "Iteration $i complete. Continuing..."
  sleep 2
done

echo ""
echo "Open Ralph reached max iterations ($MAX_ITERATIONS) without completing all tasks."
echo "Check $PROGRESS_FILE and prd.json."
exit 1
