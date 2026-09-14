import { point } from './swarm_actions.mjs'

export function packetChangesPosition(bot, packet, position, multiple = false) {
  if (!multiple) {
    return packet.location?.x === position.x && packet.location?.y === position.y && packet.location?.z === position.z
  }
  const modern = bot.supportFeature('usesMultiblockSingleLong')
  const chunk = bot.supportFeature('usesMultiblock3DChunkCoords')
    ? packet.chunkCoordinates : { x: packet.chunkX, y: 0, z: packet.chunkZ }
  if (!chunk) return false
  return packet.records.some((record) => {
    const encoded = modern ? Number(record) : undefined
    const x = modern ? (encoded >> 8) & 15 : (record.horizontalPos >> 4) & 15
    const y = modern ? encoded & 15 : record.y
    const z = modern ? (encoded >> 4) & 15 : record.horizontalPos & 15
    return chunk.x * 16 + x === position.x && chunk.y * 16 + y === position.y && chunk.z * 16 + z === position.z
  })
}

// Mineflayer predicts digging locally. Only a matching server packet can confirm an edit.
export async function serverBlockEdit(bot, target, predicate, action, signal) {
  const position = point(target)
  signal.throwIfAborted()
  let accept
  let reject
  const acknowledgement = new Promise((resolve, fail) => { accept = resolve; reject = fail })
  acknowledgement.catch(() => {})
  const changed = (packet, multiple) => {
    if (packetChangesPosition(bot, packet, position, multiple) && predicate(bot.blockAt(position))) accept()
  }
  const single = (packet) => changed(packet, false)
  const multiple = (packet) => changed(packet, true)
  const cancel = () => reject(signal.reason)
  bot._client.on('block_change', single)
  bot._client.on('multi_block_change', multiple)
  signal.addEventListener('abort', cancel, { once: true })
  try {
    await action()
    signal.throwIfAborted()
    await acknowledgement
  } finally {
    bot._client.removeListener('block_change', single)
    bot._client.removeListener('multi_block_change', multiple)
    signal.removeEventListener('abort', cancel)
  }
}
