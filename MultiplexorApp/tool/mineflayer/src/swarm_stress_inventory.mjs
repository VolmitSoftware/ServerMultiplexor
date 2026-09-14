import { Vec3 } from 'vec3'
import { controllerCommand, until, walkTo } from './swarm_actions.mjs'
import { assertTargetBounds } from './swarm_world_bounds.mjs'

export function itemCount(bot, name) {
  return bot.inventory.items().filter((item) => item.name === name).reduce((count, item) => count + item.count, 0)
}

export async function supplyItem(bot, controller, name, count, signal, timeoutMs, record) {
  signal.throwIfAborted()
  const before = itemCount(bot, name)
  if (before >= Math.max(1, Math.floor(count / 4))) return
  await controllerCommand(controller, `/give ${bot.username} ${name} ${count - before}`, signal, timeoutMs)
  await until(() => itemCount(bot, name) >= count, signal, 'supply inventory acknowledgement')
  record({ bot: bot.username, type: 'support', operation: 'supply', item: name, count: count - before })
}

export async function trimSurplus(bot, controller, name, retain, signal, timeoutMs, record) {
  const before = itemCount(bot, name)
  if (before <= retain + 64) return
  await controllerCommand(controller, `/clear ${bot.username} ${name} ${before - retain}`, signal, timeoutMs)
  await until(() => itemCount(bot, name) <= retain, signal, 'surplus inventory acknowledgement')
  record({ bot: bot.username, type: 'support', operation: 'remove-surplus', item: name, count: before - retain })
}

async function inventoryOperation(bot, signal, operation) {
  signal.throwIfAborted()
  const cancel = () => {
    bot.deactivateItem()
    if (bot.currentWindow) bot.closeWindow(bot.currentWindow)
  }
  signal.addEventListener('abort', cancel, { once: true })
  try {
    const result = await operation()
    signal.throwIfAborted()
    return result
  } catch (error) {
    // A pending inventory transaction must not overlap a retry on the same client.
    if (signal.reason?.constructor?.name !== 'RunComplete') error.fatal = true
    throw error
  } finally {
    signal.removeEventListener('abort', cancel)
  }
}

export async function maintainFood(context) {
  const { bot, controller, signal, timeoutMs, record } = context
  if (bot.food > 16) return
  await supplyItem(bot, controller, 'cooked_beef', 16, signal, timeoutMs, record)
  const food = bot.inventory.items().find((item) => item.name === 'cooked_beef')
  const before = bot.food
  await inventoryOperation(bot, signal, async () => {
    await bot.equip(food, 'hand')
    signal.throwIfAborted()
    await bot.consume()
    await until(() => bot.food > before, signal, 'food acknowledgement')
  })
  record({ bot: bot.username, type: 'maintenance', action: 'eat', status: 'passed', foodBefore: before, foodAfter: bot.food })
}

export async function craftItems(context) {
  const { bot, controller, signal, timeoutMs, record, targets, turn } = context
  const position = targets[0]
  if (position) {
    assertTargetBounds(bot, position)
    await walkTo(bot, position, signal, { near: true })
  }
  await supplyItem(bot, controller, 'oak_log', 16, signal, timeoutMs, record)
  const resultName = turn % 2 === 0 || itemCount(bot, 'oak_planks') < 2 ? 'oak_planks' : 'stick'
  await trimSurplus(bot, controller, resultName, 32, signal, timeoutMs, record)
  const item = bot.registry.itemsByName[resultName]
  const table = position ? bot.blockAt(position) : null
  const recipe = bot.recipesFor(item.id, null, 1, table).find((candidate) => candidate.result.count > 0)
  if (!recipe) throw new Error(`No available recipe for ${resultName}`)
  const before = itemCount(bot, resultName)
  await inventoryOperation(bot, signal, async () => {
    await bot.craft(recipe, 1, table)
    await until(() => itemCount(bot, resultName) >= before + recipe.result.count, signal, 'craft result')
  })
  record({ bot: bot.username, type: 'operation', action: 'craft-item', status: 'passed', item: resultName, count: recipe.result.count })
  return { counts: { craft: 1 }, item: resultName, count: recipe.result.count }
}

export async function transferStorage(context, position) {
  const { bot, controller, signal, timeoutMs, record } = context
  assertTargetBounds(bot, position)
  await walkTo(bot, position, signal, { near: true })
  const block = bot.blockAt(position)
  if (!block || !['chest', 'trapped_chest', 'barrel'].includes(block.name)) {
    return { status: 'skipped', reason: 'Storage target is not a loaded chest or barrel' }
  }
  await supplyItem(bot, controller, 'cobblestone', 32, signal, timeoutMs, record)
  const itemType = bot.registry.itemsByName.cobblestone.id
  const before = itemCount(bot, 'cobblestone')
  let window
  await inventoryOperation(bot, signal, async () => {
    try {
      window = await bot.openContainer(block)
      signal.throwIfAborted()
      const containerCount = () => window.containerItems().filter((item) => item.type === itemType).reduce((total, item) => total + item.count, 0)
      const carriedCount = () => window.items().filter((item) => item.type === itemType).reduce((total, item) => total + item.count, 0)
      const stored = containerCount()
      await window.deposit(itemType, null, 8)
      await until(() => containerCount() === stored + 8 && carriedCount() === before - 8, signal, 'chest deposit')
      record({ bot: bot.username, type: 'operation', action: 'deposit', status: 'passed', count: 8, position })
      signal.throwIfAborted()
      await window.withdraw(itemType, null, 8)
      await until(() => containerCount() === stored && carriedCount() === before, signal, 'chest withdrawal')
      record({ bot: bot.username, type: 'operation', action: 'withdraw', status: 'passed', count: 8, position })
    } finally {
      if (window && bot.currentWindow === window) await window.close()
    }
  })
  return { counts: { storage: 1 } }
}

export const farmFace = new Vec3(0, 1, 0)
