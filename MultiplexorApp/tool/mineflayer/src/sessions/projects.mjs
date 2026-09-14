import { point } from '../swarm_actions.mjs'

export function shelterBlueprint(plot) {
  const [x, y, z] = plot.origin
  const blocks = []
  for (let dx = 0; dx < 5; dx++) for (let dz = 0; dz < 5; dz++) blocks.push({ position: [x + dx, y, z + dz], block: 'cobblestone' })
  for (let dy = 1; dy <= 2; dy++) {
    for (const [dx, dz] of [[0, 0], [4, 0], [0, 4], [4, 4]]) blocks.push({ position: [x + dx, y + dy, z + dz], block: 'oak_planks' })
  }
  // Roof rings grow from supported corners toward the middle.
  const roof = []
  for (let dx = 0; dx < 5; dx++) for (let dz = 0; dz < 5; dz++) roof.push({ position: [x + dx, y + 3, z + dz], block: 'oak_planks' })
  roof.sort((left, right) => {
    const rank = ({ position: [px, , pz] }) => Math.min(px - x, x + 4 - px) + Math.min(pz - z, z + 4 - pz)
    return rank(left) - rank(right)
  })
  return [...blocks, ...roof]
}

export function initializeProjects(shared, world) {
  shared.world ??= {}
  shared.world.projects ??= {}
  for (const plot of world.buildPlots) {
    shared.world.projects[plot.id] ??= { id: plot.id, verified: {}, completed: false, verifiedAt: null }
  }
  shared.world.storage ??= { items: {}, observedAt: null, emptySlots: 0, partialCapacity: {} }
  shared.world.resourceTransfers ??= 0
  shared.world.foodCrafted ??= 0
  return shared.world
}

export function inspectProject(bot, plot, state, now = Date.now()) {
  const blueprint = shelterBlueprint(plot)
  const missing = []
  let unloaded = 0
  for (const target of blueprint) {
    const key = target.position.join(',')
    const observed = bot.blockAt(point(target.position))
    if (!observed) { unloaded++; continue }
    if (observed.name === target.block) state.verified[key] = target.block
    else { delete state.verified[key]; missing.push({ ...target, occupied: !['air', 'cave_air', 'void_air'].includes(observed.name) }) }
  }
  const completed = unloaded === 0 && missing.length === 0
  if (unloaded === 0 || missing.length > 0) state.completed = completed
  if (unloaded === 0) state.verifiedAt = now
  return {
    id: plot.id, total: blueprint.length, verified: Object.keys(state.verified).length,
    missing: missing.length, unloaded, completed,
    next: missing.find((target) => !target.occupied &&
      [[0, -1, 0], [1, 0, 0], [-1, 0, 0], [0, 0, 1], [0, 0, -1]].some((offset) =>
        bot.blockAt(point(target.position).offset(...offset))?.boundingBox === 'block')) ?? null,
    blocked: missing.filter((target) => target.occupied).length
  }
}

export function projectMaterials(world) {
  const materials = {}
  for (const plot of world.buildPlots) for (const target of shelterBlueprint(plot)) materials[target.block] = (materials[target.block] ?? 0) + 1
  return materials
}

export function projectSummary(shared, world) {
  const projects = world.buildPlots.map((plot) => {
    const state = shared.world.projects[plot.id]
    return { id: plot.id, completed: state.completed, verifiedAt: state.verifiedAt, blocksVerified: Object.keys(state.verified).length, blocksTotal: shelterBlueprint(plot).length }
  })
  return {
    projectsCompleted: projects.filter((project) => project.completed).length,
    projectsTotal: projects.length, blocksVerified: projects.reduce((total, project) => total + project.blocksVerified, 0),
    resourceTransfers: shared.world.resourceTransfers, foodCrafted: shared.world.foodCrafted,
    goalsMet: projects.length > 0 && projects.every((project) => project.completed), projects
  }
}
