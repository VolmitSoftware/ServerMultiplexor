import { Vec3 } from 'vec3'
import { point, pause, until, interact } from '../swarm_actions.mjs'
import { serverBlockEdit } from '../swarm_block_ack.mjs'
import { containsBlock } from '../swarm_world_bounds.mjs'
import { assertWorld, editable, regionPositions, validateWorld, recordChunkVisit, sessionWalk as walkTo, travelToward } from './world.mjs'
import { initializeProjects, inspectProject, projectSummary } from './projects.mjs'
import { prepareSessionWorld } from './fixtures.mjs'
import { inventoryCounts, itemCount, transferResource, withStorage } from './resources.mjs'

const air = new Set(['air', 'cave_air', 'void_air'])
const offsets = [[0, -1, 0], [1, 0, 0], [-1, 0, 0], [0, 0, 1], [0, 0, -1]]
const tools = ['stone_pickaxe', 'wooden_pickaxe', 'iron_pickaxe', 'diamond_pickaxe', 'netherite_pickaxe']

function waiting(reason, milliseconds = 2000) { return { kind: 'idle', reason, milliseconds } }
function withdrawal(item, count) { return { kind: 'withdraw', item, count } }
function deposit(item, count) { return { kind: 'deposit', item, count } }

function scopePlayer(player, world) {
  player.intent ??= {}
  player.intent.worlds ??= {}
  player.intent.worlds[world.id] ??= {}
  return { ...player, intent: player.intent.worlds[world.id] }
}

function deferTarget(player, task, context, reason) {
  player.intent.targetCooldowns ??= {}
  const now = Date.now()
  for (const [key, entry] of Object.entries(player.intent.targetCooldowns)) {
    if (entry.until <= now) delete player.intent.targetCooldowns[key]
  }
  if (Object.keys(player.intent.targetCooldowns).length < 256) {
    player.intent.targetCooldowns[`${task.kind}:${task.position.join(',')}`] = { until: now + 60000, reason }
  }
  context.record({ type: 'target-deferred', player: player.id, action: task.kind, position: task.position, reason, retryAfterMs: 60000 })
}

export function chooseSettlementTask(player, observation, shared, random = Math.random) {
  if (observation.wrongBackend) return waiting('Visiting another backend')
  if (player.intent?.transfer) return { kind: 'inspectStorage', reason: 'Reconcile interrupted transfer' }
  const inventory = observation.inventory
  const stock = shared.world.storage.items
  const count = (name) => inventory[name] ?? 0
  const available = (name) => stock[name] ?? 0
  const role = player.role
  if (observation.storageStale && !count('bread')) return { kind: 'inspectStorage' }
  if (observation.food <= 16) {
    if (count('bread')) return { kind: 'eat', item: 'bread' }
    if (available('bread')) return withdrawal('bread', 4)
    if (observation.food <= 10) {
      if (count('wheat') >= 3) return { kind: 'craft', item: 'bread', batches: 1 }
      if (available('wheat') >= 3) return withdrawal('wheat', 3)
      if (observation.candidates.farm[0]) return { kind: 'farm', position: observation.candidates.farm[0] }
      return waiting('Food shortage; resting while crops grow')
    }
  }
  if (observation.meeting?.active && player.intent?.meetingAttended !== observation.meeting.id) return { kind: 'gather', meeting: observation.meeting.id }
  if (observation.storageStale) return { kind: 'inspectStorage' }
  if (role === 'builder') {
    const target = observation.projects.find((project) => project.next)?.next
    if (target) {
      if (count(target.block)) return { kind: 'build', position: target.position, block: target.block }
      if (available(target.block)) return withdrawal(target.block, 32)
      if (target.block === 'oak_planks' && count('oak_log')) return { kind: 'craft', item: 'oak_planks', batches: Math.min(8, count('oak_log')) }
      if (target.block === 'oak_planks' && available('oak_log')) return withdrawal('oak_log', 8)
      return waiting(`Builder waiting for ${target.block}`)
    }
    if (observation.projects.some((project) => project.blocked)) return waiting('Build plot contains unexpected blocks')
    if (observation.projects.some((project) => project.unloaded)) return { kind: 'travel', position: observation.unloadedPlot }
    if (count('cobblestone')) return deposit('cobblestone', count('cobblestone'))
    if (count('oak_planks')) return deposit('oak_planks', count('oak_planks'))
    return { kind: 'social' }
  }
  if (role === 'miner') {
    if (count('cobblestone') >= 11 || (!observation.candidates.mine.length && count('cobblestone') > 3)) return deposit('cobblestone', count('cobblestone') - 3)
    if (!tools.some((name) => count(name))) {
      const supplied = tools.find((name) => available(name))
      if (supplied) return withdrawal(supplied, 1)
      if (count('cobblestone') >= 3 && count('stick') >= 2) return { kind: 'craft', item: 'stone_pickaxe', batches: 1 }
      if (count('oak_planks') >= 3 && count('stick') >= 2) return { kind: 'craft', item: 'wooden_pickaxe', batches: 1 }
      if (count('oak_log')) return { kind: 'craft', item: 'oak_planks', batches: Math.min(2, count('oak_log')) }
      if (count('oak_planks') >= 2 && count('stick') < 2) return { kind: 'craft', item: 'stick', batches: 1 }
      if (available('oak_log')) return withdrawal('oak_log', 2)
      if (available('oak_planks')) return withdrawal('oak_planks', 8)
      if (available('cobblestone') >= 3 && count('cobblestone') < 3) return withdrawal('cobblestone', 3 - count('cobblestone'))
      return waiting('Miner waiting for a pickaxe or tool materials')
    }
    return observation.candidates.mine[0] ? { kind: 'mine', position: observation.candidates.mine[0] } : waiting('Quarry exhausted or unloaded')
  }
  if (role === 'lumberjack') {
    if (count('oak_log') >= 8 || (!observation.candidates.wood.length && count('oak_log'))) return deposit('oak_log', count('oak_log'))
    if (!['wooden_axe', 'stone_axe', 'iron_axe', 'diamond_axe', 'netherite_axe'].some((name) => count(name)) && available('wooden_axe')) return withdrawal('wooden_axe', 1)
    if (observation.candidates.replant.length && count('oak_sapling')) return { kind: 'replantTree', position: observation.candidates.replant[0] }
    if (observation.candidates.replant.length && available('oak_sapling') && !count('oak_sapling')) return withdrawal('oak_sapling', 4)
    if (observation.candidates.wood[0]) return { kind: 'wood', position: observation.candidates.wood[0] }
    return waiting(observation.deferredTargets ? `Waiting for reachable timber (${observation.deferredTargets} targets deferred)` : 'Waiting for trees to grow or loaded timber')
  }
  if (role === 'farmer') {
    if (count('bread') > 4) return deposit('bread', count('bread') - 4)
    if (count('wheat') >= 3 && available('bread') < 16) return { kind: 'craft', item: 'bread', batches: Math.floor(count('wheat') / 3) }
    if (count('wheat') >= 6 || (!observation.candidates.farm.length && count('wheat'))) return deposit('wheat', count('wheat'))
    if (count('wheat_seeds') > 16) return deposit('wheat_seeds', count('wheat_seeds') - 8)
    if (observation.candidates.unplanted.length && count('wheat_seeds')) return { kind: 'plant', position: observation.candidates.unplanted[0] }
    if (observation.candidates.unplanted.length && available('wheat_seeds') && !count('wheat_seeds')) return withdrawal('wheat_seeds', 8)
    if (observation.candidates.farm[0]) return { kind: 'farm', position: observation.candidates.farm[0] }
    if (count('wheat') >= 3) return { kind: 'craft', item: 'bread', batches: Math.floor(count('wheat') / 3) }
    if (count('bread') > 4) return deposit('bread', count('bread') - 4)
    return waiting('Waiting for mature crops')
  }
  if (role === 'crafter' || role === 'courier') {
    if (count('bread') > 4) return deposit('bread', count('bread') - 4)
    if (count('wheat') >= 3) return { kind: 'craft', item: 'bread', batches: Math.min(8, Math.floor(count('wheat') / 3)) }
    if (available('wheat') >= 3) return withdrawal('wheat', Math.min(24, Math.floor(available('wheat') / 3) * 3))
    if (count('oak_planks') >= 4) return deposit('oak_planks', count('oak_planks'))
    if (count('oak_log')) return { kind: 'craft', item: 'oak_planks', batches: Math.min(8, count('oak_log')) }
    if (available('oak_log') > 2 && available('oak_planks') < 64) return withdrawal('oak_log', Math.min(8, available('oak_log') - 2))
    return waiting('Waiting for ingredients to process')
  }
  if (role === 'explorer') return { kind: 'explore' }
  if (role === 'mechanic') return observation.redstoneAvailable ? { kind: 'redstone' } : waiting('No redstone stations configured')
  if (random() < 0.3) return waiting('Resting at the meeting point', 1000 + Math.floor(random() * 4000))
  return { kind: 'social' }
}

function candidateList(bot, world, positions, predicate, kind) {
  return positions.filter((position) => editable(world, position, kind) && predicate(bot.blockAt(point(position)), position))
    .sort((left, right) => bot.entity.position.distanceSquared(point(left)) - bot.entity.position.distanceSquared(point(right))).slice(0, 32)
}

function scopedClaim(context, player, key) {
  const owner = `${player.id}:${player.generation}`
  return context.coordinator.acquire(`${context.world.backend}:${context.world.dimension}:${key}`, owner, 120000)
}

async function editAndCollect(bot, player, task, context) {
  const { signal, world, assertCurrent } = context
  const target = point(task.position)
  if (!editable(world, task.position, task.kind)) throw new Error(`${task.kind} target is outside its permitted region`)
  const overhead = target.y > bot.entity.position.y + 2
  let approach = target
  if (overhead) {
    const standing = []
    for (const [dx, dz] of [[0, 0], [1, 0], [-1, 0], [0, 1], [0, -1]]) {
      for (let y = Math.min(Math.floor(bot.entity.position.y) + 1, target.y - 2); y >= Math.max(world.bounds.min[1], Math.floor(bot.entity.position.y) - 3); y--) {
        const candidate = new Vec3(target.x + dx, y, target.z + dz)
        if (containsBlock(world.bounds, candidate) && bot.blockAt(candidate)?.boundingBox === 'empty' &&
            bot.blockAt(candidate.offset(0, 1, 0))?.boundingBox === 'empty' && bot.blockAt(candidate.offset(0, -1, 0))?.boundingBox === 'block') {
          standing.push(candidate)
          break
        }
      }
    }
    approach = standing.sort((left, right) => left.distanceSquared(target) - right.distanceSquared(target))[0]
    if (!approach) {
      const reason = `No standing space beneath overhead resource: ${target}`
      deferTarget(player, task, context, reason)
      return { status: 'waiting', kind: task.kind, reason }
    }
  }
  await walkTo(bot, approach, signal, { near: !overhead })
  assertCurrent()
  const block = bot.blockAt(target)
  const valid = task.kind === 'mine' ? ['stone', 'cobblestone'].includes(block?.name)
    : task.kind === 'wood' ? block?.name === 'oak_log'
      : block?.name === 'wheat' && Number(block.getProperties().age) === 7
  if (!valid) return { status: 'waiting', reason: 'Resource changed before work started' }
  const expectedItem = task.kind === 'mine' ? 'cobblestone' : task.kind === 'wood' ? 'oak_log' : 'wheat'
  const before = itemCount(bot, expectedItem)
  const bestTool = bot.pathfinder.bestHarvestTool(block)
  if (task.kind === 'mine' && !bestTool) return { status: 'waiting', reason: 'No usable mining tool' }
  if (bestTool) await bot.equip(bestTool, 'hand')
  if (!bot.canDigBlock(block)) {
    const reason = `Resource is outside mining reach after approach: ${target}`
    deferTarget(player, task, context, reason)
    return { status: 'waiting', kind: task.kind, reason }
  }
  const cancel = () => { bot.stopDigging(); bot.clearControlStates() }
  signal.addEventListener('abort', cancel, { once: true })
  try {
    await serverBlockEdit(bot, target, (current) => air.has(current?.name), () => bot.dig(block), signal)
    assertCurrent()
    const pickup = overhead ? approach : target
    await walkTo(bot, pickup, signal)
    await until(() => itemCount(bot, expectedItem) > before, signal, `Collect ${expectedItem} drop`)
    const gained = itemCount(bot, expectedItem) - before
    if (task.kind === 'wood') {
      player.intent.harvestedTrees ??= []
      if (player.intent.harvestedTrees.length < 128) player.intent.harvestedTrees.push(task.position)
    }
    let replanted = 0
    if (task.kind === 'farm' && itemCount(bot, 'wheat_seeds')) {
      const planting = await plant(bot, { kind: 'plant', position: task.position }, context)
      replanted = Number(planting.status === 'completed')
    }
    return { status: 'completed', kind: task.kind, item: expectedItem,
      metrics: { blocksHarvested: 1, itemsCollected: gained, cropsHarvested: Number(task.kind === 'farm'), cropsReplanted: replanted } }
  } finally { signal.removeEventListener('abort', cancel) }
}

async function plant(bot, task, context) {
  const crop = task.kind === 'replantTree' ? 'oak_sapling' : 'wheat'
  const itemName = task.kind === 'replantTree' ? 'oak_sapling' : 'wheat_seeds'
  if (!editable(context.world, task.position, task.kind === 'replantTree' ? 'wood' : 'farm')) throw new Error('Planting target is outside its permitted region')
  const target = point(task.position)
  await walkTo(bot, target, context.signal, { near: true })
  const before = bot.blockAt(target)
  if (!air.has(before?.name)) return { status: 'waiting', reason: 'Planting target is occupied' }
  const soil = bot.blockAt(target.offset(0, -1, 0))
  if (!(task.kind === 'replantTree' ? ['dirt', 'grass_block'].includes(soil?.name) : soil?.name === 'farmland')) return { status: 'waiting', reason: 'Planting soil is unsuitable' }
  const item = bot.inventory.items().find((candidate) => candidate.name === itemName)
  if (!item) return { status: 'waiting', reason: `Waiting for ${itemName}` }
  await bot.equip(item, 'hand')
  context.assertCurrent()
  await serverBlockEdit(bot, target, (block) => block?.name === crop, () => bot.placeBlock(soil, new Vec3(0, 1, 0)), context.signal)
  return { status: 'completed', kind: task.kind, metrics: { replanted: 1 } }
}

async function construct(bot, task, context) {
  if (!editable(context.world, task.position, 'build')) throw new Error('Building target is outside its permitted plot')
  const target = point(task.position)
  await walkTo(bot, target, context.signal, { near: true })
  if (bot.blockAt(target)?.name === task.block) return { status: 'waiting', reason: 'Another builder completed this block' }
  if (!air.has(bot.blockAt(target)?.name)) return { status: 'waiting', reason: 'Building target is occupied' }
  const item = bot.inventory.items().find((candidate) => candidate.name === task.block)
  if (!item) return { status: 'waiting', reason: `Waiting for ${task.block}` }
  const neighbor = offsets.map((offset) => ({ offset, block: bot.blockAt(target.offset(...offset)) })).find(({ block }) => block?.boundingBox === 'block')
  if (!neighbor) return { status: 'waiting', reason: 'Building target has no support' }
  if (bot.entity.position.distanceTo(target.offset(0.5, 0, 0.5)) < 0.8) {
    const alternative = offsets.slice(1).map((offset) => target.offset(...offset)).find((candidate) => containsBlock(context.world.bounds, candidate) && air.has(bot.blockAt(candidate)?.name) && bot.blockAt(candidate.offset(0, -1, 0))?.boundingBox === 'block')
    if (!alternative) return { status: 'waiting', reason: 'Builder must leave the placement space' }
    await walkTo(bot, alternative, context.signal)
  }
  await bot.equip(item, 'hand')
  context.assertCurrent()
  await serverBlockEdit(bot, target, (block) => block?.name === task.block, () => bot.placeBlock(neighbor.block, new Vec3(...neighbor.offset).scaled(-1)), context.signal)
  return { status: 'completed', kind: 'build', metrics: { blocksPlaced: 1 } }
}

async function craft(bot, player, task, context) {
  await walkTo(bot, context.world.craftingTable, context.signal, { near: true })
  const table = bot.blockAt(point(context.world.craftingTable))
  if (table?.name !== 'crafting_table') return { status: 'waiting', reason: 'Crafting table is missing' }
  const item = bot.registry.itemsByName[task.item]
  if (!item) throw new Error(`Unknown recipe output ${task.item}`)
  const recipe = bot.recipesFor(item.id, null, 1, table)[0]
  if (!recipe) return { status: 'waiting', reason: `Missing ingredients for ${task.item}` }
  const before = itemCount(bot, task.item)
  player.intent.craft = { item: task.item, before, phase: 'intent' }
  await context.checkpoint()
  context.assertCurrent()
  const cancel = () => { if (bot.currentWindow) bot.closeWindow(bot.currentWindow) }
  context.signal.addEventListener('abort', cancel, { once: true })
  try {
    let count = 0
    for (let batch = 0; batch < task.batches; batch++) {
      context.signal.throwIfAborted(); context.assertCurrent()
      const currentRecipe = bot.recipesFor(item.id, null, 1, table)[0]
      if (!currentRecipe) break
      const batchBefore = itemCount(bot, task.item)
      // Mineflayer synchronizes its final inventory click when each craft call closes the table.
      await bot.craft(currentRecipe, 1, table)
      await until(() => itemCount(bot, task.item) >= batchBefore + currentRecipe.result.count, context.signal, 'Crafted inventory result')
      count += itemCount(bot, task.item) - batchBefore
    }
    if (task.item === 'bread') context.shared.world.foodCrafted += count
    delete player.intent.craft
    await context.checkpoint()
    if (!count) return { status: 'waiting', reason: `Ingredients for ${task.item} changed before crafting` }
    return { status: 'completed', kind: 'craft', item: task.item, metrics: { itemsCrafted: count } }
  } finally { context.signal.removeEventListener('abort', cancel) }
}

async function explore(bot, player, context) {
  if (!context.world.frontiers.length) return { status: 'waiting', reason: 'No exploration frontiers configured' }
  const origin = bot.entity.position
  player.intent.frontier ??= null
  if (!player.intent.frontier || Math.hypot(player.intent.frontier.x - origin.x, player.intent.frontier.z - origin.z) < 3) {
    const region = context.world.frontiers[Math.floor(context.random() * context.world.frontiers.length)]
    player.intent.frontier = {
      region: region.id,
      x: Math.round(region.min[0] + context.random() * (region.max[0] - region.min[0])),
      z: Math.round(region.min[2] + context.random() * (region.max[2] - region.min[2]))
    }
  }
  const { x: targetX, z: targetZ } = player.intent.frontier
  const distance = Math.hypot(targetX - origin.x, targetZ - origin.z)
  const factor = Math.min(1, 12 / Math.max(distance, 1))
  const x = Math.floor(origin.x + (targetX - origin.x) * factor)
  const z = Math.floor(origin.z + (targetZ - origin.z) * factor)
  let target
  for (let y = Math.min(Math.floor(origin.y) + 2, context.world.bounds.max[1] - 1); y >= Math.max(Math.floor(origin.y) - 2, context.world.bounds.min[1]); y--) {
    const candidate = new Vec3(x, y, z)
    if (air.has(bot.blockAt(candidate)?.name) && air.has(bot.blockAt(candidate.offset(0, 1, 0))?.name) && bot.blockAt(candidate.offset(0, -1, 0))?.boundingBox === 'block') { target = candidate; break }
  }
  if (!target) return { status: 'waiting', reason: 'Frontier route needs loaded, walkable terrain' }
  await walkTo(bot, target, context.signal)
  const newlyVisited = recordChunkVisit(player.intent, context.world.backend, context.world.dimension, bot.entity.position)
  return { status: 'completed', kind: 'explore', chunkTrackingFull: player.intent.chunkTrackingFull ?? false,
    metrics: { blocksWalked: origin.distanceTo(bot.entity.position), exploredChunks: Number(newlyVisited) } }
}

function currentMeeting(shared, player, context) {
  const peers = (context.peers ?? []).filter((peer) => peer.backend === context.backend && peer.homeWorld === player.homeWorld)
  if (!player.socialGroup || peers.length < 2) return null
  shared.world.meetings ??= {}
  const now = Date.now()
  const meeting = shared.world.meetings[player.socialGroup] ??= { sequence: 0, opensAt: now + 120000, closesAt: now + 150000, participants: {}, counted: false }
  if (now > meeting.closesAt) {
    meeting.sequence++
    meeting.opensAt = now + 180000
    meeting.closesAt = meeting.opensAt + 30000
    meeting.participants = {}
    meeting.counted = false
  }
  return { id: `${player.socialGroup}:${meeting.sequence}`, active: now >= meeting.opensAt, state: meeting }
}

export function createSessionActions({ profile, shared, record = () => {}, checkpoint = async () => {} }) {
  const world = validateWorld(profile.world)
  initializeProjects(shared, world)
  const minePositions = regionPositions(world.resourceAreas.filter((region) => region.kind === 'mine'))
  const woodPositions = regionPositions(world.resourceAreas.filter((region) => region.kind === 'wood'))
  const farmPositions = regionPositions(world.farmAreas)
  const adapter = {
    world,
    resume() {
      for (const project of Object.values(shared.world.projects)) {
        project.completed = false
        project.verified = {}
        project.verifiedAt = null
      }
      shared.world.storage.observedAt = null
    },
    async prepare(options) { return prepareSessionWorld({ ...options, world, shared, record, checkpoint }) },
    async arrive(bot, player, context) {
      if (context.backend !== world.backend) return
      assertWorld(bot, world, context.backend)
    },
    async observe(bot, player, context) {
      player = scopePlayer(player, world)
      if (context.backend !== world.backend) return { wrongBackend: true, inventory: inventoryCounts(bot.inventory.items()), projects: [], candidates: {} }
      assertWorld(bot, world, context.backend)
      if (player.intent.craft) {
        record({ type: 'craft-reconciled', player: player.id, item: player.intent.craft.item, before: player.intent.craft.before, observed: itemCount(bot, player.intent.craft.item), outcome: 'reobserved; no completion credit' })
        delete player.intent.craft
        await checkpoint()
      }
      const projects = world.buildPlots.map((plot) => inspectProject(bot, plot, shared.world.projects[plot.id]))
      const meeting = currentMeeting(shared, player, context)
      const cooldowns = player.intent.targetCooldowns ?? {}
      const now = Date.now()
      for (const [key, entry] of Object.entries(cooldowns)) if (entry.until <= now) delete cooldowns[key]
      const eligible = (kind, positions) => positions.filter((position) => !cooldowns[`${kind}:${position.join(',')}`])
      return {
        inventory: inventoryCounts(bot.inventory.items()), position: [bot.entity.position.x, bot.entity.position.y, bot.entity.position.z],
        food: bot.food, health: bot.health, dimension: bot.game.dimension, projects,
        unloadedPlot: world.buildPlots.find((plot) => projects.find((project) => project.id === plot.id)?.unloaded)?.origin,
        storageStale: !shared.world.storage.observedAt || Date.now() - shared.world.storage.observedAt > 15000,
        redstoneAvailable: world.redstone.length > 0,
        meeting: meeting ? { id: meeting.id, active: meeting.active } : null,
        deferredTargets: Object.keys(cooldowns).length,
        candidates: {
          mine: candidateList(bot, world, eligible('mine', minePositions), (block) => ['stone', 'cobblestone'].includes(block?.name), 'mine'),
          wood: candidateList(bot, world, eligible('wood', woodPositions), (block) => block?.name === 'oak_log', 'wood'),
          farm: candidateList(bot, world, eligible('farm', farmPositions), (block) => block?.name === 'wheat' && Number(block.getProperties().age) === 7, 'farm'),
          unplanted: candidateList(bot, world, eligible('plant', farmPositions), (block, position) => air.has(block?.name) && bot.blockAt(point(position).offset(0, -1, 0))?.name === 'farmland', 'farm'),
          replant: candidateList(bot, world, eligible('replantTree', player.intent.harvestedTrees ?? []), (block, position) => air.has(block?.name) && ['dirt', 'grass_block'].includes(bot.blockAt(point(position).offset(0, -1, 0))?.name), 'wood')
        }
      }
    },
    chooseTask(player, observation, state = shared, context = {}) {
      const task = chooseSettlementTask(scopePlayer(player, world), observation, state, context.random)
      if (observation.wrongBackend) return task
      let destination = ['inspectStorage', 'withdraw', 'deposit'].includes(task.kind) ? world.storage
        : task.kind === 'craft' ? world.craftingTable : ['social', 'gather'].includes(task.kind) ? world.meetingPoint : task.position
      if (task.kind === 'idle') {
        const area = player.role === 'miner' ? world.resourceAreas.find((region) => region.kind === 'mine')
          : player.role === 'lumberjack' ? world.resourceAreas.find((region) => region.kind === 'wood')
            : player.role === 'farmer' ? world.farmAreas[0] : null
        destination = area?.min
      }
      if (destination && point(observation.position).distanceTo(point(destination)) > 24) return { kind: 'travel', position: destination, reason: `Travelling to ${task.kind === 'idle' ? 'work area' : task.kind}` }
      return task
    },
    async executeTask(bot, player, task, supplied) {
      player = scopePlayer(player, world)
      const context = { random: Math.random, assertCurrent: () => {}, checkpoint, record, ...supplied, world, shared }
      const { signal } = context
      signal.throwIfAborted(); context.assertCurrent()
      if (context.backend !== world.backend) {
        await pause(1000, signal)
        return { status: 'waiting', kind: 'idle', reason: 'Visiting another backend' }
      }
      assertWorld(bot, world, context.backend)
      if (task.kind === 'idle') { await pause(Math.min(task.milliseconds ?? 2000, 5000), signal); return { status: 'waiting', kind: 'idle', reason: task.reason } }
      if (task.kind === 'inspectStorage') return withStorage(bot, player, context, async () => ({ status: 'completed', kind: 'inspectStorage', metrics: {} }))
      if (['deposit', 'withdraw'].includes(task.kind)) return transferResource(bot, player, task, context)
      if (task.kind === 'travel') return travelToward(bot, task.position, signal)
      if (task.kind === 'explore') return explore(bot, player, context)
      if (task.kind === 'gather') {
        const meeting = currentMeeting(shared, player, context)
        if (!meeting?.active || meeting.id !== task.meeting) return { status: 'waiting', reason: 'Gathering has ended' }
        await walkTo(bot, world.meetingPoint, signal, { near: true })
        const nearby = (context.peers ?? []).filter((peer) => peer.id !== player.id && peer.backend === world.backend && peer.homeWorld === player.homeWorld &&
          bot.players[peer.username]?.entity?.position.distanceTo(bot.entity.position) <= 8)
        if (!nearby.length) { await pause(2000, signal); return { status: 'waiting', kind: 'gather', reason: 'Waiting briefly for the group' } }
        player.intent.meetingAttended = meeting.id
        meeting.state.participants[player.id] = Date.now()
        for (const peer of nearby) meeting.state.participants[peer.id] = Date.now()
        const counted = !meeting.state.counted
        meeting.state.counted = true
        record({ type: 'gathering', player: player.id, group: player.socialGroup, meeting: meeting.id, nearby: nearby.map((peer) => peer.id) })
        await pause(2000, signal)
        return { status: 'completed', kind: 'gather', metrics: { gatherings: Number(counted), groupVisits: 1 } }
      }
      if (task.kind === 'social') {
        await walkTo(bot, world.meetingPoint, signal, { near: true })
        const now = Date.now()
        if (now - (player.intent.lastChatAt ?? 0) >= 30000) {
          const summary = projectSummary(shared, world)
          const message = summary.goalsMet ? 'The shelters are finished. Meeting at the stores.'
            : `At the meeting point. ${summary.blocksVerified} building blocks checked so far.`
          const heard = new Promise((resolve, reject) => {
            const received = (text) => { if (text.includes(message) && text.includes(bot.username)) { clean(); resolve() } }
            const cancel = () => { clean(); reject(signal.reason) }
            const clean = () => { bot.removeListener('messagestr', received); signal.removeEventListener('abort', cancel) }
            bot.on('messagestr', received); signal.addEventListener('abort', cancel, { once: true })
          })
          bot.chat(message)
          await heard
          player.intent.lastChatAt = now
          return { status: 'completed', kind: 'social', metrics: { messages: 1 } }
        }
        await pause(1500, signal)
        return { status: 'completed', kind: 'social', metrics: {} }
      }
      if (task.kind === 'eat') {
        const food = bot.inventory.items().find((item) => item.name === task.item)
        if (!food) return { status: 'waiting', reason: 'Food is no longer available' }
        const before = bot.food
        await bot.equip(food, 'hand'); await bot.consume()
        await until(() => bot.food > before, signal, 'Food restored')
        return { status: 'completed', kind: 'eat', metrics: { meals: 1 } }
      }
      const station = task.position?.join(',') ?? (task.kind === 'craft' ? world.craftingTable.join(',') : 'redstone')
      const lease = scopedClaim(context, player, `work:${station}`)
      if (!lease) return { status: 'waiting', reason: 'Work target is reserved' }
      const originalAssert = context.assertCurrent
      context.assertCurrent = () => { originalAssert(); context.coordinator.assert(lease) }
      try {
        if (['mine', 'wood', 'farm'].includes(task.kind)) return await editAndCollect(bot, player, task, context)
        if (['plant', 'replantTree'].includes(task.kind)) return await plant(bot, task, context)
        if (task.kind === 'build') return await construct(bot, task, context)
        if (task.kind === 'craft') return await craft(bot, player, task, context)
        if (task.kind === 'redstone') {
          const station = world.redstone[Math.floor(context.random() * world.redstone.length)]
          if (!station) return { status: 'waiting', reason: 'No redstone station configured' }
          await interact(bot, station.control, signal, bot, station.lamp)
          if (station.piston) {
            const powered = bot.blockAt(point(station.control))?.getProperties().powered === true
            await until(() => bot.blockAt(point(station.piston))?.getProperties().extended === powered &&
              (powered ? bot.blockAt(point(station.head))?.name === 'piston_head' : air.has(bot.blockAt(point(station.head))?.name)), signal, 'Piston movement')
          }
          return { status: 'completed', kind: 'redstone', metrics: { redstoneTransitions: 1, pistonTransitions: Number(Boolean(station.piston)) } }
        }
        throw new Error(`Unknown session action ${task.kind}`)
      } catch (error) {
        if (task.position && (!signal.aborted || signal.reason?.kind === 'timeout') && ['mine', 'wood', 'farm', 'plant', 'replantTree'].includes(task.kind)) {
          deferTarget(player, task, context, error.message)
          await context.checkpoint()
        }
        throw error
      } finally { context.coordinator.release(lease) }
    },
    verifyGoals() { return projectSummary(shared, world) },
    async dispose() {}
  }
  return adapter
}
