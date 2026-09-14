import assert from 'node:assert/strict'
import { EventEmitter, getEventListeners } from 'node:events'
import test from 'node:test'
import { Vec3 } from 'vec3'
import { bounded, mineBlock, pause, seededRandom, sendChat, walkTo } from '../src/swarm_actions.mjs'
import { arenaLayout, scatterPositions, SwarmCoordinator } from '../src/swarm_behaviors.mjs'
import { runSwarmPlan, validateSwarmPlan } from '../src/swarm_plans.mjs'

test('seeded activity decisions repeat without giving each worker the same sequence', () => {
  const sequence = (seed) => {
    const random = seededRandom(seed)
    return Array.from({ length: 12 }, random)
  }
  assert.deepEqual(sequence(4), sequence(4))
  assert.notDeepEqual(sequence(4), sequence(5))
  assert(sequence(4).every((value) => value >= 0 && value < 1))
})

test('scatter assigns unique evenly spaced cells across requested area', () => {
  for (const count of [1, 2, 4, 5, 64]) {
    const positions = scatterPositions(count, { x: 100, y: 80, z: -100 }, 64)
    assert.equal(new Set(positions.map(String)).size, count)
    assert(positions.every((position) => Math.abs(position.x - 100) <= 64 && Math.abs(position.z + 100) <= 64))
  }
  assert.deepEqual(scatterPositions(4, { x: 0, y: 80, z: 0 }, 32).map(({ x, z }) => [x, z]), [[-16, -16], [16, -16], [-16, 16], [16, 16]])
})

test('each arena worker has distinct fixtures inside its twelve-block tile', () => {
  const tiles = arenaLayout({ x: 0, y: 80, z: 0 }, 64)
  assert.equal(new Set(tiles.map((tile) => String(tile.base))).size, 64)
  for (const tile of tiles) {
    for (const target of [tile.lever, tile.button, tile.plate, tile.building, ...tile.walking]) {
      assert(target.x > tile.base.x && target.x < tile.base.x + 11)
      assert(target.z > tile.base.z && target.z < tile.base.z + 11)
    }
  }
})

test('coordinator excludes overlapping jobs and releases failed reservations', async () => {
  const coordinator = new SwarmCoordinator()
  const position = { x: 1, y: 2, z: 3 }
  let release
  const pending = coordinator.claim(position, () => new Promise((resolve) => { release = resolve }))
  assert.deepEqual(await coordinator.claim(position, () => assert.fail('overlap ran')), { skipped: true })
  release('done')
  assert.equal(await pending, 'done')
  await assert.rejects(coordinator.claim(position, () => { throw new Error('failed') }), /failed/)
  assert.equal(await coordinator.claim(position, () => 'reused'), 'reused')
})

test('bounded actions abort pending work and remove parent listeners', async () => {
  const parent = new AbortController()
  let stopped = false
  await assert.rejects(bounded('slow', 20, parent.signal, async (signal) => {
    try { await pause(10000, signal) } finally { stopped = true }
  }), /timed out/)
  assert(stopped)
  assert.equal(getEventListeners(parent.signal, 'abort').length, 0)
})

test('chat requires server echo and cancellation removes listeners', async () => {
  const observer = new EventEmitter()
  const controller = new AbortController()
  const bot = { username: 'Worker01', chat: () => {} }
  const pending = sendChat(bot, observer, 'Ready to build', controller.signal)
  observer.emit('messagestr', '<Other> Ready to build')
  assert.equal(observer.listenerCount('messagestr'), 1)
  observer.emit('messagestr', '<Worker01> Ready to build')
  await pending
  assert.equal(observer.listenerCount('messagestr'), 0)
  const cancelled = sendChat(bot, observer, 'Next job', controller.signal)
  controller.abort(new Error('cancelled'))
  await assert.rejects(cancelled, /cancelled/)
  assert.equal(observer.listenerCount('messagestr'), 0)
})

test('plans reject commands in chat, unknown functions, conflicting blocks and absent actors', () => {
  const plan = (phase) => ({ name: 'demo', phases: [phase] })
  for (const phase of [
    { action: 'chat', messages: ['/op intruder'] },
    { action: 'exec', command: 'anything' },
    { action: 'mine', positions: [[1, 80, 1], [1, 80, 1]] },
    { action: 'walk', positions: [[1, 80, 1]], actors: [5] },
    { action: 'teleport', positions: [[30000001, 80, 1]] },
    { action: 'build', positions: [[1, 80, 1]], block: 'stone; op intruder' }
  ]) assert.throws(() => validateSwarmPlan(plan(phase), { bots: 4 }))
  assert.equal(validateSwarmPlan(plan({ action: 'chat', messages: ['{bot} is ready'] })).phases.length, 1)
})

test('mining cannot pass on the digger optimistic block prediction', async () => {
  const bot = new EventEmitter()
  const position = new Vec3(1, 81, 1)
  let localAir = false
  const stone = { name: 'stone', boundingBox: 'block', position }
  Object.assign(bot, {
    entity: { position: position.offset(0, 0, 1) },
    pathfinder: { goto: async () => {}, setGoal: () => {}, bestHarvestTool: () => null },
    clearControlStates: () => {}, stopDigging: () => {}, canDigBlock: () => true,
    blockAt: () => localAir ? { name: 'air' } : stone,
    dig: async () => { localAir = true }
  })
  const observer = { blockAt: () => stone }
  await assert.rejects(bounded('server acknowledgement', 50, undefined, (signal) =>
    mineBlock({ bot, observer, position, signal, timeoutMs: 50 })), /timed out/)
  assert(localAir)
})

test('late cancellation of an old walking route cannot stop its replacement', async () => {
  const pending = []
  const bot = {
    entity: { position: new Vec3(0, 80, 0) },
    clearControlStates: () => {},
    pathfinder: {
      goal: null,
      setGoal(goal) { this.goal = goal },
      goto(goal) {
        this.goal = goal
        return new Promise((resolve, reject) => pending.push({ goal, resolve, reject }))
      }
    }
  }
  const firstSignal = new AbortController()
  const first = walkTo(bot, new Vec3(1, 80, 1), firstSignal.signal)
  first.catch(() => {})
  firstSignal.abort(new Error('cancel first'))
  const second = walkTo(bot, new Vec3(2, 80, 2), new AbortController().signal)
  second.catch(() => {})
  pending[0].reject(new Error('old goal changed'))
  await assert.rejects(first, /old goal changed/)
  assert.equal(bot.pathfinder.goal, pending[1].goal)
  pending[1].reject(new Error('finish second'))
  await assert.rejects(second, /finish second/)
})

test('all assigned workers finish a phase before the next coordinated phase starts', async () => {
  const controller = new EventEmitter()
  controller.chat = () => queueMicrotask(() => controller.emit('messagestr', 'Set own game mode to Spectator Mode'))
  const events = []
  const bots = ['One', 'Two'].map((username) => ({ username, chat: (text) => {
    events.push(`${username}:${text}`)
    queueMicrotask(() => controller.emit('messagestr', `<${username}> ${text}`))
  } }))
  await runSwarmPlan({
    bots, controller,
    plan: { name: 'barrier', phases: [{ action: 'chat', messages: ['phase one'] }, { action: 'chat', messages: ['phase two'] }] },
    origin: { x: 0, y: 80, z: 0 }, deadline: performance.now() + 3000,
    signal: new AbortController().signal, record: () => {}, actionTimeoutMs: 1000
  })
  assert.deepEqual(events, ['One:phase one', 'Two:phase one', 'One:phase two', 'Two:phase two'])
})
