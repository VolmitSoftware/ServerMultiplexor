import assert from 'node:assert/strict'
import EventEmitter from 'node:events'
import { mkdtemp, readFile, rm } from 'node:fs/promises'
import os from 'node:os'
import path from 'node:path'
import test from 'node:test'

import { startWebFeed, stopWebFeed } from '../src/web_feed.mjs'

test('serves and records a loopback web feed', async () => {
  const artifactsDirectory = await mkdtemp(path.join(os.tmpdir(), 'mineflayer-viewer-'))
  const notices = []
  const bot = new EventEmitter()

  try {
    const state = await startWebFeed({
      artifactsDirectory,
      bot,
      instance: 'qa',
      notice: (line) => notices.push(line),
      scenario: 'connect'
    })

    assert.match(state.url, /^http:\/\/127\.0\.0\.1:\d+\/$/)
    assert.equal(state.bindAddress, '127.0.0.1')
    assert.equal((await fetch(state.url)).status, 200)
    assert.deepEqual(notices, [`[INFO] Web feed: ${state.url}`])
    const activeState = JSON.parse(await readFile(state.stateFile, 'utf8'))
    assert.equal(activeState.status, 'active')
    assert.equal(activeState.url, state.url)

    await stopWebFeed(bot, state, { instance: 'qa', scenario: 'connect' })
    const closedState = JSON.parse(await readFile(state.stateFile, 'utf8'))
    assert.equal(closedState.status, 'closed')
    assert.equal(typeof closedState.closedAt, 'string')
  } finally {
    await bot.viewer?.close?.()
    await rm(artifactsDirectory, { recursive: true, force: true })
  }
})
