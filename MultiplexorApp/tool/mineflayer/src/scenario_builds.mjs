import { createHash } from 'node:crypto'
import { createReadStream } from 'node:fs'
import { readdir, stat } from 'node:fs/promises'
import path from 'node:path'

export async function hashFile(filename) {
  const hash = createHash('sha256')
  for await (const chunk of createReadStream(filename)) hash.update(chunk)
  return hash.digest('hex')
}

export async function installedPlugins(directory) {
  if (!directory) return undefined
  const folder = path.join(directory, 'plugins')
  let entries
  try { entries = await readdir(folder, { withFileTypes: true }) }
  catch (error) { if (error.code === 'ENOENT') return []; throw error }
  const plugins = []
  for (const entry of entries.filter((entry) => entry.name.endsWith('.jar') && (entry.isFile() || entry.isSymbolicLink())).sort((a, b) => a.name.localeCompare(b.name))) {
    const filename = path.join(folder, entry.name)
    const before = await stat(filename)
    const sha256 = await hashFile(filename)
    const after = await stat(filename)
    if (before.size !== after.size || before.mtimeMs !== after.mtimeMs) throw new Error(`Plugin artifact changed while hashing: ${entry.name}`)
    plugins.push({ filename: entry.name, bytes: after.size, sha256 })
  }
  return plugins
}
