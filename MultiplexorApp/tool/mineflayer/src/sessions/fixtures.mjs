import { bounded, pause, point, until } from '../swarm_actions.mjs'

export const SETTLEMENT_STARTER_STOCK = Object.freeze([
  { item: 'wooden_pickaxe', count: 1 }, { item: 'wooden_pickaxe', count: 1 },
  { item: 'wooden_axe', count: 1 }, { item: 'wooden_axe', count: 1 },
  { item: 'bread', count: 32 }, { item: 'wheat_seeds', count: 32 },
  { item: 'oak_sapling', count: 16 }
])

export function settlementCommands(world) {
  if (world.setup.kind !== 'settlement') return []
  const [x, y, z] = world.setup.origin
  const xyz = (dx, dy, dz) => `${x + dx} ${y + dy} ${z + dz}`
  const commands = [
    '/defaultgamemode survival',
    `/fill ${xyz(0, -1, 0)} ${xyz(47, -1, 47)} grass_block`,
    `/fill ${xyz(0, 0, 0)} ${xyz(47, 7, 47)} air`,
    `/fill ${xyz(0, 8, 0)} ${xyz(47, 15, 47)} air`,
    `/setworldspawn ${world.home.join(' ')}`,
    `/setblock ${world.storage.join(' ')} chest[facing=south]`,
    `/setblock ${world.craftingTable.join(' ')} crafting_table`,
    `/setblock ${xyz(5, 0, 6)} torch`,
    `/setblock ${xyz(9, 0, 6)} torch`
  ]
  for (let slot = 0; slot < SETTLEMENT_STARTER_STOCK.length; slot++) {
    const supply = SETTLEMENT_STARTER_STOCK[slot]
    commands.push(`/item replace block ${world.storage.join(' ')} container.${slot} with ${supply.item} ${supply.count}`)
  }
  for (const area of world.resourceAreas) {
    const step = area.kind === 'mine' ? 1 : 2
    for (let px = area.min[0]; px <= area.max[0]; px += step) for (let pz = area.min[2]; pz <= area.max[2]; pz += step) {
      commands.push(`/setblock ${px} ${y} ${pz} ${area.kind === 'mine' ? 'stone' : 'oak_log'}`)
    }
  }
  for (const area of world.farmAreas) {
    commands.push(`/fill ${area.min[0]} ${y - 1} ${area.min[2]} ${area.max[0]} ${y - 1} ${area.max[2]} farmland[moisture=7]`)
    commands.push(`/fill ${area.min.join(' ')} ${area.max.join(' ')} wheat[age=7]`)
    const middle = [Math.floor((area.min[0] + area.max[0]) / 2), y - 1, Math.floor((area.min[2] + area.max[2]) / 2)]
    commands.push(`/setblock ${middle.join(' ')} water`)
    commands.push(`/setblock ${middle[0]} ${y} ${middle[2]} air`)
    commands.push(`/setblock ${middle[0]} ${y + 1} ${middle[2]} sea_lantern`)
  }
  for (const station of world.redstone) {
    commands.push(`/setblock ${station.lamp.join(' ')} redstone_lamp`)
    commands.push(`/setblock ${station.control.join(' ')} lever[face=floor,facing=north,powered=false]`)
    if (station.piston) commands.push(`/setblock ${station.piston.join(' ')} piston[facing=up,extended=false]`)
  }
  return commands
}

export async function fixtureCommand(controller, text, signal) {
  return bounded(`Fixture command ${text.split(' ')[0]}`, 15000, signal, async (current) => {
    await pause(110, current)
    return new Promise((resolve, reject) => {
      const cleanup = () => { controller.removeListener('messagestr', received); current.removeEventListener('abort', cancel) }
      const cancel = () => { cleanup(); reject(current.reason) }
      const received = (message) => {
        if (/Unknown|Incorrect|Invalid|No entity|No player|Cannot|Unable|outside of the world|not loaded|not enough|does not exist/i.test(message)) {
          cleanup(); reject(new Error(`Fixture command failed: ${message}`))
        } else if (/Successfully|Filled|Changed|Teleported|Replaced|Set |already|Nothing changed|No blocks were|default game mode/i.test(message)) {
          cleanup(); resolve(message)
        }
      }
      controller.on('messagestr', received)
      current.addEventListener('abort', cancel, { once: true })
      controller.chat(text)
    })
  })
}

export async function prepareSessionWorld({ world, shared, controller, command, signal, record, checkpoint }) {
  if (shared.world.prepared) return { status: 'existing', setupCommands: shared.world.setupCommands ?? 0 }
  if (shared.world.preparing) throw new Error('Settlement setup was interrupted. Inspect or restore the world before starting a new run; setup is never replayed on resume')
  if (world.setup.kind === 'existing') {
    shared.world.prepared = true
    await checkpoint()
    return { status: 'existing', setupCommands: 0 }
  }
  if (!controller && !command) throw new Error('Settlement setup needs a temporary setup controller')
  shared.world.preparing = true
  await checkpoint()
  let completed = 0
  const send = async (text) => {
    signal.throwIfAborted()
    if (command) await command(text, signal)
    else await fixtureCommand(controller, text, signal)
    completed++
    record({ type: 'setup', operation: text.split(' ')[0].slice(1), command: text })
  }
  await send('/gamemode spectator @s')
  await send(`/tp @s ${world.setup.origin[0] + 24.5} ${world.setup.origin[1] + 20} ${world.setup.origin[2] + 24.5}`)
  if (controller) await bounded('Settlement chunks', 15000, signal, (current) => until(() =>
    controller.blockAt(point(world.bounds.min)) && controller.blockAt(point(world.bounds.max)), current, 'Setup chunks loaded'))
  for (const text of settlementCommands(world)) {
    await send(text)
  }
  shared.world.preparing = false
  shared.world.prepared = true
  shared.world.setupCommands = completed
  shared.world.starterStock = SETTLEMENT_STARTER_STOCK.map((supply) => ({ ...supply }))
  await checkpoint()
  return { status: 'prepared', setupCommands: completed, starterStock: shared.world.starterStock }
}
