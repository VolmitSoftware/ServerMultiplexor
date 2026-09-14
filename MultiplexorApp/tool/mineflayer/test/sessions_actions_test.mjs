import assert from 'node:assert/strict'
import test from 'node:test'
import { Vec3 } from 'vec3'
import { defaultSettlementWorld, validateWorld, editable, recordChunkVisit, avoidCornerCutting } from '../src/sessions/world.mjs'
import { shelterBlueprint, initializeProjects, inspectProject, projectMaterials } from '../src/sessions/projects.mjs'
import { settlementCommands, prepareSessionWorld, SETTLEMENT_STARTER_STOCK } from '../src/sessions/fixtures.mjs'
import { chooseSettlementTask, createSessionActions } from '../src/sessions/actions.mjs'
import { inventoryCounts, transferResource } from '../src/sessions/resources.mjs'
import { preserveSearchNodes, stabilizeCollisionBounds } from '../src/sessions/world_navigation.mjs'
import AStar from 'mineflayer-pathfinder/lib/astar.js'
import Move from 'mineflayer-pathfinder/lib/move.js'

function observation(inventory = {}) {
  return { inventory, food: 20, health: 20, projects: [], candidates: { mine: [], wood: [], farm: [], unplanted: [], replant: [] }, storageStale: false }
}

function sharedState(items = {}) {
  const shared = {}
  initializeProjects(shared, defaultSettlementWorld())
  shared.world.storage.items = items
  return shared
}

test('session world rejects custom fixture edits, out-of-bounds stations, and oversized scans', () => {
  assert.equal(validateWorld().id, 'settlement')
  const custom = defaultSettlementWorld()
  custom.storage = [7, 80, 6]
  assert.throws(() => validateWorld(custom), /standard storage/)
  custom.setup = { kind: 'existing' }
  assert.equal(validateWorld(custom).storage[0], 7)
  custom.storage = [-1, 80, 6]
  assert.throws(() => validateWorld(custom), /outside/)
  custom.storage = [7, 80, 6]
  custom.bounds.max = [1000, 1000, 1000]
  custom.resourceAreas[0].max = [1000, 1000, 1000]
  assert.throws(() => validateWorld(custom), /65536/)
})

test('session edit regions prevent work in protected stores and other activity areas', () => {
  const world = defaultSettlementWorld()
  assert.equal(editable(world, [12, 80, 2], 'mine'), true)
  assert.equal(editable(world, world.storage, 'mine'), false)
  assert.equal(editable(world, [12, 80, 12], 'mine'), false)
  assert.equal(editable(world, [28, 80, 24], 'build'), true)
  assert.equal(editable(world, [28, 84, 24], 'build'), false)
})

test('exploration never counts the same chunk twice or evicts history to inflate visits', () => {
  const intent = {}
  assert.equal(recordChunkVisit(intent, 'survival', 'overworld', { x: -1, z: -1 }, 2), true)
  assert.equal(recordChunkVisit(intent, 'survival', 'overworld', { x: -16, z: -16 }, 2), false)
  assert.equal(recordChunkVisit(intent, 'survival', 'overworld', { x: 0, z: 0 }, 2), true)
  assert.equal(recordChunkVisit(intent, 'survival', 'overworld', { x: 16, z: 0 }, 2), false)
  assert.equal(recordChunkVisit(intent, 'survival', 'overworld', { x: -1, z: -1 }, 2), false)
  assert.equal(intent.chunkVisits.length, 2)
  assert.equal(intent.chunkTrackingFull, true)
})

test('navigation rejects diagonal corner cuts but retains open diagonal routes', () => {
  const neighbors = []
  let blocked = true
  const movements = {
    getBlock: (_node, x, _y, z) => ({ safe: !(blocked && x === 1 && z === 0) }),
    getMoveDiagonal: (_node, _direction, result) => result.push('diagonal')
  }
  avoidCornerCutting(movements)
  avoidCornerCutting(movements)
  movements.getMoveDiagonal({}, { x: 1, z: 1 }, neighbors)
  assert.deepEqual(neighbors, [])
  blocked = false
  movements.getMoveDiagonal({}, { x: 1, z: 1 }, neighbors)
  assert.deepEqual(neighbors, ['diagonal'])
})

test('formatting a partial path cannot corrupt the search graph used by later slices', () => {
  preserveSearchNodes()
  const start = new Move(0, 80, 0, 0, 0)
  const search = new AStar(start, { getNeighbors: () => [] }, { heuristic: () => 0 }, 1000)
  const child = { data: new Move(1, 80, 0, 0, 1, [{ x: 1, y: 80, z: 0 }]), parent: search.bestNode, g: 1 }
  const first = search.makeResult('partial', child)
  first.path[0].x += 0.5
  first.path[0].z += 0.5
  first.path[0].toBreak[0].x = 99
  assert.equal(child.data.x, 1)
  assert.equal(child.data.z, 0)
  assert.equal(child.data.toBreak[0].x, 1)
  assert.equal(search.makeResult('success', child).path[0].x, 1)
})

test('collision epsilon applies only to standard 1.21 client bounds', () => {
  const supported = { version: '1.21.11', physics: { playerHalfWidth: 0.3, playerHeight: 1.8 } }
  stabilizeCollisionBounds(supported)
  assert.deepEqual(supported.physics, { playerHalfWidth: 0.30001, playerHeight: 1.80001 })
  const custom = { version: '1.21.11', physics: { playerHalfWidth: 0.6, playerHeight: 1.8 } }
  stabilizeCollisionBounds(custom)
  assert.equal(custom.physics.playerHalfWidth, 0.6)
  const older = { version: '1.20.4', physics: { playerHalfWidth: 0.3, playerHeight: 1.8 } }
  stabilizeCollisionBounds(older)
  assert.equal(older.physics.playerHalfWidth, 0.3)
})

test('fixture resource stock can satisfy unique blueprint costs without building materials in starter chest', () => {
  const world = defaultSettlementWorld()
  const commands = settlementCommands(world)
  const cost = projectMaterials(world)
  const stone = commands.filter((command) => command.endsWith(' stone')).length
  const logs = commands.filter((command) => command.endsWith(' oak_log')).length
  assert.ok(stone >= cost.cobblestone)
  assert.ok(logs * 4 >= cost.oak_planks)
  assert.equal(SETTLEMENT_STARTER_STOCK.some(({ item }) => ['oak_log', 'oak_planks', 'cobblestone'].includes(item)), false)
  assert.equal(commands.some((command) => command.startsWith('/give') || command.startsWith('/clear')), false)
  assert.ok(commands.some((command) => command.includes('piston[facing=up')))
})

test('fixture preparation is persisted before commands and is never replayed after interruption', async () => {
  const shared = sharedState()
  const seen = []
  let checkpoints = 0
  const options = { world: defaultSettlementWorld(), shared, signal: new AbortController().signal, record: () => {}, checkpoint: async () => { checkpoints++ } }
  await assert.rejects(prepareSessionWorld({ ...options, command: async (command) => { seen.push(command); throw new Error('server gone') } }), /server gone/)
  assert.equal(shared.world.preparing, true)
  assert.equal(checkpoints, 1)
  await assert.rejects(prepareSessionWorld({ ...options, command: async (command) => { seen.push(command) } }), /never replayed/)
  assert.equal(seen.length, 1)
})

test('a builder waits for actual supplied material and uses inventory already obtained before another withdrawal', () => {
  const state = sharedState()
  const view = observation()
  view.projects = [{ next: { position: [28, 80, 24], block: 'cobblestone' } }]
  assert.match(chooseSettlementTask({ role: 'builder' }, view, state).reason, /waiting for cobblestone/)
  state.world.storage.items.cobblestone = 25
  assert.deepEqual(chooseSettlementTask({ role: 'builder' }, view, state), { kind: 'withdraw', item: 'cobblestone', count: 32 })
  view.inventory.cobblestone = 25
  assert.equal(chooseSettlementTask({ role: 'builder' }, view, state).kind, 'build')
})

test('gatherers deliver physical output, exhausted miners seek supplies, and farming supplies food under scarcity', () => {
  assert.deepEqual(chooseSettlementTask({ role: 'lumberjack' }, observation({ oak_log: 8 }), sharedState()), { kind: 'deposit', item: 'oak_log', count: 8 })
  assert.deepEqual(chooseSettlementTask({ role: 'miner' }, observation(), sharedState({ wooden_pickaxe: 1 })), { kind: 'withdraw', item: 'wooden_pickaxe', count: 1 })
  assert.deepEqual(chooseSettlementTask({ role: 'farmer' }, observation({ wheat: 6 }), sharedState()), { kind: 'craft', item: 'bread', batches: 2 })
  const view = observation()
  view.food = 12
  assert.deepEqual(chooseSettlementTask({ role: 'miner' }, view, sharedState({ bread: 10 })), { kind: 'withdraw', item: 'bread', count: 4 })
})

test('project completion comes from every real block and remains idempotent across repeated observations', () => {
  const world = defaultSettlementWorld()
  const plot = world.buildPlots[0]
  const blueprint = shelterBlueprint(plot)
  assert.equal(new Set(blueprint.map(({ position }) => position.join(','))).size, 58)
  const blocks = new Map(blueprint.map(({ position, block }) => [position.join(','), { name: block, boundingBox: 'block' }]))
  const bot = { blockAt: (position) => blocks.get(`${position.x},${position.y},${position.z}`) ?? { name: 'air', boundingBox: 'empty' } }
  const state = { verified: {} }
  for (let count = 0; count < 3; count++) assert.equal(inspectProject(bot, plot, state).completed, true)
  assert.equal(Object.keys(state.verified).length, 58)
  blocks.delete(blueprint[0].position.join(','))
  assert.equal(inspectProject(bot, plot, state).completed, false)
  assert.equal(Object.keys(state.verified).length, 57)
})

test('resuming invalidates world observations without erasing historical resource transfers', () => {
  const shared = sharedState({ cobblestone: 30 })
  const adapter = createSessionActions({ profile: { world: defaultSettlementWorld() }, shared })
  for (const project of Object.values(shared.world.projects)) { project.completed = true; project.verified = { '1,2,3': 'cobblestone' }; project.verifiedAt = Date.now() }
  shared.world.resourceTransfers = 32
  shared.world.storage.observedAt = Date.now()
  assert.equal(adapter.verifyGoals().goalsMet, true)
  adapter.resume()
  assert.equal(adapter.verifyGoals().goalsMet, false)
  assert.equal(adapter.verifyGoals().blocksVerified, 0)
  assert.equal(shared.world.storage.observedAt, null)
  assert.equal(shared.world.resourceTransfers, 32)
})

function inventoryHarness({ stored = 20, carried = 0, interrupt = false } = {}) {
  let depositCalls = 0
  let withdrawCalls = 0
  const item = (count) => count > 0 ? [{ name: 'cobblestone', type: 1, count }] : []
  const window = {
    get slots() { return [...item(stored), ...Array.from({ length: 27 - item(stored).length }, () => null)] },
    inventoryStart: 27,
    containerItems: () => item(stored), items: () => item(carried),
    withdraw: async (_type, _meta, count) => { withdrawCalls++; stored -= count; carried += count; if (interrupt) throw new Error('Disconnected after transfer') },
    deposit: async (_type, _meta, count) => { depositCalls++; stored += count; carried -= count },
    close: async () => { bot.currentWindow = null }
  }
  const bot = {
    username: 'test', entity: { position: new Vec3(6.5, 80, 6.5) },
    registry: { itemsByName: { cobblestone: { id: 1, stackSize: 64 } } },
    inventory: { items: () => item(carried) },
    pathfinder: { goto: async () => {}, setGoal: () => {} }, clearControlStates() {},
    blockAt: () => ({ name: 'chest' }), openContainer: async () => { bot.currentWindow = window; return window },
    closeWindow: () => { bot.currentWindow = null }
  }
  const context = {
    world: defaultSettlementWorld(), shared: sharedState(), signal: new AbortController().signal,
    checkpoint: async () => {}, record: () => {}, assertCurrent: () => {},
    coordinator: { acquire: () => ({ id: 1 }), assert: () => {}, release: () => {} }
  }
  return { bot, context, counts: () => ({ stored, carried, depositCalls, withdrawCalls }) }
}

test('storage withdrawal verifies both physical inventories and an ambiguous transfer is not replayed', async () => {
  const harness = inventoryHarness({ interrupt: true })
  const player = { id: 'one', generation: 1, intent: {} }
  await assert.rejects(transferResource(harness.bot, player, { kind: 'withdraw', item: 'cobblestone', count: 8 }, harness.context), /Disconnected/)
  assert.equal(player.intent.transfer.phase, 'uncertain')
  assert.equal(harness.context.shared.world.resourceTransfers, 0)
  assert.deepEqual(harness.counts(), { stored: 12, carried: 8, depositCalls: 0, withdrawCalls: 1 })
  const { withStorage } = await import('../src/sessions/resources.mjs')
  await withStorage(harness.bot, player, harness.context, async () => ({}))
  assert.equal(player.intent.transfer, undefined)
  assert.equal(player.intent.lastReconciliation.currentPlayerCount, 8)
  assert.equal(harness.counts().withdrawCalls, 1)
  assert.equal(harness.context.shared.world.resourceTransfers, 0)
})

test('storage deposits use observed stock and count a verified transfer once', async () => {
  const harness = inventoryHarness({ stored: 3, carried: 12 })
  const player = { id: 'one', generation: 1, intent: {} }
  const result = await transferResource(harness.bot, player, { kind: 'deposit', item: 'cobblestone', count: 8 }, harness.context)
  assert.equal(result.status, 'completed')
  assert.equal(harness.context.shared.world.resourceTransfers, 8)
  assert.deepEqual(harness.counts(), { stored: 11, carried: 4, depositCalls: 1, withdrawCalls: 0 })
  assert.deepEqual(inventoryCounts(harness.bot.inventory.items()), { cobblestone: 4 })
})

test('craft batches synchronize one recipe at a time and stop when observed ingredients run out', async () => {
  const world = defaultSettlementWorld()
  const shared = sharedState()
  let logs = 2
  let planks = 0
  const calls = []
  const movements = { exclusionAreasStep: [], exclusionAreasBreak: [], exclusionAreasPlace: [], getMoveDiagonal() {} }
  const bot = {
    username: 'Builder', version: '1.21.11', game: { dimension: 'overworld', gameMode: 'survival', minY: -64, height: 384 },
    entity: { position: new Vec3(8.5, 80, 8.5) },
    registry: { itemsByName: { oak_planks: { id: 2 } } },
    inventory: { items: () => [{ name: 'oak_log', count: logs }, { name: 'oak_planks', count: planks }] },
    blockAt: () => ({ name: 'crafting_table' }),
    pathfinder: { movements, setMovements() {}, goto: async () => {}, setGoal() {} }, clearControlStates() {},
    recipesFor: () => logs ? [{ result: { count: 4 } }] : [],
    craft: async (_recipe, count) => { calls.push(count); assert.equal(count, 1); logs--; planks += 4 }
  }
  const context = { backend: world.backend, signal: new AbortController().signal, assertCurrent() {}, coordinator: { acquire: () => ({}), assert() {}, release() {} } }
  const adapter = createSessionActions({ profile: { world }, shared })
  const result = await adapter.executeTask(bot, { id: 'one', generation: 1, intent: {} }, { kind: 'craft', item: 'oak_planks', batches: 8 }, context)
  assert.deepEqual(calls, [1, 1])
  assert.equal(result.metrics.itemsCrafted, 8)
  assert.equal(planks, 8)
})

test('a failed timber route keeps its failure and defers that target while exposing other logs', async () => {
  const world = defaultSettlementWorld()
  const events = []
  const movements = { exclusionAreasStep: [], exclusionAreasBreak: [], exclusionAreasPlace: [], getMoveDiagonal() {} }
  const bot = {
    username: 'Logger', version: '1.21.11', game: { dimension: 'overworld', gameMode: 'survival', minY: -64, height: 384 },
    entity: { position: new Vec3(8.5, 80, 8.5) }, food: 20, health: 20,
    inventory: { items: () => [] },
    blockAt: (position) => ({ name: position.y === 80 && position.z === 12 && [12, 14].includes(position.x) ? 'oak_log' : 'air', boundingBox: 'empty' }),
    pathfinder: { movements, setMovements() {}, goto: async () => { throw new Error('No reachable route') }, setGoal() {} }, clearControlStates() {}
  }
  const context = { backend: world.backend, signal: new AbortController().signal, assertCurrent() {}, coordinator: { acquire: () => ({}), assert() {}, release() {} } }
  const player = { id: 'one', generation: 1, role: 'lumberjack', intent: {} }
  const adapter = createSessionActions({ profile: { world }, shared: sharedState(), record: (event) => events.push(event) })
  await assert.rejects(adapter.executeTask(bot, player, { kind: 'wood', position: [12, 80, 12] }, context), /No reachable route/)
  assert.equal(events.at(-1).type, 'target-deferred')
  const observed = await adapter.observe(bot, player, context)
  assert.deepEqual(observed.candidates.wood, [[14, 80, 12]])
  assert.equal(observed.deferredTargets, 1)
})
