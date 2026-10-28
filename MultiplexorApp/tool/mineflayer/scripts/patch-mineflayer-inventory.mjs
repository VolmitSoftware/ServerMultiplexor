import { readFile, writeFile, rename, unlink } from 'node:fs/promises'
import { createRequire } from 'node:module'
import path from 'node:path'
import { fileURLToPath } from 'node:url'

const supportedVersion = '4.38.0'
const anchor = "  bot._client.on('set_player_inventory', (packet) => {"
const handler = `  bot._client.on('set_cursor_item', (packet) => {
    const item = Item.fromNotch(packet.contents)
    bot.inventory.selectedItem = item
    if (bot.currentWindow) bot.currentWindow.selectedItem = item
  })
`

const originalCopy = '      if (!Item.equal(bot.inventory.slots[slot], item, true)) bot.inventory.updateSlot(slot, item)'
const componentCopy = `      const previous = bot.inventory.slots[slot]
      if (!Item.equal(previous, item, true) ||
          !isDeepStrictEqual(previous?.components, item?.components) ||
          !isDeepStrictEqual(previous?.removedComponents, item?.removedComponents)) {
        bot.inventory.updateSlot(slot, item)
      }`
const equalityImport = "const { isDeepStrictEqual } = require('node:util')"

const copyAnchor = `  function copyInventory (window) {
    const slotOffset = window.inventoryStart - bot.inventory.inventoryStart`
const copyCursor = `  function copyInventory (window) {
    bot.inventory.selectedItem = window.selectedItem
    const slotOffset = window.inventoryStart - bot.inventory.inventoryStart`
const originalCarried = '    if (packet.carriedItem !== undefined) window.selectedItem = Item.fromNotch(packet.carriedItem)'
const synchronizedCarried = `    if (packet.carriedItem !== undefined) {
      const item = Item.fromNotch(packet.carriedItem)
      window.selectedItem = item
      bot.inventory.selectedItem = item
    }`
const originalCraftWait = '  async function waitForWindowUpdate (window, slot) {'
const emptyResultCraftWait = `  async function waitForWindowUpdate (window, slot, clickedItem) {
    if (slot === 0 && clickedItem === null &&
        (window.type === 'minecraft:inventory' || window.type === 'minecraft:crafting')) return`
const originalCraftWaitCall = '      await waitForWindowUpdate(window, slot)'
const updatedCraftWaitCall = '      await waitForWindowUpdate(window, slot, click.item)'

export function patchInventorySource(source, version) {
  if (version !== supportedVersion) throw new Error(`Inventory patch requires Mineflayer ${supportedVersion}; found ${version}`)
  const newline = source.includes('\r\n') ? '\r\n' : '\n'
  let normalized = source.replace(/\r\n/g, '\n')
  if (!normalized.includes(handler)) {
    if (normalized.includes("on('set_cursor_item'") || normalized.includes('on("set_cursor_item"')) {
      throw new Error('Mineflayer already has a different cursor handler; review the dependency patch')
    }
    if (normalized.split(anchor).length !== 2
      || !normalized.includes("const Item = require('prismarine-item')(bot.registry)")
      || !normalized.includes("bot.inventory = windows.createWindow(0, 'minecraft:inventory', 'Inventory')")) {
      throw new Error('Mineflayer inventory source differs from the supported patch signature')
    }
    normalized = normalized.replace(anchor, `${handler}${anchor}`)
  }
  if (!normalized.includes(componentCopy)) {
    const importAnchor = "const assert = require('assert')"
    if (normalized.split(originalCopy).length !== 2 || normalized.split(importAnchor).length !== 2
      || normalized.includes('isDeepStrictEqual')) {
      throw new Error('Mineflayer inventory copy differs from the supported patch signature')
    }
    normalized = normalized.replace(importAnchor, `${importAnchor}\n${equalityImport}`).replace(originalCopy, componentCopy)
  } else if (!normalized.includes(equalityImport)) {
    throw new Error('Mineflayer inventory component comparison is missing its supported import')
  }
  if (!normalized.includes(copyCursor)) {
    if (normalized.split(copyAnchor).length !== 2) throw new Error('Mineflayer closing cursor differs from the supported patch signature')
    normalized = normalized.replace(copyAnchor, copyCursor)
  }
  if (!normalized.includes(synchronizedCarried)) {
    if (normalized.split(originalCarried).length !== 2) throw new Error('Mineflayer carried item differs from the supported patch signature')
    normalized = normalized.replace(originalCarried, synchronizedCarried)
  }
  if (normalized.split('  async function waitForWindowUpdate (').length !== 2
    || normalized.split('      await waitForWindowUpdate(').length !== 2) {
    throw new Error('Mineflayer crafting result wait differs from the supported patch signature')
  }
  if (normalized.includes(emptyResultCraftWait)) {
    if (normalized.split(emptyResultCraftWait).length !== 2 || normalized.split(updatedCraftWaitCall).length !== 2
      || normalized.includes(originalCraftWait) || normalized.includes(originalCraftWaitCall)) {
      throw new Error('Mineflayer crafting result wait differs from the supported patch signature')
    }
  } else {
    if (normalized.split(originalCraftWait).length !== 2 || normalized.split(originalCraftWaitCall).length !== 2
      || normalized.includes('waitForWindowUpdate (window, slot,') || normalized.includes(updatedCraftWaitCall)) {
      throw new Error('Mineflayer crafting result wait differs from the supported patch signature')
    }
    normalized = normalized.replace(originalCraftWait, emptyResultCraftWait).replace(originalCraftWaitCall, updatedCraftWaitCall)
  }
  return normalized.replace(/\n/g, newline)
}

const originalSmithing = "      windows['minecraft:smithing'] = { type: protocolId++, inventory: { start: 3, end: 38 }, slots: 39, craft: 2, requireConfirmation: true }"
const updatedSmithing = `      const smithingSlots = registry.version['>=']('1.20') ? 4 : 3
      windows['minecraft:smithing'] = { type: protocolId++, inventory: { start: smithingSlots, end: smithingSlots + 35 }, slots: smithingSlots + 36, craft: smithingSlots - 1, requireConfirmation: true }`

export function patchWindowsSource(source, version) {
  if (version !== '2.10.0') throw new Error(`Smithing patch requires prismarine-windows 2.10.0; found ${version}`)
  const newline = source.includes('\r\n') ? '\r\n' : '\n'
  let normalized = source.replace(/\r\n/g, '\n')
  if (!normalized.includes(updatedSmithing)) {
    if (normalized.split(originalSmithing).length !== 2 || normalized.includes('const smithingSlots =')) {
      throw new Error('Prismarine smithing source differs from the supported patch signature')
    }
    normalized = normalized.replace(originalSmithing, updatedSmithing)
  }
  return normalized.replace(/\n/g, newline)
}

async function install() {
  const require = createRequire(import.meta.url)
  const inventory = require.resolve('mineflayer/lib/plugins/inventory.js')
  const windows = require.resolve('prismarine-windows')
  const inventorySource = await readFile(inventory, 'utf8')
  const windowsSource = await readFile(windows, 'utf8')
  const patches = [
    { target: inventory, original: inventorySource, patched: patchInventorySource(inventorySource, require('mineflayer/package.json').version) },
    { target: windows, original: windowsSource, patched: patchWindowsSource(windowsSource, require('prismarine-windows/package.json').version) }
  ]
  for (const { target, original, patched } of patches) {
    if (patched === original) continue
    const temporary = `${target}.inventory-patch-${process.pid}.tmp`
    try {
      await writeFile(temporary, patched, { flag: 'wx' })
      await rename(temporary, target)
    } finally {
      await unlink(temporary).catch(error => { if (error.code !== 'ENOENT') throw error })
    }
    process.stdout.write(`Installed authoritative inventory handling: ${path.basename(target)}\n`)
  }
}
if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) await install()
