import test from 'node:test'
import assert from 'node:assert/strict'
import { EventEmitter } from 'node:events'
import { validatePluginActivities, duePluginActivity, executePluginActivity } from '../src/sessions/plugin_activities.mjs'

const command = { id: 'status', backend: 'town', command: '/status {player}', expect: '{player} ready', everySeconds: [1, 2] }

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
