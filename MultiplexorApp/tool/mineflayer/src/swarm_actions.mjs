import { Vec3 } from 'vec3'
import pathfinder from 'mineflayer-pathfinder'
import { assertTargetBounds, assertWorkerBounds } from './swarm_world_bounds.mjs'

const { goals } = pathfinder

const commandQueues = new WeakMap()
const observerQueues = new WeakMap()

export function point(value) {
  return new Vec3(value.x ?? value[0], value.y ?? value[1], value.z ?? value[2])
}

export function seededRandom(seed) {
  let state = seed >>> 0
  return () => {
    state += 0x6D2B79F5
    let value = state
    value = Math.imul(value ^ value >>> 15, value | 1)
    value ^= value + Math.imul(value ^ value >>> 7, value | 61)
    return ((value ^ value >>> 14) >>> 0) / 4294967296
  }
}

export function pause(milliseconds, signal) {
  signal?.throwIfAborted()
  return new Promise((resolve, reject) => {
    const cancel = () => { clearTimeout(timer); reject(signal.reason) }
    const timer = setTimeout(() => {
      signal?.removeEventListener('abort', cancel)
      resolve()
    }, milliseconds)
    signal?.addEventListener('abort', cancel, { once: true })
  })
}

export async function until(predicate, signal, label) {
  while (true) {
    signal?.throwIfAborted()
    const value = predicate()
    if (value) return value
    await pause(40, signal)
  }
}

export async function bounded(label, timeoutMs, parent, action) {
  const controller = new AbortController()
  const cancel = () => controller.abort(parent.reason)
  parent?.throwIfAborted()
  parent?.addEventListener('abort', cancel, { once: true })
  const timer = setTimeout(() => controller.abort(new Error(`${label} timed out after ${timeoutMs}ms`)), timeoutMs)
  let onAbort
  try {
    return await Promise.race([
      Promise.resolve().then(() => action(controller.signal)),
      new Promise((resolve, reject) => {
        onAbort = () => reject(controller.signal.reason)
        controller.signal.addEventListener('abort', onAbort, { once: true })
      })
    ])
  } finally {
    clearTimeout(timer)
    parent?.removeEventListener('abort', cancel)
    controller.signal.removeEventListener('abort', onAbort)
  }
}

export function queueFor(registry, key, action) {
  const previous = registry.get(key) ?? Promise.resolve()
  const result = previous.catch(() => {}).then(action)
  registry.set(key, result.catch(() => {}))
  return result
}

export function controllerCommand(controller, command, signal, timeoutMs = 15000) {
  signal.throwIfAborted()
  const queued = queueFor(commandQueues, controller, () => bounded(`Command ${command.split(' ')[0]}`, timeoutMs, signal, async (current) => {
    await pause(110, current)
    return new Promise((resolve, reject) => {
      const cleanup = () => {
        controller.removeListener('messagestr', received)
        current.removeEventListener('abort', cancel)
      }
      const cancel = () => { cleanup(); reject(current.reason) }
      const received = (text) => {
        if (/Unknown|Incorrect|Invalid|No entity|No player|Cannot|Unable|outside of the world|not loaded|not enough|does not exist|No blocks were/i.test(text)) {
          cleanup()
          // Reapplying an existing fixture produces this response without changing the result.
          if (/No blocks were/i.test(text)) resolve(text)
          else reject(new Error(`Setup command failed: ${text}`))
        } else if (/Successfully|Filled|Changed|Teleported|Gave|Set |Removed \d+|already|Nothing changed/i.test(text)) {
          cleanup()
          resolve(text)
        }
      }
      controller.on('messagestr', received)
      current.addEventListener('abort', cancel, { once: true })
      controller.chat(command)
    })
  }))
  return new Promise((resolve, reject) => {
    const cancel = () => reject(signal.reason)
    signal.addEventListener('abort', cancel, { once: true })
    queued.then(resolve, reject).finally(() => signal.removeEventListener('abort', cancel))
  })
}

export function sendChat(bot, observer, message, signal) {
  signal.throwIfAborted()
  return new Promise((resolve, reject) => {
    const cleanup = () => {
      observer.removeListener('messagestr', received)
      signal.removeEventListener('abort', cancel)
    }
    const cancel = () => { cleanup(); reject(signal.reason) }
    const received = (text) => {
      if (text.includes(message) && text.includes(bot.username)) {
        cleanup()
        resolve()
      }
    }
    observer.on('messagestr', received)
    signal.addEventListener('abort', cancel, { once: true })
    bot.chat(message)
  })
}

export async function walkTo(bot, destination, signal, { near = false } = {}) {
  const position = point(destination)
  signal.throwIfAborted()
  assertWorkerBounds(bot)
  assertTargetBounds(bot, position, { walking: !near })
  const goal = near
    ? new goals.GoalNear(position.x, position.y, position.z, 2)
    : new goals.GoalBlock(Math.floor(position.x), Math.floor(position.y), Math.floor(position.z))
  const cancel = () => {
    if (bot.pathfinder.goal === goal) {
      bot.pathfinder.setGoal(null)
      bot.clearControlStates()
    }
  }
  signal.addEventListener('abort', cancel, { once: true })
  try {
    await bot.pathfinder.goto(goal)
    signal.throwIfAborted()
    assertWorkerBounds(bot)
    if (!bot.entity || bot.entity.position.distanceTo(position.offset(0.5, 0, 0.5)) > (near ? 3.6 : 1.2)) {
      throw new Error(`Walking did not reach ${position}`)
    }
  } finally {
    signal.removeEventListener('abort', cancel)
    cancel()
  }
}

export async function interact(bot, target, signal, observer = bot, lamp) {
  const position = point(target)
  assertTargetBounds(bot, position)
  await walkTo(bot, position, signal, { near: true })
  const initial = bot.blockAt(position)
  if (!initial) throw new Error(`Interaction target is not loaded: ${position}`)
  const props = initial.getProperties()
  if (!('powered' in props) && !('open' in props)) {
    throw new Error(`No observable interaction state for ${initial.name}`)
  }
  bot.setControlState('sneak', false)
  await bot.unequip('hand')
  if (initial.name.endsWith('pressure_plate')) {
    const off = position.offset(1, 0, 0)
    await walkTo(bot, off, signal)
    await until(() => observer.blockAt(position)?.getProperties().powered === false, signal, 'plate off')
    await walkTo(bot, position, signal)
    await until(() => observer.blockAt(position)?.getProperties().powered === true, signal, 'plate on')
    if (lamp) await until(() => observer.blockAt(point(lamp))?.getProperties().lit === true, signal, 'lamp on')
    await walkTo(bot, off, signal)
    await until(() => observer.blockAt(position)?.getProperties().powered === false, signal, 'plate released')
    if (lamp) await until(() => observer.blockAt(point(lamp))?.getProperties().lit === false, signal, 'lamp off')
    return { block: initial.name, transition: 'off/on/off' }
  }
  const property = 'powered' in props ? 'powered' : 'open'
  const before = props[property]
  await bot.activateBlock(initial)
  await until(() => observer.blockAt(position)?.getProperties()[property] === !before, signal, 'interaction acknowledgement')
  if (lamp) await until(() => observer.blockAt(point(lamp))?.getProperties().lit === !before, signal, 'lamp transition')
  if (initial.name.endsWith('button')) {
    await until(() => observer.blockAt(position)?.getProperties().powered === false, signal, 'button released')
    if (lamp) await until(() => observer.blockAt(point(lamp))?.getProperties().lit === false, signal, 'lamp off')
  }
  return { block: initial.name, property, before, after: !before }
}

export function observedEdit({ bot, observer, position, signal, timeoutMs, action }) {
  if (!observer || observer === bot) throw new Error('Mining and building require a separate observer')
  return queueFor(observerQueues, observer, async () => {
    signal.throwIfAborted()
    if (!observer.blockAt(position)) {
      await controllerCommand(observer, `/tp @s ${position.x + 2.5} ${position.y + 3} ${position.z + 2.5}`, signal, timeoutMs)
      await until(() => observer.blockAt(position), signal, 'observer chunk load')
    }
    return action(observer)
  })
}

export async function mineBlock({ bot, observer, position, signal, timeoutMs }) {
  position = point(position)
  await walkTo(bot, position, signal, { near: true })
  return observedEdit({ bot, observer, position, signal, timeoutMs, action: async (witness) => {
    const block = bot.blockAt(position)
    if (!block || block.boundingBox === 'empty' || !bot.canDigBlock(block)) {
      throw new Error(`Cannot mine target at ${position}`)
    }
    const tool = bot.pathfinder.bestHarvestTool(block)
    if (tool) await bot.equip(tool, 'hand')
    const cancel = () => { bot.stopDigging(); bot.clearControlStates() }
    signal.addEventListener('abort', cancel, { once: true })
    try {
      await bot.dig(block)
      await until(() => witness.blockAt(position)?.name === 'air', signal, 'server mining acknowledgement')
      return { block: block.name, position }
    } finally {
      signal.removeEventListener('abort', cancel)
    }
  } })
}

export async function buildBlock({ bot, observer, position, blockName, signal, timeoutMs }) {
  position = point(position)
  await walkTo(bot, position, signal, { near: true })
  return observedEdit({ bot, observer, position, signal, timeoutMs, action: async (witness) => {
    const existing = bot.blockAt(position)
    if (!existing || !['air', 'cave_air', 'void_air'].includes(existing.name)) {
      throw new Error(`Building target is occupied or unloaded: ${position}`)
    }
    const item = bot.inventory.items().find((item) => item.name === blockName)
    if (!item) throw new Error(`${bot.username} has no ${blockName} to build with`)
    const offsets = [new Vec3(0, -1, 0), new Vec3(1, 0, 0), new Vec3(-1, 0, 0), new Vec3(0, 0, 1), new Vec3(0, 0, -1)]
    const reference = offsets.map((offset) => ({ offset, block: bot.blockAt(position.plus(offset)) }))
      .find(({ block }) => block?.boundingBox === 'block')
    if (!reference) throw new Error(`Building target needs a solid neighbor: ${position}`)
    await bot.equip(item, 'hand')
    await bot.placeBlock(reference.block, reference.offset.scaled(-1))
    await until(() => witness.blockAt(position)?.name === blockName, signal, 'server placement acknowledgement')
    return { block: blockName, position }
  } })
}
