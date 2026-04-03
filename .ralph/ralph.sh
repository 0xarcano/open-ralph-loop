#!/usr/bin/env bash
# Open Ralph — autonomous AI loop for OpenCode only (Ralph-style).
# Inspired by https://github.com/snarktank/ralph
#
# Usage (from repository root): ./ralph.sh [max_iterations]
#   or: .ralph/ralph.sh [max_iterations]
#
# Requires: opencode (https://opencode.ai/), jq, curl
# Optional env in .ralph/.env (Ralph/OpenCode only; separate from project-root .env):
#   RALPH_MODEL        — opencode run --model (e.g. anthropic/claude-sonnet-4-20250514)
#   RALPH_AGENT        — opencode run --agent (e.g. ralph)
#   RALPH_ATTACH       — opencode run --attach (e.g. http://localhost:4096)
#   RALPH_PROMPT_FILE  — prompt file relative to .ralph/ (default prompt.md)
#   RALPH_VLLM_URL     — vLLM base URL for pre-flight check (default: from .opencode/opencode.json)
#   RALPH_VLLM_API_KEY — API key env var name for pre-flight (default: VLLM_API_KEY)
#   RALPH_MIN_CTX      — minimum context tokens required (default: 4096)
#   RALPH_MAX_OUTPUT_TOKENS — optional upper bound for OPENCODE_EXPERIMENTAL_OUTPUT_TOKEN_MAX
#                             after the completion budget is computed (see below)
#   RALPH_COMPLETION_HARD_CAP — max completion tokens after the max_len/4 rule (default 8192).
#                               Raise only if you have a very large max_model_len and need long replies.
#   RALPH_FALLBACK_MAX_OUTPUT — when GET /v1/models fails (network), cap output tokens (default 8192)
#   RALPH_ABORT_ON_FAKE_TOOLS — if 1, exit 2 when output looks like markdown/XML “tools” (vLLM not
#                               returning real tool_calls; see vLLM --enable-auto-tool-choice)
#   RALPH_DISABLE_AUTOCOMPACT — if 1, set OPENCODE_DISABLE_AUTOCOMPACT (autocompact is ON by default)
#   RALPH_ITERATION_LOG_KEEP — max iteration blocks kept in progress.txt; older ones archived (default 5)
#
# OpenCode runs with cwd = project root; PRD/progress live under .ralph/

set -euo pipefail

OPENCODE_MIN_SYSTEM_PROMPT_TOKENS=900

MAX_ITERATIONS=10
while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help)
      echo "Usage: $0 [max_iterations]"
      exit 0
      ;;
    *)
      if [[ "$1" =~ ^[0-9]+$ ]]; then
        MAX_ITERATIONS="$1"
      else
        echo "Unknown argument: $1" >&2; exit 1
      fi
      shift
      ;;
  esac
done

for cmd in opencode jq curl; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "Error: '$cmd' not found." >&2; exit 1
  fi
done

RALPH_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$RALPH_HOME/.." && pwd)"
PRD_FILE="$RALPH_HOME/prd.json"
PROGRESS_FILE="$RALPH_HOME/progress.txt"
ARCHIVE_DIR="$RALPH_HOME/archive"
LAST_BRANCH_FILE="$RALPH_HOME/.last-branch"
ENV_FILE="$RALPH_HOME/.env"

# ── Load Ralph env (.ralph/.env — not the project app .env at repo root) ─────
if [[ -f "$ENV_FILE" ]]; then
  set -a
  # shellcheck disable=SC1090
  source "$ENV_FILE"
  set +a
else
  echo "Warning: missing $ENV_FILE (create it for VLLM_API_KEY, RALPH_*, etc.)." >&2
fi

# ── Resolve prompt file (under .ralph/) ──────────────────────────────────────
if [[ -n "${RALPH_PROMPT_FILE:-}" ]]; then
  if [[ "${RALPH_PROMPT_FILE}" == /* ]]; then
    PROMPT_FILE="${RALPH_PROMPT_FILE}"
  else
    PROMPT_FILE="$RALPH_HOME/${RALPH_PROMPT_FILE}"
  fi
else
  PROMPT_FILE="$RALPH_HOME/prompt.md"
fi
[[ -f "$PROMPT_FILE" ]] || { echo "Error: Missing $PROMPT_FILE" >&2; exit 1; }

# ── Resolve OpenCode model id (for preflight max_model_len match) ───────────
ralph_resolve_oc_model() {
  local m=""
  [[ -n "${RALPH_MODEL:-}" ]] && m="$RALPH_MODEL"
  if [[ -z "$m" ]]; then
    for cfg in "$PROJECT_ROOT/.opencode/opencode.json" \
               "$HOME/.config/opencode/opencode.json" \
               "$PROJECT_ROOT/opencode.json"; do
      if [[ -f "$cfg" ]]; then
        m="$(jq -r 'if (.model | type == "string") then .model else empty end' "$cfg" 2>/dev/null || true)"
        [[ -n "$m" ]] && break
      fi
    done
  fi
  printf '%s' "$m"
}

# ── Pre-flight: query vLLM max_model_len ─────────────────────────────────────
preflight_check() {
  local base_url="${RALPH_VLLM_URL:-}"
  local api_key="${VLLM_API_KEY:-}"
  local min_ctx="${RALPH_MIN_CTX:-4096}"

  if [[ -z "$base_url" ]]; then
    for cfg in "$PROJECT_ROOT/.opencode/opencode.json" \
               "$HOME/.config/opencode/opencode.json" \
               "$PROJECT_ROOT/opencode.json"; do
      if [[ -f "$cfg" ]]; then
        base_url="$(jq -r '.. | .baseURL? // empty' "$cfg" 2>/dev/null | head -1)"
        [[ -n "$base_url" ]] && break
      fi
    done
  fi

  [[ -z "$base_url" ]] && return 0

  local oc_model
  oc_model="$(ralph_resolve_oc_model)"

  local auth_header=""
  [[ -n "$api_key" ]] && auth_header="Authorization: Bearer $api_key"

  local resp
  resp="$(curl -sf --max-time 5 ${auth_header:+-H "$auth_header"} "${base_url}/models" 2>/dev/null)" || return 0

  local max_len=""
  if [[ "$oc_model" == vllm/* ]]; then
    local vid="${oc_model#vllm/}"
    max_len="$(echo "$resp" | jq -r --arg id "$vid" '(.data[]? | select(.id == $id) | .max_model_len) // empty' 2>/dev/null | head -1)"
  fi
  if [[ -z "$max_len" ]]; then
    max_len="$(echo "$resp" | jq -r '.data[0].max_model_len // empty' 2>/dev/null)"
  fi
  [[ -z "$max_len" ]] && return 0

  export RALPH_VLLM_MAX_MODEL_LEN="$max_len"
  echo "Pre-flight: vLLM max_model_len = $max_len (minimum required: $min_ctx)"
  if [[ "$oc_model" == vllm/* ]]; then
    local vid="${oc_model#vllm/}"
    if echo "$resp" | jq -e --arg id "$vid" '[.data[]? | select(.id == $id)] | length > 0' >/dev/null 2>&1; then
      echo "Pre-flight: vLLM lists model id '$vid' (matches OpenCode model)"
    else
      echo "" >&2
      echo "═══════════════════════════════════════════════════════════════════" >&2
      echo "  FATAL: OpenCode is set to vllm/$vid but that id is missing from GET ${base_url}/models." >&2
      echo "" >&2
      echo "  Fix one of:" >&2
      echo "    • Serve that model in vLLM, or" >&2
      echo "    • Set RALPH_MODEL to a served id and add the same key under provider.vllm.models in opencode.json." >&2
      echo "" >&2
      echo "  Served model ids (use exactly, including case):" >&2
      echo "$resp" | jq -r '.data[]? | "    \(.id)"' >&2
      echo "═══════════════════════════════════════════════════════════════════" >&2
      exit 2
    fi
  fi

  if [[ "$max_len" -lt "$min_ctx" ]]; then
    echo "" >&2
    echo "═══════════════════════════════════════════════════════════════════" >&2
    echo "  FATAL: vLLM max_model_len ($max_len) is too small for OpenCode." >&2
    echo "" >&2
    echo "  OpenCode's system prompt alone uses ~$OPENCODE_MIN_SYSTEM_PROMPT_TOKENS tokens." >&2
    echo "  With max_model_len=$max_len there is no room for output." >&2
    echo "" >&2
    echo "  FIX: restart vLLM with a larger --max-model-len, e.g.:" >&2
    echo "" >&2
    echo "    vllm serve Qwen/Qwen2.5-7B-Instruct-AWQ \\" >&2
    echo "      --max-model-len 8192 \\" >&2
    echo "      --enable-auto-tool-choice \\" >&2
    echo "      --tool-call-parser hermes" >&2
    echo "" >&2
    echo "  Or use a hosted provider (anthropic, openai, etc.)." >&2
    echo "═══════════════════════════════════════════════════════════════════" >&2
    exit 2
  fi

  # vLLM rejects when prompt_tokens + max_tokens > max_model_len. Agent turns often carry
  # ~10k–20k+ tokens of input (system + history + tool outputs). Using max_len/2 for
  # max_tokens routinely overflows (e.g. 16k prompt + 16k max > 32k).
  local quarter=$(( max_len / 4 ))
  local max_output="$quarter"
  [[ $max_output -lt 256 ]] && max_output=256
  local hard_cap="${RALPH_COMPLETION_HARD_CAP:-8192}"
  if [[ "$max_output" -gt "$hard_cap" ]]; then
    max_output="$hard_cap"
  fi

  if [[ -n "${RALPH_MAX_OUTPUT_TOKENS:-}" ]] && [[ "${RALPH_MAX_OUTPUT_TOKENS}" =~ ^[0-9]+$ ]] \
     && [[ "$max_output" -gt "${RALPH_MAX_OUTPUT_TOKENS}" ]]; then
    max_output="${RALPH_MAX_OUTPUT_TOKENS}"
    echo "Pre-flight: further capped max output to RALPH_MAX_OUTPUT_TOKENS=$max_output"
  fi

  local current="${OPENCODE_EXPERIMENTAL_OUTPUT_TOKEN_MAX:-32000}"
  if [[ "$current" -gt "$max_output" ]]; then
    export OPENCODE_EXPERIMENTAL_OUTPUT_TOKEN_MAX="$max_output"
    echo "Pre-flight: set OPENCODE_EXPERIMENTAL_OUTPUT_TOKEN_MAX to $max_output (max_model_len=$max_len, completion budget ≈ min(max_len/4, RALPH_COMPLETION_HARD_CAP=${RALPH_COMPLETION_HARD_CAP:-8192}))"
  fi
}

ralph_ensure_output_token_cap_without_vllm() {
  [[ -n "${RALPH_VLLM_MAX_MODEL_LEN:-}" ]] && return 0
  local fb="${RALPH_FALLBACK_MAX_OUTPUT:-8192}"
  if [[ -n "${RALPH_MAX_OUTPUT_TOKENS:-}" ]] && [[ "${RALPH_MAX_OUTPUT_TOKENS}" =~ ^[0-9]+$ ]] \
     && [[ "$fb" -gt "${RALPH_MAX_OUTPUT_TOKENS}" ]]; then
    fb="${RALPH_MAX_OUTPUT_TOKENS}"
  fi
  local cur="${OPENCODE_EXPERIMENTAL_OUTPUT_TOKEN_MAX:-32000}"
  if [[ "$cur" -gt "$fb" ]]; then
    export OPENCODE_EXPERIMENTAL_OUTPUT_TOKEN_MAX="$fb"
    echo "" >&2
    echo "Pre-flight: could not read vLLM max_model_len (unreachable ${RALPH_VLLM_URL:-opencode.json baseURL}?)." >&2
    echo "            Set RALPH_VLLM_URL to a reachable GET .../v1/models endpoint, or tune RALPH_FALLBACK_MAX_OUTPUT." >&2
    echo "            Applying OPENCODE_EXPERIMENTAL_OUTPUT_TOKEN_MAX=$fb so requests stay under typical context." >&2
  fi
}

ralph_all_stories_pass() {
  [[ -f "$PRD_FILE" ]] || return 1
  jq -e '
    (.userStories | type == "array")
    and ((.userStories | length) > 0)
    and ([.userStories[] | select(.passes == false)] | length == 0)
  ' "$PRD_FILE" >/dev/null 2>&1
}

ralph_output_has_standalone_complete_promise() {
  echo "$1" | grep -qE '^[[:space:]]*<promise>COMPLETE</promise>[[:space:]]*$'
}

ralph_output_looks_like_unexecuted_tool_markdown() {
  local out="$1"
  if echo "$out" | grep -qE '```(json|JSON|xml|XML)' \
     && echo "$out" | grep -qE '"name"[[:space:]]*:[[:space:]]*"(read|bash|edit|write|glob|grep)"'; then
    return 0
  fi
  if echo "$out" | grep -qE '<(read|bash|write|edit|glob|grep)[[:space:]]*>'; then
    return 0
  fi
  return 1
}

ralph_warn_vllm_tool_calling() {
  echo "" >&2
  echo "═══════════════════════════════════════════════════════════════════" >&2
  echo "  WARNING: Output looks like tool calls in plain text (markdown/XML), not API tool_calls." >&2
  echo "  OpenCode only runs tools when vLLM returns a non-empty tool_calls array on the chat" >&2
  echo "  completion response. If that array is empty, nothing executes — this is not an OpenCode bug." >&2
  echo "" >&2
  echo "  Qwen2.5-Coder vs Hermes: vLLM’s docs suggest hermes for Qwen2.5, but Qwen2.5-Coder" >&2
  echo "  models often write tools as free text (code fences, <read>-style tags). The Hermes" >&2
  echo "  parser does not turn that into tool_calls (see vLLM #10952, #32926). So enabling" >&2
  echo "  --enable-auto-tool-choice --tool-call-parser hermes is not enough for many Coder runs." >&2
  echo "" >&2
  echo "  What usually works:" >&2
  echo "    • Serve Qwen2.5-*-Instruct (non-Coder), same Hermes flags — tool calling matches docs." >&2
  echo "    • Or use a vLLM build/plugin with a Qwen2.5-Coder-specific parser when available." >&2
  echo "    • Or use a hosted model (Anthropic/OpenAI) for OpenCode agent loops." >&2
  echo "" >&2
  echo "  https://docs.vllm.ai/en/latest/features/tool_calling/" >&2
  echo "═══════════════════════════════════════════════════════════════════" >&2
}

# Strip newlines/CR so .last-branch and jq output compare equal (else progress.txt resets every run).
ralph_normalize_branch() {
  local s="${1:-}"
  s="${s//$'\r'/}"
  s="${s//$'\n'/}"
  printf '%s' "$s"
}

ralph_write_progress_skeleton() {
  {
    echo "# Open Ralph Progress Log"
    echo "Started: $(date)"
    echo "---"
    echo ""
    echo "## Codebase Patterns"
    echo ""
    echo "_Agent-maintained reusable patterns for this codebase._"
    echo ""
    echo "---"
    echo ""
    echo "## Story log"
    echo ""
    echo "_One \"## [Date/Time] - [Story ID]\" block per completed story — insert before \`<!--RALPH:END_STORY_LOG-->\` (.ralph/prompt.md)._"
    echo ""
    echo "<!--RALPH:END_STORY_LOG-->"
    echo ""
    echo "## Iteration log (ralph.sh)"
    echo ""
  } > "$PROGRESS_FILE"
}

# Older progress.txt files appended iteration blocks right after Codebase Patterns, so agents never
# had a stable place for story blocks. Insert ## Story log + marker + ## Iteration log before the
# first automatic iteration entry.
ralph_ensure_progress_story_sections() {
  [[ -f "$PROGRESS_FILE" ]] || return 0
  grep -q 'RALPH:END_STORY_LOG' "$PROGRESS_FILE" 2>/dev/null && return 0

  local tmp in_patterns inserted
  tmp="$(mktemp)"
  in_patterns=0
  inserted=0
  while IFS= read -r line || [[ -n "$line" ]]; do
    printf '%s\n' "$line"
    if [[ "$line" == '## Codebase Patterns' ]]; then
      in_patterns=1
    elif [[ "$in_patterns" -eq 1 ]] && [[ "$line" == '---' ]] && [[ "$inserted" -eq 0 ]]; then
      printf '\n## Story log\n\n_One "## [Date/Time] - [Story ID]" block per completed story — insert before the line `<!--RALPH:END_STORY_LOG-->` (.ralph/prompt.md)._\n\n<!--RALPH:END_STORY_LOG-->\n\n## Iteration log (ralph.sh)\n\n'
      inserted=1
      in_patterns=2
    fi
  done < "$PROGRESS_FILE" > "$tmp" && mv "$tmp" "$PROGRESS_FILE"

  if ! grep -q 'RALPH:END_STORY_LOG' "$PROGRESS_FILE" 2>/dev/null; then
    tmp="$(mktemp)"
    local inserted_fb=0
    while IFS= read -r line || [[ -n "$line" ]]; do
      if [[ "$inserted_fb" -eq 0 ]] && [[ "$line" == "##"* ]] && [[ "$line" == *"Open Ralph iteration"* ]]; then
        printf '\n## Story log\n\n_One "## [Date/Time] - [Story ID]" block per completed story — insert before `<!--RALPH:END_STORY_LOG-->` (.ralph/prompt.md)._\n\n<!--RALPH:END_STORY_LOG-->\n\n## Iteration log (ralph.sh)\n\n'
        inserted_fb=1
      fi
      printf '%s\n' "$line"
    done < "$PROGRESS_FILE" > "$tmp" && mv "$tmp" "$PROGRESS_FILE"
  fi
}

# Append after each OpenCode run so the log always moves forward even if the model skips step 10.
ralph_append_iteration_record() {
  local iter="$1" max_iter="$2" rc="$3" title="$4"
  {
    echo "## $(date -Iseconds) — Open Ralph iteration ${iter}/${max_iter} (ralph.sh)"
    echo "- OpenCode exit code: ${rc}"
    echo "- Session title: ${title}"
    echo "- Story updates belong in **## Story log** above, before \`<!--RALPH:END_STORY_LOG-->\` (see .ralph/prompt.md)."
    echo "---"
    echo ""
  } >> "$PROGRESS_FILE"
}

# Keep the last N iteration blocks in progress.txt; archive older blocks to .ralph/archive/
ralph_rotate_iteration_log() {
  local keep="${RALPH_ITERATION_LOG_KEEP:-5}"
  [[ "$keep" =~ ^[0-9]+$ ]] || keep=5
  [[ "$keep" -eq 0 ]] && return 0
  [[ -f "$PROGRESS_FILE" ]] || return 0
  command -v python3 >/dev/null 2>&1 || return 0
  mkdir -p "$ARCHIVE_DIR"
  RALPH_PROGRESS_FILE="$PROGRESS_FILE" RALPH_ARCHIVE_DIR="$ARCHIVE_DIR" RALPH_KEEP="$keep" python3 - <<'PY'
import os, re, sys
from datetime import datetime

path = os.environ["RALPH_PROGRESS_FILE"]
arch_dir = os.environ["RALPH_ARCHIVE_DIR"]
keep = int(os.environ["RALPH_KEEP"])

text = open(path, encoding="utf-8").read()
marker = "## Iteration log (ralph.sh)\n"
if marker not in text:
    sys.exit(0)
idx = text.index(marker) + len(marker)
head = text[:idx]
tail = text[idx:]
pat = re.compile(r"^## [0-9]{4}-[0-9]{2}-[0-9]{2}T.*— Open Ralph iteration", re.MULTILINE)
matches = list(pat.finditer(tail))
if len(matches) <= keep:
    sys.exit(0)
blocks = []
for i, m in enumerate(matches):
    start = m.start()
    end = matches[i + 1].start() if i + 1 < len(matches) else len(tail)
    blocks.append(tail[start:end])
archive_blocks = blocks[:-keep]
keep_blocks = blocks[-keep:]
stamp = datetime.now().strftime("%Y-%m-%d-%H%M%S")
archive_path = os.path.join(arch_dir, f"iteration-log-{stamp}.txt")
with open(archive_path, "w", encoding="utf-8") as f:
    f.write("".join(archive_blocks))
with open(path, "w", encoding="utf-8") as f:
    f.write(head + "".join(keep_blocks))
print(f"Ralph: archived {len(archive_blocks)} iteration log block(s) → {archive_path}", file=sys.stderr)
PY
}

ralph_ensure_progress_patterns_section() {
  [[ -f "$PROGRESS_FILE" ]] || return 0
  if grep -qE '^## Codebase Patterns[[:space:]]*$' "$PROGRESS_FILE" 2>/dev/null; then
    return 0
  fi
  local tmp
  tmp="$(mktemp)"
  {
    head -n 3 "$PROGRESS_FILE"
    echo ""
    echo "## Codebase Patterns"
    echo ""
    echo "_Agent-maintained reusable patterns for this codebase._"
    echo ""
    echo "---"
    echo ""
    tail -n +4 "$PROGRESS_FILE"
  } > "$tmp" && mv "$tmp" "$PROGRESS_FILE"
}

ralph_preflight_warn_qwen_coder_family() {
  local m
  m="$(ralph_resolve_oc_model)"
  [[ -z "$m" ]] && return 0
  case "${m#vllm/}" in
    *Coder*|*coder*) ;;
    *) return 0 ;;
  esac
  echo "Pre-flight: model id mentions Coder — if tools never execute, Hermes + this checkpoint" >&2
  echo "            often leave tool_calls empty; try Qwen2.5-*-Instruct (non-Coder) for agents." >&2
}

preflight_check
ralph_ensure_output_token_cap_without_vllm
ralph_preflight_warn_qwen_coder_family

# Autocompact is ON by default (reduces unbounded multi-turn context). Set RALPH_DISABLE_AUTOCOMPACT=1 for old behavior.
if [[ "${RALPH_DISABLE_AUTOCOMPACT:-0}" == "1" ]]; then
  export OPENCODE_DISABLE_AUTOCOMPACT=true
fi

if [[ -f "$PRD_FILE" && -f "$LAST_BRANCH_FILE" ]]; then
  CURRENT_BRANCH="$(ralph_normalize_branch "$(jq -r '.branchName // empty' "$PRD_FILE" 2>/dev/null || echo "")")"
  LAST_BRANCH="$(ralph_normalize_branch "$(cat "$LAST_BRANCH_FILE" 2>/dev/null || echo "")")"
  if [[ -n "$CURRENT_BRANCH" && -n "$LAST_BRANCH" && "$CURRENT_BRANCH" != "$LAST_BRANCH" ]]; then
    ARCHIVE_FOLDER="$ARCHIVE_DIR/$(date +%Y-%m-%d)-$(echo "$LAST_BRANCH" | sed 's|^ralph/||')"
    echo "Archiving previous run → $ARCHIVE_FOLDER"
    mkdir -p "$ARCHIVE_FOLDER"
    [[ -f "$PRD_FILE" ]] && cp "$PRD_FILE" "$ARCHIVE_FOLDER/"
    [[ -f "$PROGRESS_FILE" ]] && cp "$PROGRESS_FILE" "$ARCHIVE_FOLDER/"
    ralph_write_progress_skeleton
  fi
fi

if [[ -f "$PRD_FILE" ]]; then
  CURRENT_BRANCH="$(ralph_normalize_branch "$(jq -r '.branchName // empty' "$PRD_FILE" 2>/dev/null || echo "")")"
  [[ -n "$CURRENT_BRANCH" ]] && printf '%s\n' "$CURRENT_BRANCH" > "$LAST_BRANCH_FILE"
fi

[[ -f "$PROGRESS_FILE" ]] || ralph_write_progress_skeleton
ralph_ensure_progress_patterns_section
ralph_ensure_progress_story_sections

RUN_ARGS=(run)
[[ -n "${RALPH_MODEL:-}" ]]  && RUN_ARGS+=(--model "$RALPH_MODEL")
[[ -n "${RALPH_AGENT:-}" ]]  && RUN_ARGS+=(--agent "$RALPH_AGENT")
[[ -n "${RALPH_ATTACH:-}" ]] && RUN_ARGS+=(--attach "$RALPH_ATTACH")

PROMPT_CONTENT="$(cat "$PROMPT_FILE")"

echo "Starting Open Ralph — max iterations: $MAX_ITERATIONS"
echo "OpenCode: $(command -v opencode)"
echo "Working directory (OpenCode cwd): $PROJECT_ROOT"
echo "Ralph data: $RALPH_HOME"
[[ -n "${RALPH_MODEL:-}" ]]  && echo "  model:  $RALPH_MODEL"
[[ -n "${RALPH_AGENT:-}" ]]  && echo "  agent:  $RALPH_AGENT"
[[ -n "${RALPH_ATTACH:-}" ]] && echo "  attach: $RALPH_ATTACH"
echo "  prompt: $PROMPT_FILE"

cd "$PROJECT_ROOT"

for i in $(seq 1 "$MAX_ITERATIONS"); do
  echo ""
  echo "==============================================================="
  echo "  Open Ralph iteration $i of $MAX_ITERATIONS"
  echo "==============================================================="

  if ralph_all_stories_pass; then
    echo ""
    echo "Open Ralph: all user stories in .ralph/prd.json have passes: true (verified with jq)."
    exit 0
  fi

  TITLE="open-ralph-${i}-$(date +%s)-${RANDOM}"

  set +e
  TMP_OUT="$(mktemp)"
  opencode "${RUN_ARGS[@]}" --title "$TITLE" "$PROMPT_CONTENT" 2>&1 | tee "$TMP_OUT"
  RC=$?
  OUTPUT="$(cat "$TMP_OUT")"
  rm -f "$TMP_OUT"
  set -e

  [[ "$RC" -ne 0 ]] && echo "Warning: opencode exited $RC" >&2

  ralph_append_iteration_record "$i" "$MAX_ITERATIONS" "$RC" "$TITLE"
  ralph_rotate_iteration_log

  if echo "$OUTPUT" | grep -q "maximum context length"; then
    echo "" >&2
    if echo "$OUTPUT" | grep -qE "output tokens|max_tokens|requested.*output"; then
      echo "FATAL: prompt + max output tokens exceed model context (often OpenCode default 32k output)." >&2
      echo "       Ensure ./ralph.sh preflight can curl vLLM (set RALPH_VLLM_URL), or set" >&2
      echo "       OPENCODE_EXPERIMENTAL_OUTPUT_TOKEN_MAX or RALPH_FALLBACK_MAX_OUTPUT in .ralph/.env." >&2
    else
      echo "FATAL: context length exceeded. Raise vLLM --max-model-len or shorten the agent prompt/tools." >&2
    fi
    exit 2
  fi

  if ralph_all_stories_pass; then
    echo ""
    echo "Open Ralph: all user stories in .ralph/prd.json have passes: true after iteration $i."
    exit 0
  fi

  if ralph_output_has_standalone_complete_promise "$OUTPUT"; then
    echo "" >&2
    echo "Warning: model printed a standalone <promise>COMPLETE</promise> but .ralph/prd.json still has stories with passes: false." >&2
    echo "         Ignoring (likely hallucinated or narrative). Continue loop or fix vLLM tool-calling." >&2
  fi

  if ralph_output_looks_like_unexecuted_tool_markdown "$OUTPUT"; then
    ralph_warn_vllm_tool_calling
    [[ "${RALPH_ABORT_ON_FAKE_TOOLS:-0}" == "1" ]] && exit 2
  fi

  echo "Iteration $i done. Continuing..."
  sleep 2
done

echo ""
echo "Open Ralph reached max iterations ($MAX_ITERATIONS)."
echo "Check $PROGRESS_FILE and $PRD_FILE."
exit 1
