import assert from "node:assert/strict"
import { mkdtempSync, mkdirSync, rmSync, writeFileSync } from "node:fs"
import { tmpdir } from "node:os"
import { join } from "node:path"
import test from "node:test"

import {
  allStoriesPass,
  nextStoryHint,
  progressForPrd,
  resolvePrd,
  slugify,
} from "../dist/index.js"

function fixture() {
  const root = mkdtempSync(join(tmpdir(), "open-ralph-loop-test-"))
  return {
    root,
    cleanup: () => rmSync(root, { recursive: true, force: true }),
  }
}

function writeJson(path, value) {
  mkdirSync(join(path, ".."), { recursive: true })
  writeFileSync(path, JSON.stringify(value, null, 2))
}

test("resolves Lisa plugin specs from docs/specs by slug", () => {
  const { root, cleanup } = fixture()
  try {
    const prd = join(root, "docs/specs/auth.json")
    writeJson(prd, { userStories: [] })
    assert.equal(resolvePrd(root, "auth"), prd)
    assert.equal(progressForPrd(prd), join(root, "docs/specs/auth-progress.txt"))
  } finally {
    cleanup()
  }
})

test("resolves Lisa CLI specs from lisa by explicit path", () => {
  const { root, cleanup } = fixture()
  try {
    const prd = join(root, "lisa/auth.json")
    writeJson(prd, { userStories: [] })
    assert.equal(resolvePrd(root, "lisa/auth.json"), prd)
    assert.equal(progressForPrd(prd), join(root, "lisa/auth-progress.txt"))
  } finally {
    cleanup()
  }
})

test("falls back to .ralph/prd.json", () => {
  const { root, cleanup } = fixture()
  try {
    const prd = join(root, ".ralph/prd.json")
    writeJson(prd, { userStories: [] })
    assert.equal(resolvePrd(root), prd)
    assert.equal(progressForPrd(prd), join(root, ".ralph/progress.txt"))
  } finally {
    cleanup()
  }
})

test("completion requires all stories passing", () => {
  const { root, cleanup } = fixture()
  try {
    const prd = join(root, "docs/specs/auth.json")
    writeJson(prd, {
      userStories: [
        { id: "US-001", passes: true },
        { id: "US-002", passes: false },
      ],
    })
    assert.equal(allStoriesPass(prd), false)
    writeJson(prd, {
      userStories: [
        { id: "US-001", passes: true },
        { id: "US-002", passes: true },
      ],
    })
    assert.equal(allStoriesPass(prd), true)
  } finally {
    cleanup()
  }
})

test("story hint uses priority first and Lisa category order otherwise", () => {
  const { root, cleanup } = fixture()
  try {
    const priorityPrd = join(root, "docs/specs/priority.json")
    writeJson(priorityPrd, {
      userStories: [
        { id: "US-002", title: "Second", priority: 2, passes: false },
        { id: "US-001", title: "First", priority: 1, passes: false },
      ],
    })
    assert.equal(nextStoryHint(priorityPrd), "US-001 - First")

    const categoryPrd = join(root, "docs/specs/category.json")
    writeJson(categoryPrd, {
      userStories: [
        { id: "US-004", title: "Polish", category: "polish", passes: false },
        { id: "US-001", title: "Setup", category: "setup", passes: false },
      ],
    })
    assert.equal(nextStoryHint(categoryPrd), "US-001 - Setup")
  } finally {
    cleanup()
  }
})

test("slugifies feature names for Lisa paths", () => {
  assert.equal(slugify("User Authentication"), "user-authentication")
  assert.equal(slugify("user_authentication.json"), "user-authentication")
})
