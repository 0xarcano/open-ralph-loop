# Open Ralph Loop

An autonomous **Ralph-style** agent loop that runs **[OpenCode](https://opencode.ai/)** repeatedly until every item in `prd.json` is complete. Each iteration is a fresh `opencode run` with clean context; memory carries forward through git commits, `progress.txt`, and `prd.json`.

Inspired by [snarktank/ralph](https://github.com/snarktank/ralph), but **OpenCode only** (no Amp, no Claude Code CLI).

## Prerequisites

- [OpenCode](https://dev.opencode.ai/docs/) installed and authenticated (`opencode auth login` as needed)
- [`jq`](https://jqlang.org/) on your `PATH`
- A git repository for your project

## Quick start

Copy these files into your project root (or a subdirectory and adjust paths):

- `ralph.sh`
- `prompt.md`
- `prd.json.example` → copy to `prd.json` and edit

Make the script executable:

```bash
chmod +x ralph.sh
```

Run the loop (default **10** iterations):

```bash
./ralph.sh
```

Or set a max iteration count:

```bash
./ralph.sh 25
```

### Optional environment

| Variable | Purpose |
|----------|---------|
| `RALPH_MODEL` | Passed to `opencode run --model` (e.g. `anthropic/claude-sonnet-4-20250514`) |
| `RALPH_AGENT` | Passed to `opencode run --agent` |
| `RALPH_ATTACH` | Passed to `opencode run --attach` (e.g. `http://localhost:4096` if you use `opencode serve`) |

Example:

```bash
RALPH_MODEL="anthropic/claude-sonnet-4-20250514" ./ralph.sh 15
```

## How it works

1. `ralph.sh` runs `opencode run` with the contents of `prompt.md` each iteration ([OpenCode CLI — `run`](https://dev.opencode.ai/docs/cli/)).
2. The agent follows `prompt.md`: pick the next failing story in `prd.json`, implement it, run checks, commit, update `prd.json` and `progress.txt`.
3. When all stories have `passes: true`, the agent prints `<promise>COMPLETE</promise>` and the script exits successfully.
4. If the max iteration count is reached first, the script exits with status **1**.

## Key files

| File | Role |
|------|------|
| `ralph.sh` | Bash loop invoking OpenCode |
| `prompt.md` | Instructions for each `opencode run` |
| `prd.json` | User stories and `passes` flags |
| `prd.json.example` | Example shape for `prd.json` |
| `progress.txt` | Append-only log (gitignored by default) |
| `archive/` | Previous `prd.json` / `progress.txt` snapshots when `branchName` changes |

## PRD workflow

Upstream Ralph often uses skills to author a PRD and convert it to `prd.json`. You can do that manually or with any workflow you like; this repo only implements the **OpenCode execution loop**. Keep stories **small** (one clear change per story) so each iteration can finish reliably.

## References

- [snarktank/ralph](https://github.com/snarktank/ralph) — original Ralph pattern
- [OpenCode documentation](https://dev.opencode.ai/docs/)
- [Geoffrey Huntley’s Ralph article](https://ghuntley.com/ralph/) (background)

## License

MIT — see [LICENSE](LICENSE).
