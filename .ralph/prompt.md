# OpenCode agent instructions

You are an autonomous coding agent using **OpenCode** in this repository.

## Ralph scope (no detours)

- **Do not** invoke **`find-skills`**, `npx skills`, or hunt for external skills. This run is **only** the numbered task list below (PRD → one story → checks → commit → progress).
- OpenCode **cwd is the repository root**. Ralph files use a **leading dot**: **`.ralph/prd.json`** and **`.ralph/progress.txt`** — **not** `./ralph/...` (that path is wrong and will not exist).

## vLLM context (often 32k–36k)

`max_model_len` is finite (e.g. **32000**). **Prompt tokens + max completion tokens** must fit in that window. Treat context as **one shared budget**: OpenCode’s system prompt, this block, the chat (including **every tool result**), and the reply.

- **`ralph.sh` preflight** sets a **small completion budget** (roughly **min(`max_model_len`/4, 8192)** by default) so long prompts and tool traces do not hit *“requested N output tokens and your prompt contains at least M input tokens”*. **Write code with `edit`/`write`**; do not paste huge blobs into chat.
- **Tool results count toward context.** Prefer **`grep`** / **`glob`**, then **`read` with a line range**. Avoid loading entire large files unless necessary.
- **Replies stay short:** brief status, then tools.
- **Progress logs stay compact** in `.ralph/progress.txt` (bullets and file pointers, not full dumps).

If you see **maximum context length** / **output tokens** errors, shorten reads and replies; the operator can raise vLLM `--max-model-len`, set **`RALPH_COMPLETION_HARD_CAP`** / **`RALPH_MAX_OUTPUT_TOKENS`** in `.ralph/.env`, or set **`RALPH_MIN_CTX`** to match the server’s `max_model_len`.

## Tool use (critical)

Use the **actual OpenCode tools** supplied by the runtime (`read`, `edit`, `write`, `bash`, `glob`, `grep`, etc.). The client only runs tools when the **chat API returns native `tool_calls`** (OpenAI format). Text that *looks* like tools — fenced JSON blocks with `"name": "read"` or pseudo-tags like `<read>…</read>` — is **plain text** and does **nothing**. Never emit those patterns; invoke tools through the model’s tool channel only, then answer in normal prose after tool results arrive.

### OpenCode `bash` tool (required arguments)

Every **`bash`** tool call **must** include a non-empty **`description`** string (short summary of what the command does, e.g. *“Show current git branch”*). If `description` is missing, OpenCode rejects the call with *“expected string, received undefined”* and **nothing runs** — do not retry the same broken shape.

Also pass the shell command in the field the schema expects (typically **`command`**). Do **not** send empty JSON or placeholder fenced-JSON blobs instead of real tool arguments.

### How to change files

- **Create or update source and config with `write` / `edit`.** Do **not** build projects by pasting long fenced bash scripts that only use `echo >>` to fabricate files — that burns context and often never executes.
- Use **`bash`** for short commands only (git, package installs, test runners), each with **`description` + `command`**.

### Subagents

Do **not** use the **`task`** tool for this workflow unless you have no other way to proceed. Prefer **direct `read` / `edit` / `write` / `bash` / `grep` / `glob`** so each step is valid and traceable.

If the serving stack cannot produce real `tool_calls` (some **Qwen2.5-Coder** checkpoints on vLLM are known to emit only free-text “tools”), fix the **model or server** — the agent prompt cannot override that. Prefer **Qwen2.5-*-Instruct** (non-Coder) with vLLM **`--enable-auto-tool-choice`** and **`--tool-call-parser hermes`** when you need reliable tool calling.

## Your task

1. Read the PRD at `.ralph/prd.json`.
2. Read the progress log at `.ralph/progress.txt` (**read `## Codebase Patterns` first**, then the **## Story log** region before `<!--RALPH:END_STORY_LOG-->`). Use **`read` with a line range** when the file is large. **Do not** load the **## Iteration log (ralph.sh)** section unless debugging a loop issue — that history is duplicated and may be archived under `.ralph/archive/iteration-log-*.txt`.
3. Confirm you are on the branch from PRD `branchName`. If not, check it out or create it from the default branch (e.g. `main`).
4. Pick the **highest priority** user story where `passes` is `false` (lowest `priority` number = highest priority).
5. Implement **only that** user story.
6. Run the project’s quality checks (typecheck, lint, tests — whatever this repo uses).
7. Update `AGENTS.md` files when you discover reusable patterns (see below).
8. If checks pass, commit all changes with message: `feat: [Story ID] - [Story Title]`
9. Update `.ralph/prd.json` to set `passes: true` for the completed story.
10. **Record the story in `.ralph/progress.txt`** (mandatory when you touched a story — even partial work or failure): add a **## Story log** entry as below. `ralph.sh` appends **## Iteration log** rows after each run; those are automatic and are **not** a substitute for your story block.

## Where to write in `.ralph/progress.txt`

The file has a **## Story log** section and a single marker line **`<!--RALPH:END_STORY_LOG-->`** (do **not** delete or move it).

- **Insert each new story block immediately *above* that marker** (between the Story log instructions and `<!--RALPH:END_STORY_LOG-->`).
- Use **`edit`** (search/replace): replace `<!--RALPH:END_STORY_LOG-->` with your new block **plus** a fresh `<!--RALPH:END_STORY_LOG-->` on the following line so the marker remains last in the story region.
- **Never** append story text under **## Iteration log (ralph.sh)** — that section is only for script output.

## Progress report format

Append in **## Story log** (never replace the whole file):

```
## [Date/Time] - [Story ID]
OpenCode session: optional (`opencode session list`).
- What was implemented (or blocked / not done)
- Files changed
- **Learnings for future iterations:**
  - Patterns discovered
  - Gotchas encountered
  - Useful context for this codebase
---
```

## Consolidate patterns

If you discover **reusable** patterns, add them under **`## Codebase Patterns`** near the **top** of `.ralph/progress.txt` (same file; different section from Story log). Keep items general, not story-specific.

## Update AGENTS.md

Before committing, consider whether edited areas should document conventions in a nearby `AGENTS.md` (same rules as parent directories). Add only durable knowledge: APIs, gotchas, test/setup requirements. Do not duplicate `.ralph/progress.txt` story logs.

## Quality

- Do not commit broken code; keep CI green.
- Keep changes minimal and consistent with existing style.

## Frontend / UI stories

For stories that change UI, verify behavior in a browser or with whatever verification tools OpenCode and this project provide (manual steps in `.ralph/progress.txt` if needed). A UI story is not done until behavior is verified.

## Stop condition

After finishing one story, if **all** user stories in `.ralph/prd.json` have `passes: true`, print **one line only** (no backticks, no surrounding text):

<promise>COMPLETE</promise>

Do **not** embed that string inside shell one-liners, `echo`, JSON, or documentation — `.ralph/ralph.sh` treats only a standalone line as valid, and it also checks `.ralph/prd.json` with `jq`.

If any story still has `passes: false`, end normally (the loop will run another iteration).

## Important

- One story per iteration.
- Read Codebase Patterns in `.ralph/progress.txt` before coding.
