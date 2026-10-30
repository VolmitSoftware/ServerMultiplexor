import test from 'node:test'
import assert from 'node:assert/strict'
import { mkdir, mkdtemp, readdir, rm, writeFile } from 'node:fs/promises'
import { createRequire } from 'node:module'
import { tmpdir } from 'node:os'
import path from 'node:path'
import { minecraftDataDirectory, pruneBedrockData } from '../scripts/prune-bedrock-data.mjs'

const require = createRequire(import.meta.url)

async function fixture() {
  const root = await mkdtemp(path.join(tmpdir(), 'mineflayer-bedrock-prune-'))
  const files = [
    'bedrock/common/protocolVersions.json',
    'bedrock/common/versions.json',
    'bedrock/1.21.90/blocks.json',
    'bedrock/1.21.90/nested/proto.yml',
    'bedrock/latest/types.yml',
    'bedrock/README.md',
    'pc/26.1/blocks.json',
    'pc/common/protocolVersions.json',
    'dataPaths.json'
  ]
  for (const file of files) {
    await mkdir(path.dirname(path.join(root, file)), { recursive: true })
    await writeFile(path.join(root, file), '{}')
  }
  return root
}

async function tree(directory) {
  const entries = await readdir(directory, { recursive: true, withFileTypes: true })
  return entries.filter(entry => entry.isFile())
    .map(entry => path.relative(directory, path.join(entry.parentPath, entry.name)).split(path.sep).join('/'))
    .sort()
}

test('pruning removes per-version Bedrock folders and keeps common Bedrock and all Java data', async () => {
  const root = await fixture()
  try {
    assert.deepEqual(await pruneBedrockData(root), ['1.21.90', 'latest'])
    assert.deepEqual(await tree(root), [
      'bedrock/README.md',
      'bedrock/common/protocolVersions.json',
      'bedrock/common/versions.json',
      'dataPaths.json',
      'pc/26.1/blocks.json',
      'pc/common/protocolVersions.json'
    ])
    assert.deepEqual(await pruneBedrockData(root), [])
  } finally {
    await rm(root, { recursive: true, force: true })
  }
})

test('pruning is a no-op when the Bedrock or data folder is absent', async () => {
  const root = await fixture()
  try {
    await rm(path.join(root, 'bedrock'), { recursive: true })
    assert.deepEqual(await pruneBedrockData(root), [])
    assert.deepEqual(await tree(root), ['dataPaths.json', 'pc/26.1/blocks.json', 'pc/common/protocolVersions.json'])
    assert.deepEqual(await pruneBedrockData(path.join(root, 'missing')), [])
  } finally {
    await rm(root, { recursive: true, force: true })
  }
})

test('installed minecraft-data keeps only common Bedrock data and still resolves Java versions', async () => {
  const bedrock = path.join(minecraftDataDirectory(), 'bedrock')
  const folders = (await readdir(bedrock, { withFileTypes: true })).filter(entry => entry.isDirectory()).map(entry => entry.name)
  assert.deepEqual(folders, ['common'])
  const minecraftData = require('minecraft-data')
  assert.ok(minecraftData.versions.bedrock.length > 0)
  const data = minecraftData('26.1')
  assert.equal(data.type, 'pc')
  assert.ok(data.protocol.play.toClient && data.blocksByName.stone && data.itemsByName.diamond)
})
