import assert from 'node:assert/strict'
import test from 'node:test'
import { EventEmitter } from 'node:events'
import { mkdtemp, writeFile, rm } from 'node:fs/promises'
import os from 'node:os'
import path from 'node:path'
import { assertOrdinaryActor, createActorManager, offlineUuid } from '../src/scenario_actors.mjs'

test('additional actors cannot reuse an operator identity with a missing or differently cased name', async (t) => {
  const directory = await mkdtemp(path.join(os.tmpdir(), 'scenario-actor-'))
  t.after(() => rm(directory, { recursive: true, force: true }))
  await writeFile(path.join(directory, 'ops.json'), JSON.stringify([{ uuid: offlineUuid('DuelBot') }]))
  await assert.rejects(assertOrdinaryActor(directory, 'DuelBot'), /operator/)
  await assertOrdinaryActor(directory, 'OtherBot')
  await writeFile(path.join(directory, 'ops.json'), JSON.stringify([{ name: 'DUELBOT' }]))
  await assert.rejects(assertOrdinaryActor(directory, 'DuelBot'), /operator/)
})

test('a secondary client failure aborts the run and every client disconnects', async (t) => {
  const directory = await mkdtemp(path.join(os.tmpdir(), 'scenario-actor-'))
  t.after(() => rm(directory, { recursive: true, force: true }))
  await writeFile(path.join(directory, 'ops.json'), '[]')
  const abort = new AbortController()
  const bots = []
  const manager = createActorManager({ configuration: { host: '127.0.0.1', auth: 'offline', instanceDirectory: directory, connectTimeoutMs: 1000 }, report: { messages: [] }, signal: abort.signal, fail: (error) => abort.abort(error), runtime: {
    createBot({ username }) {
      const bot = Object.assign(new EventEmitter(), { username, quit() { this.emit('end', 'quit') } })
      bots.push(bot)
      setImmediate(() => bot.emit('spawn'))
      return bot
    }, install() {}, configure() {}
  } })
  await manager.connect('Admin', { primary: true })
  const second = await manager.connect('Player')
  second.emit('kicked', 'test kick')
  assert.match(abort.signal.reason.message, /test kick/)
  await manager.close()
  for (const bot of bots) assert.equal(bot.eventNames().length, 0)
})

function reconnectFixture() {
  const abort = new AbortController()
  const report = { messages: [] }
  const manager = createActorManager({ configuration: { host: '127.0.0.1', auth: 'offline', connectTimeoutMs: 1000 }, report,
    signal: abort.signal, fail: (error) => abort.abort(error), runtime: {
      createBot({ username }) {
        const bot = Object.assign(new EventEmitter(), { username, quit() { this.emit('end', 'quit') } })
        setImmediate(() => bot.emit('spawn'))
        return bot
      }, install() {}, configure() {}
    }
  })
  return { manager, report, abort }
}

test('planned reconnect retains the previous connection and restores unexpected disconnect failures', async () => {
  const { manager, report, abort } = reconnectFixture()
  const first = await manager.connect('Admin', { primary: true })
  let reloadFinished = false
  const replacement = await manager.reconnectAfter(first, async () => {
    first.emit('end', 'socketClosed')
    await new Promise(resolve => setImmediate(resolve))
    reloadFinished = true
  })
  assert.ok(reloadFinished)
  assert.notEqual(replacement, first)
  assert.equal(replacement.username, first.username)
  assert.equal(report.actors.length, 2)
  assert.equal(report.actors[0].planned, true)
  assert.equal(report.actors[0].disconnectReason, 'socketClosed')
  assert.equal(first.eventNames().length, 0)
  assert.equal(abort.signal.aborted, false)
  replacement.emit('end', 'unexpected')
  assert.match(abort.signal.reason.message, /unexpected/)
  await manager.close()
})

test('planned reconnect cannot hide kicks or a missing disconnect', async () => {
  const { manager, abort } = reconnectFixture()
  const first = await manager.connect('Admin', { primary: true })
  await assert.rejects(manager.reconnectAfter(first, () => {}, { timeoutMs: 20 }), /planned disconnect timed out/)
  assert.equal(first.listenerCount('end'), 1)
  await assert.rejects(manager.reconnectAfter(first, () => first.emit('kicked', 'permission denied')), /permission denied/)
  assert.equal(abort.signal.aborted, true)
  await manager.close()
})
