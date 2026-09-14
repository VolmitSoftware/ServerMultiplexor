import { Vec3 } from 'vec3'
import { bounded, controllerCommand, interact, pause, point, sendChat, until, walkTo } from './swarm_actions.mjs'
import { serverBlockEdit } from './swarm_block_ack.mjs'
import { assertTargetBounds, assertWorkerBounds, constrainWorker, containsBlock, containsWorker } from './swarm_world_bounds.mjs'
import { craftItems, farmFace, maintainFood, supplyItem, transferStorage, trimSurplus } from './swarm_stress_inventory.mjs'
import { assignRoles } from './swarm_workload.mjs'

const air = new Set(['air', 'cave_air', 'void_air'])
const unsafeFloor = new Set(['magma_block', 'campfire', 'soul_campfire', 'cactus', 'farmland'])
const fixtureActivities = new Set(['mine', 'build', 'redstone', 'farm', 'storage', 'craft'])
const xyz = (position) => `${position.x} ${position.y} ${position.z}`

export function stressTileLayout(tile) {
  return {
    mine: [tile.base.offset(7, 1, 8), tile.base.offset(9, 1, 8)],
    build: [tile.base.offset(7, 1, 8), tile.base.offset(9, 1, 8)],
    redstone: [tile.lever, tile.button, tile.plate],
    storage: [tile.base.offset(1, 1, 1)],
    craft: [tile.base.offset(1, 1, 3)],
    farm: [tile.base.offset(10, 1, 1)]
  }
}

async function prepareFixtures({ bots, controller, arena, signal, actionTimeoutMs, record }) {
  const targets = Object.fromEntries([...fixtureActivities].map((activity) => [activity, []]))
  for (let index = 0; index < bots.length; index++) {
    const tile = arena.tiles[index]
    const fixture = stressTileLayout(tile)
    for (const [activity, positions] of Object.entries(fixture)) targets[activity].push(...positions)
    await controllerCommand(controller, `/tp @s ${xyz(tile.base.offset(6, 6, 6))}`, signal, actionTimeoutMs)
    await until(() => controller.blockAt(tile.base), signal, 'stress fixture chunks')
    for (const [position, block] of [
      [fixture.storage[0], 'chest'], [fixture.craft[0], 'crafting_table'],
      [fixture.mine[0], 'stone'], [fixture.build[1], 'air'],
      [fixture.farm[0].offset(0, -1, 0), 'farmland[moisture=7]'],
      [fixture.farm[0].offset(0, -1, 1), 'water'], [fixture.farm[0], 'wheat[age=7]']
    ]) {
      await controllerCommand(controller, `/setblock ${xyz(position)} ${block}`, signal, actionTimeoutMs)
    }
    record({ bot: bots[index].username, type: 'support', operation: 'stress-fixture', targets: fixture })
  }
  return targets
}

async function placeInsideBounds(bot, index, count, controller, bounds, signal, timeoutMs, record) {
  if (containsWorker(bounds, bot.entity.position)) return
  const columns = Math.ceil(Math.sqrt(count))
  const rows = Math.ceil(count / columns)
  const x = Math.floor(bounds.min[0] + (index % columns + 0.5) / columns * (bounds.max[0] - bounds.min[0] + 1))
  const z = Math.floor(bounds.min[2] + (Math.floor(index / columns) + 0.5) / rows * (bounds.max[2] - bounds.min[2] + 1))
  const probe = new Vec3(x, bounds.min[1], z)
  await controllerCommand(controller, `/tp @s ${x} ${Math.min(bounds.max[1], bounds.min[1] + 64)} ${z}`, signal, timeoutMs)
  await until(() => controller.blockAt(probe), signal, 'bounds landing chunks')
  await controllerCommand(controller, `/execute positioned ${x + 0.5} 0 ${z + 0.5} positioned over motion_blocking run tp ${bot.username} ~ ~ ~`, signal, timeoutMs)
  await until(() => Math.abs(bot.entity.position.x - x - 0.5) < 0.5 && Math.abs(bot.entity.position.z - z - 0.5) < 0.5, signal, 'bounds arrival')
  await until(() => {
    const floor = bot.blockAt(bot.entity.position.offset(0, -0.1, 0))
    return floor && !air.has(floor.name)
  }, signal, 'bounds standing surface')
  const floor = bot.blockAt(bot.entity.position.offset(0, -0.1, 0))
  if (!containsWorker(bounds, bot.entity.position) || ['water', 'lava'].includes(floor.name) ||
      bot.blockAt(bot.entity.position)?.boundingBox === 'block' || bot.blockAt(bot.entity.position.offset(0, 1, 0))?.boundingBox === 'block') {
    throw new Error(`No safe standing surface within bounds for ${bot.username}; choose bounds over accessible terrain`)
  }
  record({ bot: bot.username, type: 'support', operation: 'place-in-bounds', position: bot.entity.position.clone() })
}

export async function createStressExecutor({ bots, controller, arena, configuration, signal, record, actionTimeoutMs }) {
  const workload = configuration.workload
  const bounds = workload.bounds
  if (!bounds) throw new Error('Stress workload must resolve world bounds before setup')
  if (controller.game.gameMode !== 'spectator') {
    await controllerCommand(controller, '/gamemode spectator @s', signal, actionTimeoutMs)
  }
  const fixtureTargets = arena
    ? await prepareFixtures({ bots, controller, arena, signal, actionTimeoutMs, record }) : {}
  const targets = Object.fromEntries([...fixtureActivities].map((activity) => [activity,
    (workload.targets?.[activity] ?? fixtureTargets[activity] ?? []).map(point)]))
  for (const positions of Object.values(targets)) {
    if (positions.some((position) => !containsBlock(bounds, position))) throw new Error('Stress fixture target is outside bounds')
  }
  const state = bots.map(() => ({ turn: 0, lastChat: -Infinity, heading: undefined, visited: new Set(), pending: false, blockedTargets: new Map() }))
  const roles = assignRoles(workload.roles, bots.length)
  for (let index = 0; index < bots.length; index++) {
    const bot = bots[index]
    await bounded('Stress worker setup', actionTimeoutMs * 6, signal, async (current) => {
      if (bot.game.gameMode !== 'survival') await controllerCommand(controller, `/gamemode survival ${bot.username}`, current, actionTimeoutMs)
      await placeInsideBounds(bot, index, bots.length, controller, bounds, current, actionTimeoutMs, record)
      constrainWorker(bot, bounds)
      // Crops and water holes are activity targets, not walking routes.
      bot.pathfinder.movements.exclusionAreasStep.push((block) =>
        targets.farm.some((target) => target.x === block.position.x && target.z === block.position.z) ? 100 : 0)
      bot.pathfinder.setMovements(bot.pathfinder.movements)
      await supplyItem(bot, controller, 'cooked_beef', 16, current, actionTimeoutMs, record)
      const activities = roles[index].activities
      const supplies = {
        ...(activities.mine ? { iron_pickaxe: 1 } : {}),
        ...(activities.build ? { stone: 64 } : {}),
        ...(activities.craft ? { oak_log: 32 } : {}),
        ...(activities.farm ? { wheat_seeds: 32, bone_meal: 64 } : {}),
        ...(activities.storage ? { cobblestone: 32 } : {})
      }
      for (const [name, count] of Object.entries(supplies)) {
        await supplyItem(bot, controller, name, count, current, actionTimeoutMs, record)
      }
    })
  }

  const execute = async ({ bot, index, activity, role, signal: current, deadline, random, coordinator, worker: workerSummary }) => {
    const worker = state[index]
    if (worker.pending) {
      const error = new Error(`${bot.username} still has a pending inventory operation`)
      error.fatal = true
      throw error
    }
    assertWorkerBounds(bot)
    const timeoutMs = Math.max(1, Math.min(actionTimeoutMs, deadline - performance.now()))
    const run = async (jobSignal) => {
      const context = { bot, controller, signal: jobSignal, timeoutMs, record, targets: nearestTargets(bot, targets[activity]), turn: worker.turn++ }
      await maintainFood(context)
      jobSignal.throwIfAborted()
      if (activity === 'idle') {
        await pause(Math.min(1000, timeoutMs / 2), jobSignal)
        return { counts: { idle: 1 } }
      }
      if (activity === 'chat') {
        if (performance.now() - worker.lastChat < 5000) return { status: 'skipped', reason: 'Chat cooldown' }
        const templates = workload.messages
        const message = templates[Math.floor(random() * templates.length)]
          .replaceAll('{bot}', bot.username).replaceAll('{index}', String(index + 1))
          .replaceAll('{role}', role.name).replaceAll('{activity}', activity)
          .replaceAll('{completed}', String(workerSummary?.completed ?? 0))
        if (message.length > 256) throw new Error('Expanded chat message exceeds 256 characters')
        await sendChat(bot, bot, message, jobSignal)
        worker.lastChat = performance.now()
        return { counts: { chat: 1 }, message }
      }
      if (activity === 'patrol' || activity === 'explore') {
        return moveWorker({ bot, worker, activity, random, bounds, signal: jobSignal, timeoutMs, record })
      }
      if (activity === 'craft') {
        context.targets = []
        for (const target of nearestTargets(bot, targets.craft).slice(0, 4)) {
          if (await approachTarget(bot, target, worker, jobSignal, timeoutMs, record)) {
            context.targets = [target]
            break
          }
        }
        return craftItems(context)
      }
      const candidates = nearestTargets(bot, targets[activity]).filter((target) => {
        const block = bot.blockAt(target)
        if (!block) return false
        if (activity === 'mine') return !air.has(block.name)
        if (activity === 'build') return air.has(block.name)
        return true
      }).slice(0, 8)
      for (const target of candidates) {
        jobSignal.throwIfAborted()
        const result = await coordinator.claim(target, async () => {
          if (!await approachTarget(bot, target, worker, jobSignal, timeoutMs, record)) {
            return { status: 'skipped', reason: 'Station route is currently blocked' }
          }
          if (activity === 'mine') return mineResource(context, target)
          if (activity === 'build') return buildResource(context, target)
          if (activity === 'redstone') {
            if (!bot.blockAt(target)) return { status: 'skipped', reason: 'Redstone target is not loaded' }
            const details = await interact(bot, target, jobSignal)
            return { counts: { redstone: 1 }, ...details }
          }
          if (activity === 'farm') return farmCrop(context, target)
          if (activity === 'storage') {
            return transferStorage(context, target)
          }
          throw new Error(`Unimplemented stress activity: ${activity}`)
        })
        if (result?.skipped || result?.status === 'skipped') continue
        assertWorkerBounds(bot)
        return result
      }
      return { status: 'skipped', reason: `No available ${activity} target; waiting for another worker or world state` }
    }
    worker.pending = true
    try {
      return await run(current)
    } finally {
      worker.pending = false
      bot.clearControlStates()
    }
  }
  execute.bounds = bounds
  return execute
}

function nearestTargets(bot, positions = []) {
  return positions.slice().sort((a, b) => a.distanceSquared(bot.entity.position) - b.distanceSquared(bot.entity.position))
}

async function approachTarget(bot, target, worker, signal, timeoutMs, record) {
  const key = target.toString()
  if ((worker.blockedTargets.get(key) ?? 0) > performance.now()) return false
  try {
    await bounded('Station approach', Math.min(5000, Math.max(1000, timeoutMs / 3)), signal,
      (routeSignal) => walkTo(bot, target, routeSignal, { near: true }))
    worker.blockedTargets.delete(key)
    return true
  } catch (error) {
    if (signal.aborted || error.fatal) throw error
    worker.blockedTargets.set(key, performance.now() + 30000)
    if (worker.blockedTargets.size > 128) worker.blockedTargets.delete(worker.blockedTargets.keys().next().value)
    record({ bot: bot.username, type: 'route-retry', target, position: bot.entity.position.clone(), reason: error.message })
    return false
  }
}

export function walkingDestination(bot, bounds, random, { distance = 8, heading } = {}) {
  for (let attempt = 0; attempt < 32; attempt++) {
    const angle = heading === undefined || attempt > 15 ? random() * Math.PI * 2 : heading + (random() - 0.5) * Math.PI
    const step = 2 + random() * Math.max(1, distance - 2)
    const x = Math.floor(bot.entity.position.x + Math.cos(angle) * step)
    const z = Math.floor(bot.entity.position.z + Math.sin(angle) * step)
    for (let y = Math.floor(bot.entity.position.y) + 1; y >= Math.floor(bot.entity.position.y) - 2; y--) {
      const destination = new Vec3(x, y, z)
      if (!containsWorker(bounds, destination.offset(0.5, 0, 0.5))) continue
      const floor = bot.blockAt(destination.offset(0, -1, 0))
      if (floor?.boundingBox !== 'block' || unsafeFloor.has(floor.name)) continue
      if (air.has(bot.blockAt(destination)?.name) && air.has(bot.blockAt(destination.offset(0, 1, 0))?.name)) return destination
    }
  }
  return undefined
}

async function moveWorker({ bot, worker, activity, random, bounds, signal, timeoutMs, record }) {
  if (worker.heading === undefined || random() < 0.1) worker.heading = random() * Math.PI * 2
  let failure
  for (let attempt = 0; attempt < 4; attempt++) {
    signal.throwIfAborted()
    const destination = walkingDestination(bot, bounds, random, {
      distance: activity === 'explore' ? Math.max(6, 32 - attempt * 8) : 8,
      heading: activity === 'explore' ? worker.heading : undefined
    })
    if (!destination) { worker.heading += Math.PI / 2; continue }
    const start = bot.entity.position.clone()
    let distance = 0
    let previous = start
    const track = () => {
      const next = bot.entity.position.clone()
      const delta = next.distanceTo(previous)
      if (delta < 3) distance += delta
      previous = next
    }
    bot.on('move', track)
    try {
      await bounded('Stress walking route', Math.max(1000, timeoutMs / 2), signal, (routeSignal) => walkTo(bot, destination, routeSignal))
      if (start.distanceTo(bot.entity.position) < 1) continue
      const chunk = `${Math.floor(destination.x / 16)},${Math.floor(destination.z / 16)}`
      const fresh = !worker.visited.has(chunk)
      worker.visited.add(chunk)
      if (worker.visited.size > 4096) worker.visited.delete(worker.visited.values().next().value)
      return { counts: { [activity]: 1 }, distance: Math.round(distance * 100) / 100, chunks: fresh ? 1 : 0, destination }
    } catch (error) {
      if (signal.aborted || error.fatal) throw error
      failure = error
      worker.heading += Math.PI / 2
      record({ bot: bot.username, type: 'route-retry', target: destination, reason: error.message })
    } finally {
      bot.removeListener('move', track)
    }
  }
  if (failure) throw failure
  return { status: 'skipped', reason: 'No loaded, reachable destination inside bounds' }
}

async function mineResource(context, position) {
  const { bot, controller, signal, timeoutMs, record } = context
  assertTargetBounds(bot, position)
  const initial = bot.blockAt(position)
  if (!initial || air.has(initial.name)) return { status: 'skipped', reason: 'Mining target is empty or unloaded' }
  if (['bedrock', 'water', 'lava'].includes(initial.name)) return { status: 'skipped', reason: 'Mining target cannot be harvested' }
  await walkTo(bot, position, signal, { near: true })
  await supplyItem(bot, controller, 'iron_pickaxe', 1, signal, timeoutMs, record)
  const block = bot.blockAt(position)
  if (!block || !bot.canDigBlock(block)) return { status: 'skipped', reason: 'Mining target is unreachable' }
  const tool = bot.pathfinder.bestHarvestTool(block)
  if (tool) await bot.equip(tool, 'hand')
  signal.throwIfAborted()
  const cancel = () => bot.stopDigging()
  signal.addEventListener('abort', cancel, { once: true })
  try {
    await serverBlockEdit(bot, position, (value) => air.has(value?.name), () => bot.dig(block), signal)
    await trimSurplus(bot, controller, 'cobblestone', 64, signal, timeoutMs, record)
    return { counts: { mine: 1 }, block: block.name, position }
  } finally {
    signal.removeEventListener('abort', cancel)
  }
}

async function buildResource(context, position) {
  const { bot, controller, signal, timeoutMs, record } = context
  assertTargetBounds(bot, position)
  if (!air.has(bot.blockAt(position)?.name)) return { status: 'skipped', reason: 'Building target is occupied or unloaded' }
  await walkTo(bot, position, signal, { near: true })
  if (Object.values(bot.entities).some((entity) => entity.name !== 'item' && entity.position && entity.position.distanceTo(position.offset(0.5, 0, 0.5)) < 1)) {
    return { status: 'skipped', reason: 'A player or entity occupies the building target' }
  }
  const reference = bot.blockAt(position.offset(0, -1, 0))
  if (reference?.boundingBox !== 'block') return { status: 'skipped', reason: 'Building target has no solid floor' }
  await supplyItem(bot, controller, 'stone', 32, signal, timeoutMs, record)
  await bot.equip(bot.inventory.items().find((item) => item.name === 'stone'), 'hand')
  signal.throwIfAborted()
  await serverBlockEdit(bot, position, (value) => value?.name === 'stone', () => bot.placeBlock(reference, farmFace), signal)
  return { counts: { build: 1 }, position, block: 'stone' }
}

async function farmCrop(context, position) {
  const { bot, controller, signal, timeoutMs, record } = context
  assertTargetBounds(bot, position)
  const initial = bot.blockAt(position)
  if (!initial || (!air.has(initial.name) && initial.name !== 'wheat')) return { status: 'skipped', reason: 'Farm target is not wheat' }
  const farmland = bot.blockAt(position.offset(0, -1, 0))
  if (farmland?.name !== 'farmland') return { status: 'skipped', reason: 'Farm target has no farmland' }
  await walkTo(bot, position, signal, { near: true })
  await supplyItem(bot, controller, 'wheat_seeds', 16, signal, timeoutMs, record)
  await supplyItem(bot, controller, 'bone_meal', 32, signal, timeoutMs, record)
  const plant = async () => {
    await bot.equip(bot.inventory.items().find((item) => item.name === 'wheat_seeds'), 'hand')
    signal.throwIfAborted()
    await serverBlockEdit(bot, position, (value) => value?.name === 'wheat', () => bot.placeBlock(farmland, farmFace), signal)
    record({ bot: bot.username, type: 'operation', action: 'plant', status: 'passed', position })
  }
  if (air.has(bot.blockAt(position)?.name)) await plant()
  for (let attempt = 0; attempt < 8 && Number(bot.blockAt(position)?.getProperties().age) < 7; attempt++) {
    const crop = bot.blockAt(position)
    const before = Number(crop.getProperties().age)
    await bot.equip(bot.inventory.items().find((item) => item.name === 'bone_meal'), 'hand')
    signal.throwIfAborted()
    await serverBlockEdit(bot, position, (value) => Number(value?.getProperties().age) > before, () => bot.activateBlock(crop), signal)
  }
  const mature = bot.blockAt(position)
  if (Number(mature?.getProperties().age) !== 7) throw new Error('Wheat did not reach maturity')
  const cancel = () => bot.stopDigging()
  signal.addEventListener('abort', cancel, { once: true })
  try {
    await serverBlockEdit(bot, position, (value) => air.has(value?.name), () => bot.dig(mature), signal)
  } finally {
    signal.removeEventListener('abort', cancel)
  }
  record({ bot: bot.username, type: 'operation', action: 'harvest', status: 'passed', position })
  await plant()
  for (const name of ['wheat', 'wheat_seeds']) await trimSurplus(bot, controller, name, 32, signal, timeoutMs, record)
  return { counts: { farm: 1 }, position }
}
