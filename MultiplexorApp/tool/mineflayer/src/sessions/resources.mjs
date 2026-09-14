import { point, until } from '../swarm_actions.mjs'
import { sessionWalk as walkTo } from './world.mjs'

export function inventoryCounts(items) {
  const counts = {}
  for (const item of items) if (item) counts[item.name] = (counts[item.name] ?? 0) + item.count
  return counts
}

export function itemCount(bot, name) { return inventoryCounts(bot.currentWindow?.items() ?? bot.inventory.items())[name] ?? 0 }

export function storageSnapshot(window, registry, now = Date.now()) {
  const items = inventoryCounts(window.containerItems())
  const slots = window.slots.slice(0, window.inventoryStart)
  const empty = slots.filter((item) => !item).length
  const partialCapacity = {}
  for (const slot of slots) {
    if (!slot) continue
    const stackSize = registry.itemsByName[slot.name]?.stackSize ?? 64
    partialCapacity[slot.name] = (partialCapacity[slot.name] ?? 0) + Math.max(0, stackSize - slot.count)
  }
  return { items, emptySlots: empty, partialCapacity, observedAt: now }
}

function failUncertain(player, operation, error) {
  player.intent.transfer = { ...operation, phase: 'uncertain', error: error.message }
  error.uncertain = true
  return error
}

export async function withStorage(bot, player, context, operation) {
  const { world, shared, signal, checkpoint, coordinator, assertCurrent } = context
  const owner = `${player.id}:${player.generation}`
  const lease = coordinator.acquire(`${world.backend}:${world.dimension}:storage:${world.storage.join(',')}`, owner, 120000)
  if (!lease) return { status: 'waiting', reason: 'Shared storage is in use' }
  let window
  const cancel = () => { if (window && bot.currentWindow === window) bot.closeWindow(window) }
  signal.addEventListener('abort', cancel, { once: true })
  try {
    await walkTo(bot, world.storage, signal, { near: true })
    assertCurrent(); coordinator.assert(lease)
    const block = bot.blockAt(point(world.storage))
    if (!['chest', 'barrel', 'trapped_chest'].includes(block?.name)) throw new Error('Shared storage is missing or unloaded')
    window = await bot.openContainer(block)
    signal.throwIfAborted(); assertCurrent(); coordinator.assert(lease)
    shared.world.storage = storageSnapshot(window, bot.registry)
    const prior = player.intent.transfer
    if (prior && prior.phase !== 'verified') {
      // Fresh observations replace assumptions. An ambiguous transfer is never replayed.
      player.intent.lastReconciliation = {
        item: prior.item, kind: prior.kind, requested: prior.count,
        previousPlayerCount: prior.playerBefore, currentPlayerCount: itemCount(bot, prior.item),
        previousStoredCount: prior.storageBefore, currentStoredCount: shared.world.storage.items[prior.item] ?? 0,
        outcome: 'reobserved; no completion credit', at: Date.now()
      }
      context.record({ type: 'transfer-reconciled', player: player.id, ...player.intent.lastReconciliation })
      delete player.intent.transfer
      await checkpoint()
    }
    const result = await operation(window, lease)
    shared.world.storage = storageSnapshot(window, bot.registry)
    await checkpoint()
    return result
  } finally {
    signal.removeEventListener('abort', cancel)
    try { if (window && bot.currentWindow === window) await window.close() }
    finally { coordinator.release(lease) }
  }
}

export async function transferResource(bot, player, task, context) {
  return withStorage(bot, player, context, async (window, lease) => {
    const { signal, shared, checkpoint, assertCurrent, coordinator } = context
    const itemType = bot.registry.itemsByName[task.item]?.id
    if (itemType === undefined) throw new Error(`Unknown item ${task.item}`)
    const stored = inventoryCounts(window.containerItems())[task.item] ?? 0
    const carried = itemCount(bot, task.item)
    const snapshot = storageSnapshot(window, bot.registry)
    const capacity = snapshot.emptySlots * (bot.registry.itemsByName[task.item].stackSize ?? 64) + (snapshot.partialCapacity[task.item] ?? 0)
    const count = Math.min(task.count, task.kind === 'deposit' ? Math.min(carried, capacity) : stored)
    if (count < 1) return { status: 'waiting', reason: task.kind === 'deposit' ? 'Storage has no space or supplies are absent' : `Waiting for ${task.item}` }
    const operation = { kind: task.kind, item: task.item, count, playerBefore: carried, storageBefore: stored, phase: 'intent', at: Date.now() }
    player.intent.transfer = operation
    await checkpoint()
    signal.throwIfAborted(); assertCurrent(); coordinator.assert(lease)
    try {
      await window[task.kind](itemType, null, count)
      const sign = task.kind === 'deposit' ? 1 : -1
      await until(() => (inventoryCounts(window.containerItems())[task.item] ?? 0) === stored + sign * count &&
        itemCount(bot, task.item) === carried - sign * count, signal, 'authoritative storage transfer')
      assertCurrent(); coordinator.assert(lease)
      player.intent.transfer.phase = 'verified'
      shared.world.resourceTransfers += count
      context.record({ type: 'transfer', player: player.id, kind: task.kind, item: task.item, count })
      delete player.intent.transfer
      await checkpoint()
      return { status: 'completed', kind: task.kind, metrics: { itemsTransferred: count }, item: task.item, count }
    } catch (error) {
      failUncertain(player, operation, error)
      await checkpoint()
      throw error
    }
  })
}
