import assert from 'node:assert/strict'
import test from 'node:test'
import { EventEmitter } from 'node:events'
import { mkdtemp, mkdir, writeFile, rm } from 'node:fs/promises'
import os from 'node:os'
import path from 'node:path'
import { Vec3 } from 'vec3'
import { createScenarioContext } from '../src/scenario_context.mjs'

function fixture(signal) {
  const bot = Object.assign(new EventEmitter(), { username: 'Actor', entity: { position: new Vec3(1, 80, 1) }, blockAt: () => ({ name: 'air' }), chat() {} })
  const report = { steps: [], server: {} }
  return { bot, report, context: createScenarioContext({ bot, report, signal }) }
}

test('cancellation removes event waiters and rejects sleep and polling', async () => {
  const abort = new AbortController()
  const { bot, context } = fixture(abort.signal)
  const pending = [context.waitForEvent('health'), context.sleep(60000), context.waitUntil(() => false)]
  abort.abort(new Error('stop requested'))
  for (const wait of pending) await assert.rejects(wait, /stop requested/)
  assert.equal(bot.listenerCount('health'), 0)
})

test('an asynchronous assertion predicate cannot outlive its deadline', async () => {
  const { context } = fixture()
  await assert.rejects(context.waitUntil(() => new Promise(() => {}), { timeoutMs: 20, label: 'server reply' }), /server reply timed out/)
})

test('global message patterns reset for every response', async () => {
  const { bot, context } = fixture()
  const pattern = /ready/g
  pattern.lastIndex = 99
  const pending = context.waitForMessage(pattern)
  bot.emit('messagestr', 'ready')
  assert.equal(await pending, 'ready')
})

test('world transition requires a fresh server world identity, not a matching dimension', async (t) => {
  const directory = await mkdtemp(path.join(os.tmpdir(), 'scenario-observer-'))
  t.after(() => rm(directory, { recursive: true, force: true }))
  const file = path.join(directory, 'plugins', 'MultiplexorObserver', 'metrics.json')
  await mkdir(path.dirname(file), { recursive: true })
  const { context, report } = fixture()
  report.server.directory = directory
  const snapshot = { schemaVersion: 1, kind: 'paper', status: 'running', observedAt: new Date().toISOString(), processId: 1,
    worlds: [{ id: 'a', name: 'first', dimension: 'NORMAL' }, { id: 'b', name: 'second', dimension: 'NORMAL' }], players: [{ username: 'Actor', world: 'a' }] }
  await writeFile(file, JSON.stringify(snapshot))
  await assert.rejects(context.transition(async () => {}, { worldName: 'second', timeoutMs: 30 }), /arrival in second/)
  const result = await context.transition(async () => {
    snapshot.observedAt = new Date(Date.now() + 2).toISOString()
    snapshot.players[0].world = 'b'
    await writeFile(file, JSON.stringify(snapshot))
  }, { worldName: 'second' })
  assert.equal(result.world.id, 'b')
  snapshot.observedAt = new Date(Date.now() - 60000).toISOString()
  await writeFile(file, JSON.stringify(snapshot))
  await assert.rejects(context.observe(), /stale/)
})
