# Ralph loop task (per `opencode run`)

Follow the **Ralph agent** profile for tool rules and context discipline (`.opencode/agents/ralph.md`). This file is **only** the loop workflow and project paths.

## Ralph scope (no detours)

- **Do not** invoke **`find-skills`**, `npx skills`, or hunt for external skills. This run is **only** the numbered task list below (PRD → one story → checks → commit → progress).
- OpenCode **cwd is the repository root**. Ralph files use a **leading dot**: **`.ralph/prd.json`** and **`.ralph/progress.txt`** — **not** `./ralph/...` (that path is wrong and will not exist).

## vLLM / Ralph loop tuning

**`./ralph.sh` preflight** sets a **small completion budget** (roughly **min(`max_model_len`/4, 8192)** by default) so long prompts and tool traces do not hit *“requested N output tokens and your prompt contains at least M input tokens”*. **Write code with `edit`/`write`**; do not paste huge blobs into chat.

If you see **maximum context length** / **output tokens** errors, shorten reads and replies; the operator can raise vLLM `--max-model-len`, set **`RALPH_COMPLETION_HARD_CAP`** / **`RALPH_MAX_OUTPUT_TOKENS`** in `.ralph/.env`, or set **`RALPH_MIN_CTX`** to match the server’s `max_model_len`.

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
