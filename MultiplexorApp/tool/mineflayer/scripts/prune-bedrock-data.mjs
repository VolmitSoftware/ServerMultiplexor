import { readdir, rm } from 'node:fs/promises'
import { createRequire } from 'node:module'
import path from 'node:path'
import { fileURLToPath } from 'node:url'

export function minecraftDataDirectory() {
  const require = createRequire(import.meta.url)
  return path.join(path.dirname(require.resolve('minecraft-data/package.json')), 'minecraft-data', 'data')
}

export async function pruneBedrockData(dataDirectory) {
  const bedrock = path.join(dataDirectory, 'bedrock')
  let entries
  try {
    entries = await readdir(bedrock, { withFileTypes: true })
  } catch (error) {
    if (error.code === 'ENOENT') return []
    throw error
  }
  const removed = []
  for (const entry of entries) {
    if (!entry.isDirectory() || entry.name === 'common') continue
    await rm(path.join(bedrock, entry.name), { recursive: true, force: true, maxRetries: 3 })
    removed.push(entry.name)
  }
  return removed.sort()
}

async function install() {
  const removed = await pruneBedrockData(minecraftDataDirectory())
  if (removed.length > 0) process.stdout.write(`Removed unused Bedrock data: ${removed.length} versions\n`)
}
if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) await install()
