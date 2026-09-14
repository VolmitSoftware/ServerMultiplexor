import { Vec3 } from 'vec3'
import { bounded, buildBlock, controllerCommand, interact, mineBlock, pause, seededRandom, sendChat, until, walkTo } from './swarm_actions.mjs'

export const SWARM_PROFILES = Object.freeze([
  { name: 'idle', description: 'Stay connected with normal client physics.', requiresArena: false },
  { name: 'wander', description: 'Walk to seeded nearby destinations with varied pauses.', requiresArena: false },
  { name: 'redstone', description: 'Operate levers, buttons, and pressure plates; verify their states.', requiresArena: false },
  { name: 'workshop', description: 'Place and mine blocks in separate work areas.', requiresArena: true },
  { name: 'mixed', description: 'Coordinate walking, redstone, building, mining, and optional chat.', requiresArena: true },
  { name: 'stress', description: 'Run sustained weighted player roles inside bounds with activity goals, load schedules, and checkpoints.', requiresArena: false }
])

export class SwarmCoordinator {
  #claims = new Set()
  async claim(position, action) {
    const key = `${position.x},${position.y},${position.z}`
    if (this.#claims.has(key)) return { skipped: true }
    this.#claims.add(key)
    try { return await action() } finally { this.#claims.delete(key) }
  }
}

export function arenaLayout(origin, count) {
  const width = Math.ceil(Math.sqrt(count))
  return Array.from({ length: count }, (_, index) => {
    const base = new Vec3(origin.x + (index % width) * 12, origin.y, origin.z + Math.floor(index / width) * 12)
    return {
      base,
      spawn: base.offset(6, 1, 6),
      lever: base.offset(3, 2, 3),
      leverLamp: base.offset(3, 1, 3),
      button: base.offset(8, 2, 3),
      buttonLamp: base.offset(8, 1, 3),
      plate: base.offset(3, 1, 8),
      plateLamp: base.offset(3, 0, 8),
      building: base.offset(8, 1, 8),
      walking: [base.offset(2, 1, 5), base.offset(9, 1, 5), base.offset(6, 1, 9), base.offset(6, 1, 2)]
    }
  })
}

function xyz(position) { return `${position.x} ${position.y} ${position.z}` }

export async function prepareSwarmArena({ controller, bots, origin, signal, actionTimeoutMs, record }) {
  const tiles = arenaLayout(origin, bots.length)
  await controllerCommand(controller, '/gamemode spectator @s', signal, actionTimeoutMs)
  for (let index = 0; index < bots.length; index++) {
    const tile = tiles[index]
    const bot = bots[index]
    await bounded('Load arena chunks', actionTimeoutMs, signal, async (current) => {
      await controllerCommand(controller, `/tp @s ${xyz(tile.base.offset(6, 6, 6))}`, current, actionTimeoutMs)
      await until(() => controller.blockAt(tile.base), current, 'arena terrain')
    })
    const commands = [
      `/fill ${xyz(tile.base)} ${xyz(tile.base.offset(11, 0, 11))} stone`,
      `/fill ${xyz(tile.base.offset(0, 1, 0))} ${xyz(tile.base.offset(11, 5, 11))} air`,
      `/setblock ${xyz(tile.leverLamp)} redstone_lamp`,
      `/setblock ${xyz(tile.lever)} lever[face=floor,facing=north,powered=false]`,
      `/setblock ${xyz(tile.buttonLamp)} redstone_lamp`,
      `/setblock ${xyz(tile.button)} stone_button[face=floor,facing=north,powered=false]`,
      `/setblock ${xyz(tile.plateLamp)} redstone_lamp`,
      `/setblock ${xyz(tile.plate)} stone_pressure_plate[powered=false]`,
      `/give ${bot.username} stone 64`,
      `/give ${bot.username} iron_pickaxe`,
      `/give ${bot.username} cooked_beef 16`,
      `/tp ${bot.username} ${xyz(tile.spawn.offset(0.5, 0, 0.5))}`
    ]
    if (bot.game.gameMode !== 'survival') {
      await controllerCommand(controller, `/gamemode survival ${bot.username}`, signal, actionTimeoutMs)
    }
    for (const command of commands) await controllerCommand(controller, command, signal, actionTimeoutMs)
    await bounded('Worker arena arrival', actionTimeoutMs, signal, (current) => until(
      () => bot.entity.position.distanceTo(tile.spawn.offset(0.5, 0, 0.5)) < 2 && bot.blockAt(tile.lever)?.name === 'lever',
      current,
      'worker arena chunks'
    ))
    record({ bot: bot.username, index, action: 'arena', status: 'passed', origin: tile.base })
  }
  return { origin, tiles }
}

export function scatterPositions(count, origin, radius) {
  const columns = Math.ceil(Math.sqrt(count))
  const rows = Math.ceil(count / columns)
  return Array.from({ length: count }, (_, index) => {
    const row = Math.floor(index / columns)
    const rowCount = Math.min(columns, count - row * columns)
    return new Vec3(
      Math.round(origin.x + ((index % columns + 0.5) / rowCount * 2 - 1) * radius),
      origin.y,
      Math.round(origin.z + ((row + 0.5) / rows * 2 - 1) * radius)
    )
  })
}

export async function scatterSwarm({ controller, bots, origin, radius, signal, actionTimeoutMs, record }) {
  const positions = scatterPositions(bots.length, origin, radius)
  await controllerCommand(controller, '/gamemode spectator @s', signal, actionTimeoutMs)
  for (let index = 0; index < bots.length; index++) {
    const bot = bots[index]
    const destination = positions[index]
    await bounded('Scatter worker', actionTimeoutMs * 2, signal, async (current) => {
      // Loading each column first makes heightmap placement work in unexplored terrain.
      await controllerCommand(controller, `/tp @s ${destination.x} ${origin.y} ${destination.z}`, current, actionTimeoutMs)
      await until(() => controller.blockAt(destination), current, 'scatter chunks')
      await controllerCommand(controller, `/execute positioned ${destination.x + 0.5} 0 ${destination.z + 0.5} positioned over motion_blocking run tp ${bot.username} ~ ~ ~`, current, actionTimeoutMs)
      await until(() => Math.abs(bot.entity.position.x - destination.x - 0.5) < 1 && Math.abs(bot.entity.position.z - destination.z - 0.5) < 1, current, 'scatter arrival')
      await until(() => {
        const below = bot.blockAt(bot.entity.position.offset(0, -0.1, 0))
        return below && !['air', 'cave_air', 'void_air'].includes(below.name)
      }, current, 'worker terrain')
      const floor = bot.blockAt(bot.entity.position.offset(0, -0.1, 0))
      if (['water', 'lava', 'air'].includes(floor.name)) throw new Error(`Scatter cell ${index + 1} has no safe standing surface; choose another origin/radius`)
      if (bot.blockAt(bot.entity.position)?.boundingBox === 'block' || bot.blockAt(bot.entity.position.offset(0, 1, 0))?.boundingBox === 'block') {
        throw new Error(`Scatter cell ${index + 1} has no standing room; choose another origin/radius`)
      }
    })
    record({ bot: bot.username, index, action: 'scatter', status: 'passed', position: bot.entity.position.clone() })
  }
  return positions
}

function naturalDestination(bot, center, radius, random) {
  for (let attempt = 0; attempt < 24; attempt++) {
    const angle = random() * Math.PI * 2
    const distance = 1.5 + random() * Math.min(2.5, radius - 1.5)
    const x = Math.floor(bot.entity.position.x + Math.cos(angle) * distance)
    const z = Math.floor(bot.entity.position.z + Math.sin(angle) * distance)
    if (Math.hypot(x + 0.5 - center.x, z + 0.5 - center.z) > radius) continue
    for (let y = Math.floor(bot.entity.position.y) + 1; y >= Math.floor(bot.entity.position.y) - 2; y--) {
      const destination = new Vec3(x, y, z)
      const floor = bot.blockAt(destination.offset(0, -1, 0))
      if (floor?.boundingBox !== 'block' || ['magma_block', 'campfire', 'soul_campfire', 'cactus'].includes(floor.name)) continue
      if (bot.blockAt(destination)?.name === 'air' && bot.blockAt(destination.offset(0, 1, 0))?.name === 'air') return destination
    }
  }
  throw new Error(`${bot.username} cannot find a safe walking destination within radius ${radius}`)
}

export async function runSwarmWorker({ bot, index, profile, arena, seed, radius, deadline, signal, record, actionTimeoutMs, observer, chat = false, coordinator = new SwarmCoordinator() }) {
  const random = seededRandom((seed + Math.imul(index + 1, 2654435761)) >>> 0)
  const tile = arena?.tiles[index]
  const center = bot.entity.position.clone()
  const activities = profile === 'mixed' ? ['walk', 'lever', 'button', 'plate', 'workshop']
    : profile === 'redstone' ? ['lever', 'button', 'plate']
      : [profile === 'wander' ? 'walk' : profile]
  let turn = index % activities.length
  let lastChat = -Infinity
  await pause(Math.floor(random() * 500), signal)
  while (performance.now() < deadline && !signal.aborted) {
    const action = activities[turn++ % activities.length]
    if (action === 'idle') {
      if (chat && performance.now() - lastChat >= 5000) {
        const message = `${bot.username}: at my assigned position and ready.`
        await bounded(`${bot.username} chat`, actionTimeoutMs, signal, (current) => sendChat(bot, observer ?? bot, message, current))
        record({ bot: bot.username, index, action: 'chat', status: 'passed', message })
        lastChat = performance.now()
      }
      await pause(Math.min(500, Math.max(1, deadline - performance.now())), signal)
      continue
    }
    await bounded(`${bot.username} ${action}`, actionTimeoutMs, signal, async (current) => {
      let details = {}
      if (action === 'walk') {
        let lastFailure
        for (let attempt = 0; attempt < (tile ? 1 : 5); attempt++) {
          current.throwIfAborted()
          const destination = tile ? tile.walking[Math.floor(random() * tile.walking.length)] : naturalDestination(bot, center, radius, random)
          record({ bot: bot.username, index, action: 'walk', status: 'started', target: destination, attempt: attempt + 1 })
          try {
            if (tile) await walkTo(bot, destination, current)
            else await bounded('Walking route', Math.min(3000, Math.floor(actionTimeoutMs / 6)), current, (routeSignal) => walkTo(bot, destination, routeSignal))
            lastFailure = undefined
            break
          } catch (error) {
            current.throwIfAborted()
            lastFailure = error
          }
        }
        if (lastFailure) {
          record({ bot: bot.username, index, action: 'walk', status: 'skipped', reason: `Five blocked routes: ${lastFailure.message}` })
          return
        }
        details = { position: bot.entity.position.clone() }
      } else if (action === 'workshop') {
        if (!tile) throw new Error('Workshop requires a demo arena')
        await buildBlock({ bot, observer, position: tile.building, blockName: 'stone', signal: current, timeoutMs: actionTimeoutMs })
        record({ bot: bot.username, index, action: 'build', status: 'passed', position: tile.building })
        await mineBlock({ bot, observer, position: tile.building, signal: current, timeoutMs: actionTimeoutMs })
        record({ bot: bot.username, index, action: 'mine', status: 'passed', position: tile.building })
      } else {
        const target = tile?.[action] ?? bot.findBlock({
          matching: (block) => block.name === 'lever' || block.name.endsWith('_button') || block.name.endsWith('_pressure_plate'),
          maxDistance: radius
        })?.position
        if (!target) throw new Error(`${bot.username} found no redstone input; use --build-arena or place inputs nearby`)
        details = await coordinator.claim(target, () => interact(bot, target, current, tile ? observer : bot, tile?.[`${action}Lamp`]))
        if (details.skipped) {
          record({ bot: bot.username, index, action, status: 'skipped', reason: 'another worker owns this input' })
          return
        }
      }
      if (action !== 'workshop') record({ bot: bot.username, index, action, status: 'passed', ...details })
      if (chat && performance.now() - lastChat >= 5000) {
        const message = `${bot.username}: finished ${action}; moving to the next job.`
        await sendChat(bot, observer ?? bot, message, current)
        record({ bot: bot.username, index, action: 'chat', status: 'passed', message })
        lastChat = performance.now()
      }
    })
    await pause(Math.min(500 + Math.floor(random() * 1400), Math.max(1, deadline - performance.now())), signal)
  }
}
