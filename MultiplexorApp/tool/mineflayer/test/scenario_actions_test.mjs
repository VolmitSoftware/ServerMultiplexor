import assert from 'node:assert/strict'
import test from 'node:test'
import { EventEmitter } from 'node:events'
import { circleRoute, createCircleTracker, createScenarioActions } from '../src/scenario_actions.mjs'

test('circle evidence counts observed full laps across the angle wrap in both directions', () => {
  for (const clockwise of [true, false]) {
    const configuration = { center: { x: 20, y: 80, z: -15 }, radius: 8, laps: 3, clockwise }
    const tracker = createCircleTracker(configuration)
    for (const point of circleRoute(configuration)) tracker.sample(point)
    assert.ok(Math.abs(tracker.result().laps - 3) < 0.001)
    assert.ok(tracker.result().distance > 145)
  }
})

test('circle evidence refuses shortcuts and teleportation even if the last position reaches the route', () => {
  const configuration = { center: { x: 0, y: 80, z: 0 }, radius: 8 }
  const tracker = createCircleTracker(configuration)
  tracker.sample({ x: 8, y: 80, z: 0 })
  assert.throws(() => tracker.sample({ x: 0, y: 80, z: 0 }), /radius/)
  assert.throws(() => tracker.sample({ x: -8, y: 80, z: 0 }), /jumped/)
})

test('route timeout aborts the movement and clears control states', async () => {
  const bot = Object.assign(new EventEmitter(), { pathfinder: { setGoal() {} }, clearControlStates() { this.cleared = true } })
  let movementSignal
  const actions = createScenarioActions({ bot, signal: new AbortController().signal, move: async (_, __, signal) => { movementSignal = signal; await new Promise(() => {}) } })
  await assert.rejects(actions.walkRoute([{ x: 0, y: 80, z: 0 }], { timeoutMs: 20 }), /timed out/)
  assert.equal(movementSignal.aborted, true)
  assert.equal(bot.cleared, true)
})

test('circle failures always detach the position sampler', async () => {
  const bot = Object.assign(new EventEmitter(), { entity: { position: { x: 8, y: 80, z: 0 } }, pathfinder: { setGoal() {} }, clearControlStates() {} })
  let calls = 0
  const actions = createScenarioActions({ bot, signal: new AbortController().signal, move: async () => { if (++calls > 1) throw new Error('blocked') } })
  await assert.rejects(actions.walkCircle({ center: { x: 0, y: 80, z: 0 } }), /blocked/)
  assert.equal(bot.listenerCount('physicsTick'), 0)
})

async function combatFixture(attack) {
  const { createScenarioContext } = await import('../src/scenario_context.mjs')
  const { Vec3 } = await import('vec3')
  const target = Object.assign(new EventEmitter(), { username: 'Target', health: 20 })
  const victim = { id: 2, position: new Vec3(2, 80, 0) }
  const bot = Object.assign(new EventEmitter(), {
    username: 'Attacker', entity: { id: 1, position: new Vec3(0, 80, 0) },
    players: { Target: { entity: victim } }, pathfinder: { setGoal() {} },
    clearControlStates() {}, async lookAt() {},
    attack() { attack({ bot, target, victim }) }
  })
  const context = createScenarioContext({ bot, report: { server: {}, steps: [] } })
  return { bot, target, actions: context.actions }
}

test('combat requires attributed damage and target health loss', async () => {
  const { bot, target, actions } = await combatFixture(({ bot, target, victim }) => {
    bot.emit('entityHurt', victim, bot.entity)
    target.health = 18
  })
  const result = await actions.attackPlayer(target)
  assert.equal(result.confirmedHits, 1)
  assert.deepEqual(result.damage, [{ before: 20, after: 18, amount: 2, victimId: 2, attackerId: 1 }])
  assert.equal(bot.listenerCount('entityHurt'), 0)
  assert.equal(target.listenerCount('health'), 0)
})

test('combat retains health loss that heals before its next poll', async () => {
  const { bot, target, actions } = await combatFixture(({ bot, target, victim }) => {
    bot.emit('entityHurt', victim, bot.entity)
    target.health = 19
    target.emit('health')
    target.health = 20
    target.emit('health')
  })
  const result = await actions.attackPlayer(target)
  assert.equal(result.confirmedHits, 1)
  assert.equal(result.damage[0].after, 19)
  assert.equal(result.health, 20)
  assert.equal(bot.listenerCount('entityHurt'), 0)
  assert.equal(target.listenerCount('health'), 0)
})

test('combat rejects unrelated health loss, attackers, victims, and damage without health loss', async () => {
  const attacks = [
    ({ target }) => { target.health = 18 },
    ({ bot, target, victim }) => { target.health = 18; bot.emit('entityHurt', victim, { id: 3 }) },
    ({ bot, target }) => { target.health = 18; bot.emit('entityHurt', { id: 3 }, bot.entity) },
    ({ bot, victim }) => { bot.emit('entityHurt', victim, bot.entity) }
  ]
  for (const attack of attacks) {
    const { bot, target, actions } = await combatFixture(attack)
    await assert.rejects(actions.attackPlayer(target, { timeoutMs: 50 }), /timed out/)
    assert.equal(bot.listenerCount('entityHurt'), 0)
    assert.equal(target.listenerCount('health'), 0)
  }
})
