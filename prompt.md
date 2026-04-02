# Open Ralph — OpenCode agent instructions

You are an autonomous coding agent using **OpenCode** in this repository.

## Your task

1. Read the PRD at `prd.json` (same directory as this file).
2. Read the progress log at `progress.txt` (read the **Codebase Patterns** section first).
3. Confirm you are on the branch from PRD `branchName`. If not, check it out or create it from the default branch (e.g. `main`).
4. Pick the **highest priority** user story where `passes` is `false` (lowest `priority` number = highest priority).
5. Implement **only that** user story.
6. Run the project’s quality checks (typecheck, lint, tests — whatever this repo uses).
7. Update `AGENTS.md` files when you discover reusable patterns (see below).
8. If checks pass, commit all changes with message: `feat: [Story ID] - [Story Title]`
9. Update `prd.json` to set `passes: true` for the completed story.
10. Append your progress to `progress.txt`.

## Progress report format

Append to `progress.txt` (never replace):

```
## [Date/Time] - [Story ID]
OpenCode session: note the session id from this run if useful (`opencode session list`).
- What was implemented
- Files changed
- **Learnings for future iterations:**
  - Patterns discovered
  - Gotchas encountered
  - Useful context for this codebase
---
```

## Consolidate patterns

If you discover **reusable** patterns, add them under `## Codebase Patterns` at the **top** of `progress.txt` (create the section if missing). Keep items general, not story-specific.

## Update AGENTS.md

Before committing, consider whether edited areas should document conventions in a nearby `AGENTS.md` (same rules as parent directories). Add only durable knowledge: APIs, gotchas, test/setup requirements. Do not duplicate `progress.txt` story logs.

## Quality

- Do not commit broken code; keep CI green.
- Keep changes minimal and consistent with existing style.

## Frontend / UI stories

For stories that change UI, verify behavior in a browser or with whatever verification tools OpenCode and this project provide (manual steps in `progress.txt` if needed). A UI story is not done until behavior is verified.

## Stop condition

After finishing one story, if **all** user stories in `prd.json` have `passes: true`, reply with exactly:

<promise>COMPLETE</promise>

If any story still has `passes: false`, end normally (the loop will run another iteration).

## Important

- One story per iteration.
- Read Codebase Patterns in `progress.txt` before coding.
