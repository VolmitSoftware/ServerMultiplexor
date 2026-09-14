import assert from 'node:assert/strict'
import { EventEmitter, getEventListeners } from 'node:events'
import test from 'node:test'
import { Vec3 } from 'vec3'
import { bounded, seededRandom } from '../src/swarm_actions.mjs'
import { packetChangesPosition, serverBlockEdit } from '../src/swarm_block_ack.mjs'
import { arenaLayout } from '../src/swarm_behaviors.mjs'
import { createStressExecutor, stressTileLayout, walkingDestination } from '../src/swarm_stress_actions.mjs'
import { constrainWorker, containsWorker, assertTargetBounds } from '../src/swarm_world_bounds.mjs'
import windows from 'prismarine-windows'
import { transferStorage } from '../src/swarm_stress_inventory.mjs'
import { controllerCommand } from '../src/swarm_actions.mjs'
import { StressCoordinator } from '../src/swarm_stress.mjs'
import { validateWorkload } from '../src/swarm_workload.mjs'

test('bounds include body width and head room and constrain pathfinder steps', () => {
  const bounds = { min: [0, 80, 0], max: [23, 85, 23] }
  assert(containsWorker(bounds, new Vec3(0.5, 81, 0.5)))
  assert(!containsWorker(bounds, new Vec3(0.1, 81, 0.5)))
  assert(!containsWorker(bounds, new Vec3(23.8, 81, 0.5)))
  assert(!containsWorker(bounds, new Vec3(10, 85, 10)))
  assert(!containsWorker(bounds, new Vec3(NaN, 81, 10)))
  const movements = { exclusionAreasStep: [], exclusionAreasBreak: [], exclusionAreasPlace: [] }
  const bot = { username: 'Bounded', entity: { position: new Vec3(1.5, 81, 1.5) }, pathfinder: { movements, setMovements() {} } }
  constrainWorker(bot, bounds)
  assert.equal(movements.exclusionAreasStep[0]({ position: new Vec3(-1, 81, 1) }), 100)
  assert.equal(movements.exclusionAreasStep[0]({ position: new Vec3(1, 81, 1) }), 0)
  assert.equal(movements.exclusionAreasPlace[0]({ position: new Vec3(24, 81, 1) }), 100)
  assert.throws(() => assertTargetBounds(bot, new Vec3(-1, 81, 0)), /outside/)
})

test('walking destinations remain inside bounds and reject hazardous floors', () => {
  const bounds = { min: [0, 80, 0], max: [23, 85, 23] }
  let floorName = 'stone'
  const bot = { entity: { position: new Vec3(1.5, 81, 1.5) }, blockAt: (position) =>
    position.y === 80 ? { name: floorName, boundingBox: 'block' } : { name: 'air', boundingBox: 'empty' } }
  const random = seededRandom(8)
  for (let index = 0; index < 100; index++) {
    const destination = walkingDestination(bot, bounds, random, { distance: 32 })
    if (destination) assert(containsWorker(bounds, destination.offset(0.5, 0, 0.5)))
  }
  floorName = 'farmland'
  assert.equal(walkingDestination(bot, bounds, random), undefined)
})

test('stress fixtures stay inside each tile and share mining/building jobs', () => {
  for (const tile of arenaLayout({ x: 0, y: 80, z: 0 }, 256)) {
    const fixture = stressTileLayout(tile)
    assert.deepEqual(fixture.mine, fixture.build)
    for (const positions of Object.values(fixture)) for (const position of positions) {
      assert(position.x >= tile.base.x && position.x <= tile.base.x + 11)
      assert(position.z >= tile.base.z && position.z <= tile.base.z + 11)
    }
    assert(!fixture.mine.some((target) => fixture.farm.some((crop) => crop.equals(target))))
  }
})

test('server block acknowledgement ignores optimistic state and unrelated packets', async () => {
  const client = new EventEmitter()
  const target = new Vec3(1, 81, 1)
  const bot = { _client: client, blockAt: () => ({ name: 'air' }) }
  let completed = false
  const run = bounded('packet acknowledgement', 500, undefined, (signal) => serverBlockEdit(bot, target,
    (block) => block.name === 'air', async () => {}, signal)).then(() => { completed = true })
  await new Promise((resolve) => setImmediate(resolve))
  assert.equal(completed, false)
  client.emit('block_change', { location: { x: 2, y: 81, z: 1 }, type: 0 })
  await new Promise((resolve) => setImmediate(resolve))
  assert.equal(completed, false)
  client.emit('block_change', { location: { x: 1, y: 81, z: 1 }, type: 0 })
  await run
  assert(completed)
  assert.equal(client.listenerCount('block_change'), 0)
})

test('batched block packets match section coordinates including negative chunks', () => {
  const modern = { supportFeature: () => true }
  const target = new Vec3(-17, -31, 18)
  const packet = { chunkCoordinates: { x: -2, y: -2, z: 1 }, records: [(100 << 12) | (15 << 8) | (2 << 4) | 1] }
  assert(packetChangesPosition(modern, packet, target, true))
  assert(!packetChangesPosition(modern, packet, target.offset(1, 0, 0), true))
  const legacy = { supportFeature: () => false }
  assert(packetChangesPosition(legacy, { chunkX: 1, chunkZ: -1, records: [{ horizontalPos: 0x21, y: 81 }] }, new Vec3(18, 81, -15), true))
})

test('cancelled block acknowledgements release packet and abort listeners', async () => {
  const signal = new AbortController()
  const client = new EventEmitter()
  const bot = { _client: client, blockAt: () => ({ name: 'stone' }) }
  const action = serverBlockEdit(bot, new Vec3(1, 81, 1), () => false, async () => {}, signal.signal)
  signal.abort(new Error('stop'))
  await assert.rejects(action, /stop/)
  assert.equal(client.listenerCount('block_change'), 0)
  assert.equal(client.listenerCount('multi_block_change'), 0)
  assert.equal(getEventListeners(signal.signal, 'abort').length, 0)
})

test('storage checks the open container inventory before closing and restores item balance', async () => {
  const window = windows('1.21.11').createWindow(1, 'minecraft:generic_9x3', 'Chest')
  const itemType = 14
  const target = new Vec3(1, 81, 1)
  const carried = (count) => ({ type: itemType, name: 'cobblestone', count })
  window.slots[window.inventoryStart] = carried(32)
  const bot = {
    username: 'Storage', entity: { position: target.offset(0.5, 0, 1.5) },
    inventory: { items: () => [carried(32)] }, registry: { itemsByName: { cobblestone: { id: itemType } } },
    pathfinder: { goto: async () => {}, goal: null }, clearControlStates() {}, deactivateItem() {},
    blockAt: () => ({ name: 'chest' }), openContainer: async () => { bot.currentWindow = window; return window }
  }
  let closed = false
  window.close = async () => { closed = true; bot.currentWindow = null }
  window.deposit = async (type, metadata, count) => {
    window.slots[0] = carried(count)
    window.slots[window.inventoryStart] = carried(32 - count)
  }
  window.withdraw = async () => {
    window.slots[0] = null
    window.slots[window.inventoryStart] = carried(32)
  }
  const events = []
  const result = await bounded('chest transfer', 500, undefined, (signal) => transferStorage({
    bot, signal, controller: {}, timeoutMs: 500, record: (event) => events.push(event)
  }, target))
  assert.deepEqual(result.counts, { storage: 1 })
  assert.deepEqual(events.map((event) => event.action), ['deposit', 'withdraw'])
  assert.equal(window.count(itemType), 32)
  assert.equal(window.containerCount(itemType), 0)
  assert(closed)
})

test('queued controller commands cancel promptly without sending after their turn arrives', async () => {
  const controller = new EventEmitter()
  const sent = []
  controller.chat = (command) => sent.push(command)
  const firstSignal = new AbortController()
  const queuedSignal = new AbortController()
  const first = controllerCommand(controller, '/give First stone', firstSignal.signal, 1000)
  first.catch(() => {})
  const second = controllerCommand(controller, '/give Second stone', queuedSignal.signal, 1000)
  queuedSignal.abort(new Error('cancel queued'))
  await assert.rejects(second, /cancel queued/)
  firstSignal.abort(new Error('cancel active'))
  await assert.rejects(first, /cancel active/)
  await new Promise((resolve) => setImmediate(resolve))
  assert.deepEqual(sent, [])
})

test('a blocked nearest station falls back to another reserved target', async () => {
  const bounds = { min: [0, 80, 0], max: [15, 85, 15] }
  const workload = validateWorkload({ schemaVersion: 1, name: 'Station fallback', bounds,
    roles: [{ name: 'carrier', activities: { storage: 1 } }],
    targets: { storage: [[3, 81, 1], [8, 81, 1]] }
  }, { bots: 1 })
  const window = windows('1.21.11').createWindow(1, 'minecraft:generic_9x3', 'Chest')
  const itemType = 14
  const carried = (count) => ({ type: itemType, name: 'cobblestone', count })
  window.slots[window.inventoryStart] = carried(32)
  const destinations = []
  const bot = {
    username: 'Carrier', food: 20, game: { gameMode: 'survival' }, entity: { position: new Vec3(1.5, 81, 1.5) },
    inventory: { items: () => [carried(32), { name: 'cooked_beef', count: 16 }] },
    registry: { itemsByName: { cobblestone: { id: itemType } } },
    clearControlStates() {}, deactivateItem() {}, blockAt: () => ({ name: 'chest' }),
    openContainer: async () => { bot.currentWindow = window; return window },
    pathfinder: {
      movements: { exclusionAreasStep: [], exclusionAreasBreak: [], exclusionAreasPlace: [] },
      setMovements() {}, setGoal(goal) { this.goal = goal },
      async goto(goal) {
        this.goal = goal
        destinations.push(goal.x)
        if (goal.x === 3) throw new Error('No route to this station')
        bot.entity.position = new Vec3(goal.x + 0.5, goal.y, goal.z + 1.5)
      }
    }
  }
  window.close = async () => { bot.currentWindow = null }
  window.deposit = async (type, metadata, count) => {
    window.slots[0] = carried(count)
    window.slots[window.inventoryStart] = carried(32 - count)
  }
  window.withdraw = async () => {
    window.slots[0] = null
    window.slots[window.inventoryStart] = carried(32)
  }
  const signal = new AbortController().signal
  const events = []
  const execute = await createStressExecutor({ bots: [bot], controller: { game: { gameMode: 'spectator' } },
    configuration: { workload }, signal, actionTimeoutMs: 15000, record: (event) => events.push(event) })
  const result = await execute({ bot, index: 0, activity: 'storage', role: workload.roles[0], signal,
    deadline: performance.now() + 15000, random: seededRandom(1), coordinator: new StressCoordinator() })
  assert.deepEqual(result.counts, { storage: 1 })
  assert.equal(destinations[0], 3)
  assert(destinations.includes(8))
  assert.equal(events.filter((event) => event.type === 'route-retry').length, 1)
})
