import { cpSync, existsSync, mkdirSync, readFileSync, unlinkSync, writeFileSync } from "node:fs"
import { homedir } from "node:os"
import { dirname, extname, isAbsolute, join, relative, resolve } from "node:path"
import { fileURLToPath } from "node:url"
import { tool, type Plugin } from "@opencode-ai/plugin"

type RuntimeContext = {
  directory?: string
  worktree?: string
  client?: {
    session?: {
      messages?: (input: unknown) => Promise<{ data?: unknown[] }>
      prompt?: (input: unknown) => Promise<unknown>
    }
    app?: {
      log?: (input: unknown) => Promise<unknown>
    }
  }
} & Record<string, unknown>

type RalphState = {
  active: boolean
  iteration: number
  maxIterations: number
  sessionId?: string
  prdPath?: string
  progressPath?: string
  originalRequest?: string
}

type StartArgs = {
  spec?: string
  maxIterations?: number
}

const STATE_FILE = ".opencode/ralph-loop.local.md"
const COMPLETE_PROMISE = /^\s*<promise>COMPLETE<\/promise>\s*$/im
const CATEGORY_ORDER = new Map([
  ["setup", 0],
  ["core", 1],
  ["integration", 2],
  ["polish", 3],
])

function pluginRoot() {
  return dirname(dirname(fileURLToPath(import.meta.url)))
}

function projectRoot(ctx: RuntimeContext) {
  return resolve(ctx.worktree ?? ctx.directory ?? process.cwd())
}

function statePath(root: string) {
  return join(root, STATE_FILE)
}

function toProjectPath(root: string, path: string) {
  return relative(root, path) || "."
}

function escapeYamlValue(value: string) {
  return JSON.stringify(value)
}

function unescapeYamlValue(value: string) {
  const trimmed = value.trim()
  if ((trimmed.startsWith('"') && trimmed.endsWith('"')) || (trimmed.startsWith("'") && trimmed.endsWith("'"))) {
    try {
      return JSON.parse(trimmed)
    } catch {
      return trimmed.slice(1, -1)
    }
  }
  return trimmed
}

function parseState(content: string): RalphState {
  const match = content.match(/^---\n([\s\S]*?)\n---/)
  const state: RalphState = { active: false, iteration: 0, maxIterations: 25 }
  if (!match) return state

  for (const line of match[1].split("\n")) {
    const idx = line.indexOf(":")
    if (idx === -1) continue
    const key = line.slice(0, idx).trim()
    const value = unescapeYamlValue(line.slice(idx + 1))
    if (key === "active") state.active = value === "true"
    if (key === "iteration") state.iteration = Number.parseInt(value, 10) || 0
    if (key === "maxIterations") state.maxIterations = Number.parseInt(value, 10) || 25
    if (key === "sessionId" && value) state.sessionId = value
    if (key === "prdPath" && value) state.prdPath = value
    if (key === "progressPath" && value) state.progressPath = value
    if (key === "originalRequest" && value) state.originalRequest = value
  }
  return state
}

function serializeState(state: RalphState) {
  const lines = [
    "---",
    `active: ${state.active}`,
    `iteration: ${state.iteration}`,
    `maxIterations: ${state.maxIterations}`,
  ]
  if (state.sessionId) lines.push(`sessionId: ${escapeYamlValue(state.sessionId)}`)
  if (state.prdPath) lines.push(`prdPath: ${escapeYamlValue(state.prdPath)}`)
  if (state.progressPath) lines.push(`progressPath: ${escapeYamlValue(state.progressPath)}`)
  if (state.originalRequest) lines.push(`originalRequest: ${escapeYamlValue(state.originalRequest)}`)
  lines.push("---", "")
  lines.push("This file is local Open Ralph Loop state. It is safe to delete to cancel the loop.")
  return lines.join("\n")
}

function readState(root: string): RalphState {
  const file = statePath(root)
  if (!existsSync(file)) return { active: false, iteration: 0, maxIterations: 25 }
  return parseState(readFileSync(file, "utf8"))
}

function writeState(root: string, state: RalphState) {
  const file = statePath(root)
  mkdirSync(dirname(file), { recursive: true })
  writeFileSync(file, serializeState(state))
}

function clearState(root: string) {
  const file = statePath(root)
  if (existsSync(file)) unlinkSync(file)
}

function fileExists(path: string) {
  try {
    return existsSync(path)
  } catch {
    return false
  }
}

function slugify(input: string) {
  return input
    .trim()
    .replace(/\.[^.]+$/, "")
    .replace(/([a-z])([A-Z])/g, "$1-$2")
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, "-")
    .replace(/^-+|-+$/g, "")
}

function progressForPrd(prdPath: string) {
  const ext = extname(prdPath)
  const base = ext ? prdPath.slice(0, -ext.length) : prdPath
  return `${base}-progress.txt`
}

function resolvePrd(root: string, spec?: string) {
  const raw = spec?.trim()
  const candidates: string[] = []

  if (raw) {
    const explicit = isAbsolute(raw) ? raw : resolve(root, raw)
    candidates.push(explicit)
    if (!raw.endsWith(".json")) {
      const slug = slugify(raw)
      candidates.push(resolve(root, "docs/specs", `${slug}.json`))
      candidates.push(resolve(root, "lisa", `${slug}.json`))
    }
  }

  candidates.push(resolve(root, "docs/specs/prd.json"))
  candidates.push(resolve(root, "lisa/prd.json"))

  const found = candidates.find(fileExists)
  if (!found) {
    const searched = candidates.map((path) => `- ${toProjectPath(root, path)}`).join("\n")
    throw new Error(`No Lisa PRD JSON found. Searched:\n${searched}`)
  }
  return found
}

function ensureProgressFile(path: string) {
  if (existsSync(path)) return
  mkdirSync(dirname(path), { recursive: true })
  writeFileSync(path, "")
}

function loadPrd(path: string): any {
  return JSON.parse(readFileSync(path, "utf8"))
}

function incompleteStories(prd: any) {
  const stories = Array.isArray(prd?.userStories) ? prd.userStories : []
  return stories.filter((story: any) => story?.passes === false)
}

function allStoriesPass(prdPath: string) {
  try {
    const prd = loadPrd(prdPath)
    const stories = Array.isArray(prd?.userStories) ? prd.userStories : []
    return stories.length > 0 && incompleteStories(prd).length === 0
  } catch {
    return false
  }
}

function nextStoryHint(prdPath: string) {
  try {
    const prd = loadPrd(prdPath)
    const stories = incompleteStories(prd)
    if (stories.length === 0) return "No failing stories remain."
    const ranked: Array<{ story: any; index: number }> = stories
      .map((story: any, index: number) => ({ story, index }))
      .sort((a: { story: any; index: number }, b: { story: any; index: number }) => {
        const ap = typeof a.story.priority === "number" ? a.story.priority : Number.POSITIVE_INFINITY
        const bp = typeof b.story.priority === "number" ? b.story.priority : Number.POSITIVE_INFINITY
        if (ap !== bp) return ap - bp
        const ac = CATEGORY_ORDER.get(String(a.story.category ?? "")) ?? Number.POSITIVE_INFINITY
        const bc = CATEGORY_ORDER.get(String(b.story.category ?? "")) ?? Number.POSITIVE_INFINITY
        if (ac !== bc) return ac - bc
        return a.index - b.index
      })
    const story = ranked[0].story
    return `${story.id ?? "next"} - ${story.title ?? "Untitled story"}`
  } catch {
    return "Unable to read next story."
  }
}

function loopPrompt(state: RalphState, root: string) {
  const prdPath = state.prdPath ?? ""
  const progressPath = state.progressPath ?? ""
  return `# Open Ralph Loop

Active PRD JSON: ${toProjectPath(root, prdPath)}
Progress file: ${toProjectPath(root, progressPath)}
Iteration: ${state.iteration}/${state.maxIterations}
Next story hint: ${nextStoryHint(prdPath)}

Follow one Ralph iteration:
1. Read the PRD JSON and progress file above.
2. Check out or create the PRD branchName.
3. Pick one failing story only. If numeric priority exists, lowest priority wins. Otherwise use Lisa category order: setup, core, integration, polish, then array order.
4. Implement that story, run relevant checks, and commit passing work as "feat: [Story ID] - [Story Title]".
5. Set that story's passes field to true in the PRD JSON.
6. Append concise progress and learnings to the progress file.

When every story in the PRD has passes: true, print a standalone line:
<promise>COMPLETE</promise>

Otherwise stop normally. The plugin will continue the loop when the session goes idle.`
}

function extractAssistantText(messages: any[]) {
  const assistant = messages.filter((msg) => msg?.info?.role === "assistant")
  const last = assistant.at(-1)
  const parts = Array.isArray(last?.parts) ? last.parts : []
  return parts
    .filter((part: any) => part?.type === "text")
    .map((part: any) => part.text ?? "")
    .join("\n")
}

async function assistantPromisedComplete(ctx: RuntimeContext, sessionId: string, root: string) {
  try {
    const response = await ctx.client?.session?.messages?.({ path: { id: sessionId }, query: { directory: root } })
    const messages = Array.isArray(response?.data) ? response.data : []
    return COMPLETE_PROMISE.test(extractAssistantText(messages))
  } catch {
    return false
  }
}

async function setupCommands(ctx: RuntimeContext) {
  const root = pluginRoot()
  const srcDir = join(root, "commands")
  const destDir = join(homedir(), ".config/opencode/commands")
  if (!existsSync(srcDir)) return
  try {
    mkdirSync(destDir, { recursive: true })
    for (const file of ["ralph-loop.md", "cancel-ralph.md", "ralph-status.md"]) {
      const src = join(srcDir, file)
      const dest = join(destDir, file)
      if (existsSync(src) && !existsSync(dest)) cpSync(src, dest)
    }
  } catch (error) {
    await ctx.client?.app?.log?.({
      body: {
        service: "open-ralph-loop",
        level: "warn",
        message: "Unable to install Open Ralph commands",
        extra: { error: String(error) },
      },
    })
  }
}

export const OpenRalphLoopPlugin: Plugin = async (ctx) => {
  const runtime = ctx as unknown as RuntimeContext
  const root = projectRoot(runtime)
  await setupCommands(runtime)

  return {
    tool: {
      ralph_start: tool({
        description: "Start Open Ralph Loop from a Lisa PRD JSON path or feature slug.",
        args: {
          spec: tool.schema
            .string()
            .optional()
            .describe("PRD JSON path or feature slug. Examples: docs/specs/auth.json, lisa/auth.json, auth"),
          maxIterations: tool.schema.number().optional().describe("Maximum auto-continuation iterations. Default: 25"),
        },
        async execute(args: StartArgs, context) {
          const toolRoot = resolve(context.worktree || context.directory || root)
          const prdPath = resolvePrd(toolRoot, args.spec)
          const progressPath = progressForPrd(prdPath)
          ensureProgressFile(progressPath)
          const state: RalphState = {
            active: true,
            iteration: 0,
            maxIterations: args.maxIterations && args.maxIterations > 0 ? Math.floor(args.maxIterations) : 25,
            prdPath,
            progressPath,
            originalRequest: args.spec,
          }
          writeState(toolRoot, state)
          return `${loopPrompt(state, toolRoot)}

Open Ralph Loop started.
- PRD: ${toProjectPath(toolRoot, prdPath)}
- Progress: ${toProjectPath(toolRoot, progressPath)}
- Max iterations: ${state.maxIterations}`
        },
      }),
      ralph_cancel: tool({
        description: "Cancel the active Open Ralph Loop.",
        args: {},
        async execute(_args, context) {
          const toolRoot = resolve(context.worktree || context.directory || root)
          const state = readState(toolRoot)
          if (!state.active) return "No active Open Ralph Loop."
          clearState(toolRoot)
          return `Open Ralph Loop cancelled after ${state.iteration} iteration(s).`
        },
      }),
      ralph_status: tool({
        description: "Show active Open Ralph Loop state.",
        args: {},
        async execute(_args, context) {
          const toolRoot = resolve(context.worktree || context.directory || root)
          const state = readState(toolRoot)
          if (!state.active) return "No active Open Ralph Loop."
          return [
            "Open Ralph Loop is active.",
            `- Iteration: ${state.iteration}/${state.maxIterations}`,
            `- PRD: ${state.prdPath ? toProjectPath(toolRoot, state.prdPath) : "(missing)"}`,
            `- Progress: ${state.progressPath ? toProjectPath(toolRoot, state.progressPath) : "(missing)"}`,
            `- Next story: ${state.prdPath ? nextStoryHint(state.prdPath) : "(unknown)"}`,
          ].join("\n")
        },
      }),
    },
    event: async (input) => {
      const event = input.event as { type: string; properties?: { sessionID?: string } }
      if (event.type === "session.deleted") {
        clearState(root)
        return
      }
      if (event.type !== "session.idle") return

      const sessionId = event.properties?.sessionID
      if (!sessionId) return

      const state = readState(root)
      if (!state.active || !state.prdPath || !state.progressPath) return
      if (state.sessionId && state.sessionId !== sessionId) return

      const promised = await assistantPromisedComplete(runtime, sessionId, root)
      if (promised && allStoriesPass(state.prdPath)) {
        clearState(root)
        return
      }
      if (state.iteration >= state.maxIterations) {
        clearState(root)
        return
      }

      const next: RalphState = { ...state, iteration: state.iteration + 1, sessionId }
      writeState(root, next)

      await ctx.client?.session?.prompt?.({
        path: { id: sessionId },
        body: { parts: [{ type: "text", text: loopPrompt(next, root) }] },
      })
    },
  }
}

export default OpenRalphLoopPlugin

export {
  allStoriesPass,
  incompleteStories,
  nextStoryHint,
  progressForPrd,
  resolvePrd,
  slugify,
}
