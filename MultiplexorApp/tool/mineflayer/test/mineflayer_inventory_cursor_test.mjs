import test from 'node:test'
import assert from 'node:assert/strict'
import { EventEmitter } from 'node:events'
import { readFile } from 'node:fs/promises'
import { createRequire, Module } from 'node:module'
import { Script } from 'node:vm'
import path from 'node:path'
import { patchInventorySource, patchWindowsSource } from '../scripts/patch-mineflayer-inventory.mjs'

const require = createRequire(import.meta.url)
const inventoryFile = require.resolve('mineflayer/lib/plugins/inventory.js')
const source = await readFile(inventoryFile, 'utf8')
const version = require('mineflayer/package.json').version
const patched = patchInventorySource(source, version)
const registry = require('prismarine-registry')('26.1')
const Item = require('prismarine-item')(registry)
const windows = require('prismarine-windows')('26.1')

function createBot(inventorySource = patched, windowsLoader) {
  const module = { exports: {} }
  const dependency = createRequire(inventoryFile)
  const load = name => name === 'prismarine-windows' && windowsLoader ? windowsLoader : dependency(name)
  new Script(Module.wrap(inventorySource), { filename: inventoryFile }).runInThisContext()(
    module.exports, load, module, inventoryFile, path.dirname(inventoryFile))
  const bot = new EventEmitter()
  bot._client = new EventEmitter()
  bot._client.write = () => {}
  bot.registry = registry
  bot.version = '26.1'
  bot.supportFeature = name => registry.supportFeature(name)
  bot.QUICK_BAR_START = 36
  module.exports(bot, { hideErrors: true })
  bot.quickBarSlot = 0
  return bot
}

function networkItem() {
  return {
    itemId: registry.itemsByName.diamond_pickaxe.id,
    itemCount: 1,
    components: [{ type: 'custom_data', data: { type: 'compound', value: {
      PublicBukkitValues: { type: 'compound', value: { 'talon:ability_remote_loot': { type: 'int', value: 1 } } }
    } } }],
    removeComponents: []
  }
}

test('inventory patch is idempotent and preserves existing inventory source', () => {
  assert.equal(patchInventorySource(patched, version), patched)
  assert.throws(() => patchInventorySource(patched.replace('isDeepStrictEqual(previous?.components, item?.components)', 'changedComparison(previous, item)'), version), /copy differs/)
  const start = patched.indexOf("  bot._client.on('set_cursor_item'")
  const end = patched.indexOf("  bot._client.on('set_player_inventory'", start)
  const withoutHandler = patched.slice(0, start) + patched.slice(end)
  const result = patchInventorySource(withoutHandler, version)
  assert.equal(result, patched)
  const crlf = withoutHandler.replace(/\r?\n/g, '\r\n')
  assert.equal(patchInventorySource(crlf, version).replace(/\r\n/g, '\n'), patched.replace(/\r\n/g, '\n'))
  assert.throws(() => patchInventorySource(withoutHandler, '4.39.0'), /requires Mineflayer/)
  assert.throws(() => patchInventorySource(withoutHandler.replace("on('set_player_inventory'", "on('changed_inventory'"), version), /signature/)
  assert.throws(() => patchInventorySource(withoutHandler + "\nbot._client.on('set_cursor_item', () => {})", version), /different cursor handler/)
})

for (const menuOpen of [false, true]) {
  test(`authoritative cursor packets replace and clear state with menuOpen=${menuOpen}`, () => {
    const bot = createBot()
    const held = new Item(registry.itemsByName.stone.id, 12)
    bot.inventory.updateSlot(36, held)
    if (menuOpen) bot.currentWindow = windows.createWindow(1, 'minecraft:generic_9x3', 'Container')
    const before = [...bot.inventory.slots]
    const menuSlots = bot.currentWindow ? [...bot.currentWindow.slots] : null
    let slotEvents = 0
    let heldEvents = 0
    bot.inventory.on('updateSlot', () => { slotEvents++ })
    bot.on('heldItemChanged', () => { heldEvents++ })
    bot._client.emit('set_cursor_item', { contents: networkItem() })
    assert.equal(bot.inventory.selectedItem.name, 'diamond_pickaxe')
    assert.equal(bot.inventory.selectedItem.componentMap.get('custom_data').data.value.PublicBukkitValues.value['talon:ability_remote_loot'].value, 1)
    if (menuOpen) assert.equal(bot.currentWindow.selectedItem, bot.inventory.selectedItem)
    bot._client.emit('set_cursor_item', { contents: { itemCount: 0 } })
    assert.equal(bot.inventory.selectedItem, null)
    if (menuOpen) {
      assert.equal(bot.currentWindow.selectedItem, null)
      assert.deepEqual(bot.currentWindow.slots, menuSlots)
    }
    assert.deepEqual(bot.inventory.slots, before)
    assert.equal(bot.heldItem, held)
    assert.equal(slotEvents, 0)
    assert.equal(heldEvents, 0)
  })
}

function book(level, removedComponents = []) {
  return Item.fromNotch({
    itemId: registry.itemsByName.enchanted_book.id,
    itemCount: 1,
    components: [{ type: 'custom_data', data: { type: 'compound', value: {
      PublicBukkitValues: { type: 'compound', value: {
        'talon:book_level': { type: 'int', value: level },
        'test:long': { type: 'long', value: 42n }
      } }
    } } }],
    removeComponents: removedComponents
  })
}

test('closing a workstation copies component-only book upgrades and emits only changed slot events', () => {
  const bot = createBot()
  const window = windows.createWindow(1, 'minecraft:crafting', 'Crafting')
  bot.currentWindow = window
  const original = book(1)
  const unchanged = book(1)
  const removed = book(1)
  bot.inventory.updateSlot(9, original)
  bot.inventory.updateSlot(10, unchanged)
  bot.inventory.updateSlot(11, removed)
  bot.inventory.updateSlot(36, book(1))
  const before = [...bot.inventory.slots]
  const offset = window.inventoryStart - bot.inventory.inventoryStart
  for (let slot = 9; slot < 45; slot++) window.updateSlot(slot + offset, bot.inventory.slots[slot])
  const upgraded = book(2)
  const hotbarUpgrade = book(3)
  window.updateSlot(9 + offset, upgraded)
  window.updateSlot(10 + offset, book(1))
  window.updateSlot(11 + offset, book(1, ['custom_name']))
  window.updateSlot(36 + offset, hotbarUpgrade)
  const updates = []
  const held = []
  bot.inventory.on('updateSlot', (slot, previous, item) => updates.push({ slot, previous, item }))
  bot.on('heldItemChanged', item => held.push(item))
  const closed = []
  bot.on('windowClose', item => closed.push(item))
  bot.closeWindow(window)
  assert.equal(bot.currentWindow, null)
  assert.deepEqual(updates.map(update => update.slot), [9, 11, 36])
  assert.equal(updates[0].previous, original)
  assert.equal(bot.inventory.slots[9], upgraded)
  assert.equal(bot.inventory.slots[10], unchanged)
  assert.deepEqual(bot.inventory.slots[11].removedComponents, ['custom_name'])
  assert.equal(bot.heldItem, hotbarUpgrade)
  assert.deepEqual(held, [hotbarUpgrade])
  assert.deepEqual(closed, [window])
  for (let slot = 0; slot < before.length; slot++) {
    if (![9, 11, 36].includes(slot)) assert.equal(bot.inventory.slots[slot], before[slot])
  }
})

for (const placeCursor of [false, true]) {
  test(`closing a menu copies the cursor after an ordinary click with placeCursor=${placeCursor}`, async () => {
    const bot = createBot()
    const window = windows.createWindow(1, 'minecraft:grindstone', 'Grindstone')
    bot.currentWindow = window
    bot._client.emit('set_cursor_item', { contents: networkItem() })
    const carried = window.selectedItem
    if (placeCursor) {
      await bot.clickWindow(window.inventoryStart, 0, 0)
      assert.equal(window.selectedItem, null)
      assert.equal(window.slots[window.inventoryStart], carried)
    }
    bot.closeWindow(window)
    assert.equal(bot.currentWindow, null)
    assert.equal(bot.inventory.selectedItem, placeCursor ? null : carried)
    assert.equal(bot.inventory.slots[9], placeCursor ? carried : null)
    assert.equal(bot.inventory.items().length, placeCursor ? 1 : 0)
  })
}

test('full matching window state reconciles both cursors and unrelated window state cannot replace them', () => {
  const bot = createBot()
  const window = windows.createWindow(1, 'minecraft:grindstone', 'Grindstone')
  bot.currentWindow = window
  const contents = networkItem()
  const empty = { itemCount: 0 }
  const items = window.slots.map(() => empty)
  bot._client.emit('window_items', { windowId: window.id, items, carriedItem: contents })
  assert.equal(window.selectedItem.name, 'diamond_pickaxe')
  assert.equal(bot.inventory.selectedItem, window.selectedItem)
  const carried = window.selectedItem
  bot._client.emit('window_items', { windowId: 19, items, carriedItem: empty })
  assert.equal(window.selectedItem, carried)
  assert.equal(bot.inventory.selectedItem, carried)
  bot._client.emit('window_items', { windowId: window.id, items })
  assert.equal(window.selectedItem, carried)
  assert.equal(bot.inventory.selectedItem, carried)
  bot._client.emit('window_items', { windowId: window.id, items, carriedItem: empty })
  assert.equal(window.selectedItem, null)
  assert.equal(bot.inventory.selectedItem, null)
  bot.closeWindow(window)
  assert.equal(bot.inventory.selectedItem, null)
})
const windowsFile = require.resolve('prismarine-windows')
const windowsSource = await readFile(windowsFile, 'utf8')
const windowsVersion = require('prismarine-windows/package.json').version
const patchedWindows = patchWindowsSource(windowsSource, windowsVersion)
const windowsModule = { exports: {} }
new Script(Module.wrap(patchedWindows), { filename: windowsFile }).runInThisContext()(
  windowsModule.exports, createRequire(windowsFile), windowsModule, windowsFile, path.dirname(windowsFile))

test('smithing patch preserves other definitions and validates version, signature, and repeat installation', () => {
  assert.equal(patchWindowsSource(patchedWindows, windowsVersion), patchedWindows)
  const original = "      windows['minecraft:smithing'] = { type: protocolId++, inventory: { start: 3, end: 38 }, slots: 39, craft: 2, requireConfirmation: true }"
  const updated = `      const smithingSlots = registry.version['>=']('1.20') ? 4 : 3
      windows['minecraft:smithing'] = { type: protocolId++, inventory: { start: smithingSlots, end: smithingSlots + 35 }, slots: smithingSlots + 36, craft: smithingSlots - 1, requireConfirmation: true }`
  const unpatched = patchedWindows.replace(/\r\n/g, '\n').replace(updated, original)
  assert.equal(patchWindowsSource(unpatched, windowsVersion), patchedWindows.replace(/\r\n/g, '\n'))
  assert.equal(patchWindowsSource(unpatched.replace(/\n/g, '\r\n'), windowsVersion), patchedWindows.replace(/\r?\n/g, '\r\n'))
  assert.throws(() => patchWindowsSource(unpatched, '2.11.0'), /requires prismarine-windows/)
  assert.throws(() => patchWindowsSource(unpatched.replace(original, original.replace('slots: 39', 'slots: 40')), windowsVersion), /signature/)
})

for (const version of ['1.19.4', '1.20', '1.21.11', '26.1']) {
  test(`smithing slots and shift-click result agree with protocol ${version}`, () => {
    const loader = windowsModule.exports(version)
    const current = version !== '1.19.4'
    const start = current ? 4 : 3
    const resultSlot = start - 1
    const window = loader.createWindow(1, 'minecraft:smithing', 'Smithing')
    assert.equal(window.inventoryStart, start)
    assert.equal(window.inventoryEnd, start + 36)
    assert.equal(window.slots.length, start + 36)
    assert.equal(window.craftingResultSlot, resultSlot)
    assert.equal(window.hotbarStart, start + 27)
    assert.equal(loader.createWindow(1, loader.windows['minecraft:smithing'].type, 'Smithing').inventoryStart, start)
    assert.equal(loader.createWindow(2, 'minecraft:anvil', 'Anvil').inventoryStart, 3)
    const Item = require('prismarine-item')(version)
    const data = require('prismarine-registry')(version)
    const base = new Item(data.itemsByName.diamond_pickaxe.id, 1)
    const ingredient = new Item(data.itemsByName.netherite_ingot.id, 1)
    const result = new Item(data.itemsByName.netherite_pickaxe.id, 1)
    window.updateSlot(resultSlot - 2, base)
    window.updateSlot(resultSlot - 1, ingredient)
    window.updateSlot(resultSlot, result)
    window.acceptClick({ slot: resultSlot, item: result, mouseButton: 0, mode: 1 })
    assert.equal(window.slots[resultSlot], null)
    assert.equal(window.slots[resultSlot - 2], base)
    assert.equal(window.slots[resultSlot - 1], ingredient)
    assert.equal(window.slots[window.inventoryEnd - 1], result)
    assert.equal(window.slots.slice(window.inventoryStart, window.inventoryEnd).filter(item => item?.name === 'netherite_pickaxe').length, 1)
  })
}
test('closing a modern smithing menu maps all 36 inventory slots without treating the result as storage', () => {
  const bot = createBot(patched, windowsModule.exports)
  const window = windowsModule.exports('26.1').createWindow(1, 'minecraft:smithing', 'Smithing')
  bot.currentWindow = window
  const stone = new Item(registry.itemsByName.stone.id, 12)
  const pickaxe = Item.fromNotch(networkItem())
  window.updateSlot(4, stone)
  window.updateSlot(39, pickaxe)
  window.updateSlot(3, new Item(registry.itemsByName.netherite_pickaxe.id, 1))
  bot.closeWindow(window)
  assert.equal(bot.inventory.slots[9], stone)
  assert.equal(bot.inventory.slots[44], pickaxe)
  assert.equal(bot.inventory.items().length, 2)
  assert.equal(bot.inventory.items().some(item => item.name === 'netherite_pickaxe'), false)
  assert.equal(pickaxe.componentMap.get('custom_data').data.value.PublicBukkitValues.value['talon:ability_remote_loot'].value, 1)
})
test('empty crafting result patch validates both call sites and remains idempotent', () => {
  assert.equal(patchInventorySource(patched, version), patched)
  const signature = '  async function waitForWindowUpdate (window, slot, clickedItem) {'
  const call = '      await waitForWindowUpdate(window, slot, click.item)'
  assert.throws(() => patchInventorySource(patched.replace('clickedItem === null', 'clickedItem === undefined'), version), /crafting result wait differs/)
  assert.throws(() => patchInventorySource(patched.replace(call, '      await waitForWindowUpdate(window, slot)'), version), /crafting result wait differs/)
  assert.throws(() => patchInventorySource(patched.replace(signature, signature + '\n' + signature), version), /crafting result wait differs/)
  assert.equal(patchInventorySource(patched.replace(/\r?\n/g, '\r\n'), version).replace(/\r\n/g, '\n'), patched.replace(/\r\n/g, '\n'))
})

for (const type of ['minecraft:inventory', 'minecraft:crafting']) {
  for (const mode of [0, 1]) {
    test(`empty result click resolves without a server update for ${type} mode ${mode}`, { timeout: 1000 }, async () => {
      const bot = createBot()
      const window = type === 'minecraft:inventory' ? bot.inventory : windows.createWindow(1, type, 'Crafting')
      if (window !== bot.inventory) bot.currentWindow = window
      const ingredient = new Item(registry.itemsByName.lapis_lazuli.id, 1)
      const unrelated = new Item(registry.itemsByName.diamond.id, 3)
      window.updateSlot(1, ingredient)
      window.updateSlot(window.inventoryStart, unrelated)
      const before = [...window.slots]
      const packets = []
      bot._client.write = (name, packet) => packets.push({ name, packet })
      let completed = false
      const click = bot.clickWindow(0, 0, mode).then(() => { completed = true })
      try {
        await new Promise(resolve => setImmediate(resolve))
        assert.equal(completed, true, 'An empty result must not require an unchanged result packet')
        assert.equal(window.listenerCount('updateSlot:0'), 0)
        assert.equal(packets.length, 1)
        assert.equal(packets[0].name, 'window_click')
        assert.equal(packets[0].packet.windowId, window.id)
        assert.equal(packets[0].packet.slot, 0)
        assert.equal(packets[0].packet.mode, mode)
        assert.deepEqual(window.slots, before)
        assert.equal(window.slots[1], ingredient)
        assert.equal(window.slots[window.inventoryStart], unrelated)
        assert.equal(window.selectedItem, null)
      } finally {
        if (!completed) bot._client.emit('set_slot', { windowId: window.id, slot: 0, item: { itemCount: 0 } })
        await click
      }
    })
  }

  test(`populated result click still waits for authoritative result update for ${type}`, { timeout: 1000 }, async () => {
    const bot = createBot()
    const window = type === 'minecraft:inventory' ? bot.inventory : windows.createWindow(1, type, 'Crafting')
    if (window !== bot.inventory) bot.currentWindow = window
    const result = book(2)
    window.updateSlot(0, result)
    const packets = []
    bot._client.write = (name, packet) => packets.push({ name, packet })
    let completed = false
    const click = bot.clickWindow(0, 0, 0).then(() => { completed = true })
    try {
      await new Promise(resolve => setImmediate(resolve))
      assert.equal(completed, false, 'A populated result must retain its server update wait')
      assert.equal(window.listenerCount('updateSlot:0'), 1)
      assert.equal(packets.length, 1)
      assert.equal(packets[0].name, 'window_click')
      assert.equal(packets[0].packet.slot, 0)
      bot._client.emit('set_slot', { windowId: window.id, slot: window.inventoryStart, item: { itemCount: 0 } })
      await new Promise(resolve => setImmediate(resolve))
      assert.equal(completed, false, 'An unrelated inventory update must not complete crafting')
    } finally {
      bot._client.emit('set_slot', { windowId: window.id, slot: 0, item: { itemCount: 0 } })
      await click
    }
    assert.equal(completed, true)
    assert.equal(window.listenerCount('updateSlot:0'), 0)
    assert.equal(packets.length, 1)
    assert.equal(window.selectedItem, result)
    assert.equal(window.selectedItem.componentMap.get('custom_data').data.value.PublicBukkitValues.value['talon:book_level'].value, 2)
  })

  test(`ingredient click retains the crafting result update wait for ${type}`, { timeout: 1000 }, async () => {
    const bot = createBot()
    const window = type === 'minecraft:inventory' ? bot.inventory : windows.createWindow(1, type, 'Crafting')
    if (window !== bot.inventory) bot.currentWindow = window
    const ingredient = new Item(registry.itemsByName.lapis_lazuli.id, 1)
    window.updateSlot(1, ingredient)
    const packets = []
    bot._client.write = (name, packet) => packets.push({ name, packet })
    let completed = false
    const click = bot.clickWindow(1, 0, 0).then(() => { completed = true })
    try {
      await new Promise(resolve => setImmediate(resolve))
      assert.equal(completed, false)
      assert.equal(window.listenerCount('updateSlot:0'), 1)
      assert.equal(packets.length, 1)
      assert.equal(packets[0].packet.slot, 1)
    } finally {
      bot._client.emit('set_slot', { windowId: window.id, slot: 0, item: { itemCount: 0 } })
      await click
    }
    assert.equal(completed, true)
    assert.equal(packets.length, 1)
    assert.equal(window.slots[1], null)
    assert.equal(window.selectedItem, ingredient)
  })
}
