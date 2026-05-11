# Ralph Loop Task

OpenCode cwd is the repository root. Ralph files live under `.ralph/`.

Follow this loop for one story only:

1. Read `.ralph/prd.json`.
2. Read `.ralph/progress.txt`, especially `## Codebase Patterns`.
3. Check out or create the PRD `branchName`.
4. Pick the highest-priority user story with `passes: false` (lowest priority number wins).
5. Implement only that story.
6. Run the repo's relevant checks.
7. Commit passing work as `feat: [Story ID] - [Story Title]`.
8. Set that story's `passes` to `true` in `.ralph/prd.json`.
9. Append the result to `.ralph/progress.txt`.

Story log format:

```md
## [Date/Time] - [Story ID]
- What changed or what blocked completion
- Files changed
- Learnings for future iterations
---
```

Update nearby `AGENTS.md` files only for durable conventions discovered while working.

Keep changes minimal and do not commit broken code. For UI stories, verify behavior in a browser or with the repo's available UI checks.

After finishing the story, if every user story in `.ralph/prd.json` has `passes: true`, print exactly:

<promise>COMPLETE</promise>

Otherwise end normally so the loop can continue.
