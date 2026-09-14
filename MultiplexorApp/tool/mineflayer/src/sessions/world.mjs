import { containsBlock, containsWorker, constrainWorker } from '../swarm_world_bounds.mjs'
import { walkTo } from '../swarm_actions.mjs'
import pathfinder from 'mineflayer-pathfinder'
import { preserveSearchNodes, stabilizeCollisionBounds } from './world_navigation.mjs'

const coordinateLimit = 29999984
const installedBounds = new WeakMap()
const cornerGuards = new WeakSet()

export function avoidCornerCutting(movements) {
  if (cornerGuards.has(movements)) return
  const original = movements.getMoveDiagonal
  movements.getMoveDiagonal = function (node, direction, neighbors) {
    // Pathfinder accepts one clear side of a diagonal, but the player's body can clip the other corner.
    for (const [dx, dz] of [[direction.x, 0], [0, direction.z]]) {
      if (!this.getBlock(node, dx, 0, dz).safe || !this.getBlock(node, dx, 1, dz).safe) return
    }
    return original.call(this, node, direction, neighbors)
  }
  cornerGuards.add(movements)
}

export async function sessionWalk(bot, target, signal, options) {
  const controller = new AbortController()
  const cancel = () => controller.abort(signal.reason)
  signal.throwIfAborted()
  signal.addEventListener('abort', cancel, { once: true })
  let lastPosition = bot.entity.position.clone()
  let lastProgress = Date.now()
  const started = lastProgress
  const timer = setInterval(() => {
    if (lastPosition.distanceTo(bot.entity.position) >= 0.5) {
      lastPosition = bot.entity.position.clone()
      lastProgress = Date.now()
    }
    if (Date.now() - lastProgress > 6000 || Date.now() - started > 25000) {
      controller.abort(new Error('Travel stopped making progress or exceeded its 25-second limit'))
    }
  }, 500)
  try { return await walkTo(bot, target, controller.signal, options) }
  finally { clearInterval(timer); signal.removeEventListener('abort', cancel) }
}

export async function travelToward(bot, destination, signal) {
  const position = { x: destination.x ?? destination[0], y: destination.y ?? destination[1], z: destination.z ?? destination[2] }
  const goal = new pathfinder.goals.GoalNear(position.x, position.y, position.z, 2)
  const result = bot.pathfinder.getPathTo(bot.pathfinder.movements, goal, 1000)
  if (!result.path.length) return { status: 'waiting', kind: 'travel', reason: 'No loaded walkable route toward the destination' }
  const waypoint = result.path[Math.min(result.path.length - 1, 19)]
  const origin = bot.entity.position.clone()
  await sessionWalk(bot, [Math.floor(waypoint.x), Math.floor(waypoint.y), Math.floor(waypoint.z)], signal)
  return { status: 'completed', kind: 'travel', metrics: { blocksWalked: origin.distanceTo(bot.entity.position) } }
}

export function defaultSettlementWorld() {
  return {
    id: 'settlement', backend: 'standalone', dimension: 'overworld',
    bounds: { min: [0, 79, 0], max: [47, 95, 47] },
    setup: { kind: 'settlement', origin: [0, 80, 0] },
    home: [24, 80, 24], storage: [6, 80, 6], craftingTable: [8, 80, 6], meetingPoint: [4, 80, 10],
    resourceAreas: [
      { id: 'quarry', kind: 'mine', min: [12, 80, 2], max: [25, 80, 7] },
      { id: 'grove', kind: 'wood', min: [12, 80, 12], max: [25, 93, 17] }
    ],
    farmAreas: [{ id: 'wheat', min: [2, 80, 18], max: [8, 80, 24] }],
    buildPlots: [
      { id: 'shelter-1', origin: [28, 80, 24], blueprint: 'shelter' },
      { id: 'shelter-2', origin: [36, 80, 24], blueprint: 'shelter' }
    ],
    protectedAreas: [{ id: 'stores', min: [5, 79, 5], max: [9, 81, 7] }],
    frontiers: [{ id: 'outskirts', min: [28, 80, 34], max: [44, 84, 44] }],
    redstone: [{ control: [4, 80, 32], lamp: [4, 79, 32], piston: [5, 79, 32], head: [5, 80, 32] }]
  }
}

function object(value, label, keys) {
  if (!value || typeof value !== 'object' || Array.isArray(value)) throw new Error(`${label} must be an object`)
  for (const key of Object.keys(value)) if (!keys.includes(key)) throw new Error(`Unknown ${label}.${key}`)
}

function position(value, label) {
  if (!Array.isArray(value) || value.length !== 3 || !value.every(Number.isSafeInteger) ||
      Math.abs(value[0]) > coordinateLimit || Math.abs(value[2]) > coordinateLimit || value[1] < -2048 || value[1] > 2048) {
    throw new Error(`${label} must contain three valid integer block coordinates`)
  }
  return [...value]
}

function box(value, label) {
  const min = position(value.min, `${label}.min`)
  const max = position(value.max, `${label}.max`)
  if (min.some((coordinate, axis) => coordinate > max[axis])) throw new Error(`${label} has reversed bounds`)
  return { min, max }
}

export function validateWorld(raw = defaultSettlementWorld()) {
  const value = structuredClone(raw)
  object(value, 'world', ['id', 'backend', 'dimension', 'bounds', 'setup', 'home', 'storage', 'craftingTable', 'meetingPoint', 'resourceAreas', 'farmAreas', 'buildPlots', 'protectedAreas', 'frontiers', 'redstone'])
  if (typeof value.id !== 'string' || !/^[A-Za-z0-9_.-]{1,64}$/.test(value.id)) throw new Error('world.id must name a world agenda')
  if (typeof value.backend !== 'string' || !/^[A-Za-z0-9_.-]{1,64}$/.test(value.backend)) throw new Error('world.backend must name a backend')
  if (!['overworld', 'the_nether', 'the_end'].includes(value.dimension)) throw new Error('world.dimension must be overworld, the_nether, or the_end')
  object(value.bounds, 'world.bounds', ['min', 'max'])
  value.bounds = box(value.bounds, 'world.bounds')
  object(value.setup, 'world.setup', ['kind', 'origin'])
  if (!['settlement', 'existing'].includes(value.setup.kind)) throw new Error('world.setup.kind must be settlement or existing')
  if (value.setup.kind === 'existing' && value.setup.origin !== undefined) throw new Error('Existing worlds do not use a setup origin')
  const within = (target, label) => {
    if (!containsBlock(value.bounds, target)) throw new Error(`${label} is outside world.bounds`)
    return target
  }
  for (const name of ['home', 'storage', 'craftingTable', 'meetingPoint']) {
    value[name] = within(position(value[name], `world.${name}`), `world.${name}`)
  }
  for (const name of ['resourceAreas', 'farmAreas', 'protectedAreas', 'frontiers']) {
    if (!Array.isArray(value[name]) || value[name].length > 64) throw new Error(`world.${name} must be an array with at most 64 regions`)
    const ids = new Set()
    value[name] = value[name].map((region, index) => {
      const label = `world.${name}[${index}]`
      object(region, label, name === 'resourceAreas' ? ['id', 'kind', 'min', 'max'] : ['id', 'min', 'max'])
      if (typeof region.id !== 'string' || !/^[A-Za-z0-9_-]{1,64}$/.test(region.id) || ids.has(region.id)) throw new Error(`${label}.id must be unique`)
      ids.add(region.id)
      if (name === 'resourceAreas' && !['mine', 'wood'].includes(region.kind)) throw new Error(`${label}.kind must be mine or wood`)
      const bounds = box(region, label)
      within(bounds.min, label); within(bounds.max, label)
      const volume = bounds.min.reduce((total, coordinate, axis) => total * (bounds.max[axis] - coordinate + 1), 1)
      if (['resourceAreas', 'farmAreas'].includes(name) && volume > 65536) throw new Error(`${label} exceeds 65536 searchable blocks`)
      return { ...region, ...bounds }
    })
    if (['resourceAreas', 'farmAreas'].includes(name) && value[name].reduce((sum, region) =>
      sum + region.min.reduce((volume, coordinate, axis) => volume * (region.max[axis] - coordinate + 1), 1), 0) > 65536) {
      throw new Error(`world.${name} exceeds 65536 total searchable blocks`)
    }
  }
  if (!Array.isArray(value.buildPlots) || value.buildPlots.length > 256) throw new Error('world.buildPlots must contain at most 256 plots')
  const plots = new Set()
  value.buildPlots = value.buildPlots.map((plot, index) => {
    const label = `world.buildPlots[${index}]`
    object(plot, label, ['id', 'origin', 'blueprint'])
    if (typeof plot.id !== 'string' || !/^[A-Za-z0-9_-]{1,64}$/.test(plot.id) || plots.has(plot.id)) throw new Error(`${label}.id must be unique`)
    plots.add(plot.id)
    if (plot.blueprint !== 'shelter') throw new Error(`${label}.blueprint must be shelter`)
    plot.origin = within(position(plot.origin, `${label}.origin`), label)
    within(plot.origin.map((n, axis) => n + [4, 3, 4][axis]), label)
    return plot
  })
  for (let index = 0; index < value.buildPlots.length; index++) {
    const plot = value.buildPlots[index]
    const volume = { min: plot.origin, max: plot.origin.map((coordinate, axis) => coordinate + [4, 3, 4][axis]) }
    const intersects = (region) => volume.min.every((coordinate, axis) => coordinate <= region.max[axis] && volume.max[axis] >= region.min[axis])
    if (value.protectedAreas.some(intersects) || value.resourceAreas.some(intersects) || value.farmAreas.some(intersects)) throw new Error(`Build plot ${plot.id} overlaps a protected or resource region`)
    for (const other of value.buildPlots.slice(0, index)) {
      if (intersects({ min: other.origin, max: other.origin.map((coordinate, axis) => coordinate + [4, 3, 4][axis]) })) throw new Error(`Build plot ${plot.id} overlaps ${other.id}`)
    }
  }
  if (!Array.isArray(value.redstone) || value.redstone.length > 64) throw new Error('world.redstone must contain at most 64 stations')
  for (const station of value.redstone) {
    object(station, 'world.redstone station', ['control', 'lamp', 'piston', 'head'])
    station.control = within(position(station.control, 'redstone.control'), 'redstone.control')
    station.lamp = within(position(station.lamp, 'redstone.lamp'), 'redstone.lamp')
    if (station.piston || station.head) {
      station.piston = within(position(station.piston, 'redstone.piston'), 'redstone.piston')
      station.head = within(position(station.head, 'redstone.head'), 'redstone.head')
    }
  }
  if (value.setup.kind === 'settlement') {
    if (value.dimension !== 'overworld') throw new Error('Settlement setup requires the overworld')
    value.setup.origin = position(value.setup.origin, 'world.setup.origin')
    const canonical = defaultSettlementWorld()
    const offset = value.setup.origin.map((coordinate, axis) => coordinate - canonical.setup.origin[axis])
    const shift = (target) => target.map((coordinate, axis) => coordinate + offset[axis])
    const expected = structuredClone(canonical)
    expected.id = value.id
    expected.backend = value.backend
    expected.setup.origin = value.setup.origin
    expected.bounds = { min: shift(canonical.bounds.min), max: shift(canonical.bounds.max) }
    for (const name of ['home', 'storage', 'craftingTable', 'meetingPoint']) expected[name] = shift(expected[name])
    for (const name of ['resourceAreas', 'farmAreas', 'protectedAreas', 'frontiers']) {
      for (const region of expected[name]) { region.min = shift(region.min); region.max = shift(region.max) }
    }
    for (const plot of expected.buildPlots) plot.origin = shift(plot.origin)
    for (const station of expected.redstone) for (const key of ['control', 'lamp', 'piston', 'head']) station[key] = shift(station[key])
    // Fixture geometry is fixed so setup cannot silently miss custom stations or erase unrelated regions.
    for (const key of Object.keys(expected)) {
      if (JSON.stringify(value[key]) !== JSON.stringify(expected[key])) throw new Error(`Settlement setup requires the standard ${key}; use setup.kind=existing for custom worlds`)
    }
  }
  return value
}

export function normalizeDimension(value) { return String(value).replace(/^minecraft:/, '') }

export function assertWorld(bot, world, backend) {
  preserveSearchNodes()
  stabilizeCollisionBounds(bot)
  if (backend !== world.backend) throw new Error(`World action belongs to backend ${world.backend}, received ${backend}`)
  if (normalizeDimension(bot.game?.dimension) !== world.dimension) throw new Error(`World action requires dimension ${world.dimension}`)
  if (bot.game?.gameMode && bot.game.gameMode !== 'survival') throw new Error(`${bot.username} must be in survival mode for session workloads`)
  if (!containsWorker(world.bounds, bot.entity?.position)) throw new Error(`${bot.username} is outside the configured world bounds`)
  const minY = bot.game?.minY
  const height = bot.game?.height
  if (Number.isFinite(minY) && Number.isFinite(height) && (world.bounds.min[1] < minY || world.bounds.max[1] >= minY + height)) {
    throw new Error('Configured bounds exceed this dimension\'s height')
  }
  const installed = installedBounds.get(bot)
  if (installed?.world !== world) {
    const movements = bot.pathfinder.movements
    const original = installed?.original ?? {
      step: [...movements.exclusionAreasStep], break: [...movements.exclusionAreasBreak], place: [...movements.exclusionAreasPlace]
    }
    movements.exclusionAreasStep = [...original.step]
    movements.exclusionAreasBreak = [...original.break]
    movements.exclusionAreasPlace = [...original.place]
    avoidCornerCutting(movements)
    constrainWorker(bot, world.bounds)
    installedBounds.set(bot, { world, original })
  }
}

export function editable(world, position, activity) {
  if (!containsBlock(world.bounds, position) || world.protectedAreas.some((region) => containsBlock(region, position))) return false
  if (activity === 'farm') return world.farmAreas.some((region) => containsBlock(region, position))
  if (activity === 'mine' || activity === 'wood') return world.resourceAreas.some((region) => region.kind === activity && containsBlock(region, position))
  if (activity === 'build') return world.buildPlots.some((plot) => containsBlock({ min: plot.origin, max: plot.origin.map((coordinate, axis) => coordinate + [4, 3, 4][axis]) }, position))
  return false
}

export function regionPositions(regions, maximum = 65536) {
  const result = []
  for (const region of regions) for (let y = region.min[1]; y <= region.max[1]; y++) {
    for (let x = region.min[0]; x <= region.max[0]; x++) for (let z = region.min[2]; z <= region.max[2]; z++) {
      if (result.length >= maximum) return result
      result.push([x, y, z])
    }
  }
  return result
}

export function recordChunkVisit(intent, backend, dimension, position, limit = 2048) {
  intent.chunkVisits ??= []
  const key = `${backend}:${dimension}:${Math.floor(position.x / 16)},${Math.floor(position.z / 16)}`
  if (intent.chunkVisits.includes(key)) return false
  if (intent.chunkVisits.length >= limit) { intent.chunkTrackingFull = true; return false }
  intent.chunkVisits.push(key)
  if (intent.chunkVisits.length === limit) intent.chunkTrackingFull = true
  return true
}
