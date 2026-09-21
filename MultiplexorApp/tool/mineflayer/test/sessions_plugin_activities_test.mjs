import test from 'node:test'
import assert from 'node:assert/strict'
import { EventEmitter } from 'node:events'
import { mkdtemp, writeFile, rename, rm } from 'node:fs/promises'
import os from 'node:os'
import path from 'node:path'
import { Vec3 } from 'vec3'
import { validatePluginActivities, duePluginActivity, executePluginActivity } from '../src/sessions/plugin_activities.mjs'

const command = { id: 'status', backend: 'town', command: '/status {player}', expect: '{player} ready', everySeconds: [1, 2] }

test('workflow validation rejects ambiguous actions and unverified world changes', () => {
  const base = { id: 'roundtrip', backend: 'town', steps: [{ command: '/status', expect: 'ready' }] }
  assert.equal(validatePluginActivities([base])[0].steps.length, 1)
  assert.throws(() => validatePluginActivities([{ ...base, command: '/status' }]), /not both/)
  assert.throws(() => validatePluginActivities([{ ...base, steps: [{ command: '/status', expect: 'ready', route: [{ x: 0, y: 80, z: 0 }] }] }]), /exactly one/)
  assert.throws(() => validatePluginActivities([{ ...base, steps: [{ command: '/status', expect: 'ready', transition: {} }] }]), /destination/)
  assert.throws(() => validatePluginActivities([{ ...base, steps: [{ circle: { center: { x: 0, y: 80, z: 0 }, radius: 0 } }] }]), /radius/)
})

test('workflow menus await each new window before sending subsequent clicks', async () => {
  const bot = new EventEmitter()
  bot.username = 'Returning01'
  const first = { title: 'Portal list', inventoryStart: 9, slots: [{ name: 'ender_eye' }] }
  const second = { title: 'Confirm link', inventoryStart: 9, slots: [{ name: 'emerald' }] }
  const seen = []
  bot.chat = (message) => {
    seen.push(message)
    if (message === '/portals') { bot.currentWindow = first; bot.emit('windowOpen', first) }
    else bot.emit('messagestr', 'Link remains active')
  }
  bot.clickWindow = async () => {
    if (bot.currentWindow === first) { bot.currentWindow = second; bot.emit('windowOpen', second) }
    else bot.emit('messagestr', 'Linked successfully')
  }
  bot.closeWindow = () => { bot.currentWindow = null }
  const activity = validatePluginActivities([{ id: 'link', backend: 'town', steps: [
    { command: '/portals', menu: { title: 'Portal list', clicks: [{ slot: 0, item: 'ender_eye', nextTitle: 'Confirm link' }, { slot: 0, item: 'emerald' }], expect: 'Linked successfully' } },
    { command: '/portal status', expect: 'Link remains active' }
  ] }])[0]
  const result = await executePluginActivity(bot, activity, { signal: new AbortController().signal, assertCurrent() {} })
  assert.deepEqual(seen, ['/portals', '/portal status'])
  assert.equal(result.metrics.pluginSteps, 2)
  assert.equal(bot.listenerCount('windowOpen'), 0)
  assert.equal(bot.currentWindow, null)
})

test('cancelling a workflow prevents all later commands', async () => {
  const bot = new EventEmitter()
  bot.username = 'Returning01'
  const abort = new AbortController()
  const sent = []
  bot.chat = (message) => { sent.push(message); abort.abort(new Error('Interrupted workflow')) }
  const activity = validatePluginActivities([{ id: 'cancel', backend: 'town', steps: [
    { command: '/first', expect: 'first done' }, { command: '/second', expect: 'second done' }
  ] }])[0]
  await assert.rejects(executePluginActivity(bot, activity, { signal: abort.signal, assertCurrent() {} }), /Interrupted workflow/)
  assert.deepEqual(sent, ['/first'])
  assert.equal(bot.listenerCount('messagestr'), 0)
})

test('modern NBT menu titles retain nested text and guarded clicks', async () => {
  const bot = new EventEmitter()
  bot.username = 'Returning01'
  const title = { type: 'compound', value: {
    text: { type: 'string', value: 'Supply ' },
    extra: { type: 'list', value: { type: 'compound', value: [{ text: { type: 'string', value: 'shop' } }] } }
  } }
  const window = { title, inventoryStart: 9, slots: [{ name: 'emerald' }] }
  let clicks = 0
  bot.chat = () => { bot.currentWindow = window; bot.emit('windowOpen', window) }
  bot.clickWindow = async () => { clicks++; bot.emit('messagestr', 'Purchased') }
  bot.closeWindow = () => { bot.currentWindow = null }
  const activity = validatePluginActivities([{ ...command, menu: { title: 'Supply shop', clicks: [{ slot: 0, item: 'emerald' }], expect: 'Purchased' } }])[0]
  await executePluginActivity(bot, activity, { signal: new AbortController().signal, assertCurrent() {} })
  assert.equal(clicks, 1)
  assert.equal(bot.currentWindow, null)
})

test('observed portal arrival cancels movement still chasing its entry waypoint', async () => {
  const directory = await mkdtemp(path.join(os.tmpdir(), 'plugin-arrival-'))
  const observerPath = path.join(directory, 'metrics.json')
  const bot = new EventEmitter()
  bot.username = 'Returning01'
  bot.entity = { position: new Vec3(0, 80, 0) }
  bot.blockAt = () => ({ name: 'air' })
  let cleared = 0
  bot.clearControlStates = () => { cleared++ }
  const snapshot = (observedAt) => ({ schemaVersion: 1, kind: 'paper', status: 'running', processId: 1, observedAt,
    worlds: [{ id: 'home', name: 'world' }], players: [{ username: bot.username, world: 'home' }] })
  await writeFile(observerPath, JSON.stringify(snapshot(new Date().toISOString())))
  let stop
  bot.pathfinder = {
    goal: null,
    async goto(goal) {
      this.goal = goal
      bot.entity.position = new Vec3(100, 80, 100)
      const pending = new Promise((_, reject) => { stop = reject })
      pending.catch(() => {})
      await writeFile(`${observerPath}.next`, JSON.stringify(snapshot(new Date(Date.now() + 100).toISOString())))
      await rename(`${observerPath}.next`, observerPath)
      return pending
    },
    setGoal(goal) { this.goal = goal; if (goal === null) stop?.(new Error('Movement stopped')) }
  }
  const activity = validatePluginActivities([{ id: 'portal', backend: 'town', timeoutSeconds: 2, steps: [{
    route: [{ x: 10, y: 80, z: 0 }], transition: { worldName: 'world', position: { x: 100, y: 80, z: 100 }, radius: 1 }
  }] }])[0]
  try {
    const result = await executePluginActivity(bot, activity, { observerPath, signal: new AbortController().signal, assertCurrent() {}, worldTransition: (operation) => operation() })
    assert.equal(result.status, 'completed')
    assert.equal(bot.pathfinder.goal, null)
    assert.ok(cleared > 0)
  } finally { await rm(directory, { recursive: true, force: true }) }
})

test('cancellation closes a replacement menu while its opening click is still pending', async () => {
  const bot = new EventEmitter()
  bot.username = 'Returning01'
  const abort = new AbortController()
  const first = { title: 'First', inventoryStart: 9, slots: [{ name: 'emerald' }] }
  const second = { title: 'Second', inventoryStart: 9, slots: [] }
  bot.chat = () => { bot.currentWindow = first; bot.emit('windowOpen', first) }
  let resolveClick
  bot.clickWindow = () => {
    bot.currentWindow = second
    bot.emit('windowOpen', second)
    queueMicrotask(() => abort.abort(new Error('Logout during click')))
    return new Promise((resolve) => { resolveClick = resolve })
  }
  bot.closeWindow = () => { bot.currentWindow = null }
  const activity = validatePluginActivities([{ ...command, menu: { title: 'First', clicks: [{ slot: 0, item: 'emerald', nextTitle: 'Second' }], expect: 'Opened second' } }])[0]
  await assert.rejects(executePluginActivity(bot, activity, { signal: abort.signal, assertCurrent() {} }), /Logout during click/)
  assert.equal(bot.currentWindow, null)
  resolveClick()
  await new Promise((resolve) => setImmediate(resolve))
  assert.equal(bot.currentWindow, null)
  assert.equal(bot.listenerCount('windowOpen'), 0)
})

test('plugin activities require verified replies and guarded menu clicks', () => {
  assert.throws(() => validatePluginActivities([{ ...command, expect: undefined }]), /expected response/)
  assert.throws(() => validatePluginActivities([{ ...command, menu: { title: 'shop', clicks: [{ slot: 0, item: 'emerald' }] }, expect: undefined }]), /expected response/)
  assert.throws(() => validatePluginActivities([command], { aliases: ['lobby'] }), /Unknown/)
  assert.throws(() => validatePluginActivities([command, command]), /unique/)
})

test('plugin schedules persist and do not run on the wrong backend', () => {
  const activities = validatePluginActivities([command])
  const player = { intent: {}, role: 'builder' }
  assert.equal(duePluginActivity(activities, player, 'lobby', 0, () => 0), undefined)
  assert.equal(duePluginActivity(activities, player, 'town', 0, () => 0), undefined)
  assert.equal(duePluginActivity(activities, player, 'town', 1000, () => 0).id, 'status')
  assert.equal(duePluginActivity(activities, player, 'town', 1000, () => 0), undefined)
  assert.equal(player.intent.plugins.status.nextDueAtMs, 2000)
})

test('command listener is ready before sending and cleans up on completion', async () => {
  const bot = new EventEmitter()
  bot.username = 'Returning01'
  bot.chat = (text) => { assert.equal(text, '/status Returning01'); bot.emit('messagestr', 'Returning01 ready') }
  const result = await executePluginActivity(bot, validatePluginActivities([command])[0], { signal: new AbortController().signal, assertCurrent() {} })
  assert.equal(result.metrics.pluginActions, 1)
  assert.equal(bot.listenerCount('messagestr'), 0)
})

test('a changed menu item prevents the click and closes the owned window', async () => {
  const bot = new EventEmitter()
  bot.username = 'Returning01'
  let clicks = 0
  const window = { title: '{"text":"Supply shop"}', inventoryStart: 9, slots: [{ name: 'tnt' }] }
  bot.chat = () => { bot.currentWindow = window; bot.emit('windowOpen', window) }
  bot.clickWindow = async () => { clicks++ }
  bot.closeWindow = () => { bot.currentWindow = null }
  const activity = validatePluginActivities([{ ...command, menu: { title: 'Supply shop', clicks: [{ slot: 0, item: 'emerald' }], expect: 'Purchased' } }])[0]
  await assert.rejects(executePluginActivity(bot, activity, { signal: new AbortController().signal, assertCurrent() {} }), /does not contain emerald/)
  assert.equal(clicks, 0)
  assert.equal(bot.currentWindow, null)
  assert.equal(bot.listenerCount('messagestr'), 0)
  assert.equal(bot.listenerCount('windowOpen'), 0)
})

test('cancellation ends a missing response without leaking listeners', async () => {
  const bot = new EventEmitter()
  bot.username = 'Returning01'
  const abort = new AbortController()
  bot.chat = () => queueMicrotask(() => abort.abort(new Error('Scheduled logout')))
  await assert.rejects(executePluginActivity(bot, validatePluginActivities([command])[0], { signal: abort.signal, assertCurrent() {} }), /Scheduled logout/)
  assert.equal(bot.listenerCount('messagestr'), 0)
})
