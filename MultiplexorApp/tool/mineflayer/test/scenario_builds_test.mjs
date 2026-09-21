import test from 'node:test'
import assert from 'node:assert/strict'
import { mkdtemp, mkdir, writeFile, rm, symlink } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import path from 'node:path'
import { installedPlugins } from '../src/scenario_builds.mjs'

test('build evidence includes symlinked jars, excludes configs, and changes with artifact bytes', async () => {
  const root = await mkdtemp(path.join(tmpdir(), 'gameplay-builds-'))
  try {
    await mkdir(path.join(root, 'plugins'))
    await writeFile(path.join(root, 'plugin.jar'), 'before')
    await writeFile(path.join(root, 'plugins', 'config.yml'), 'ignored')
    await symlink(path.join(root, 'plugin.jar'), path.join(root, 'plugins', 'test.jar'))
    const first = await installedPlugins(root)
    await writeFile(path.join(root, 'plugin.jar'), 'after')
    const second = await installedPlugins(root)
    assert.equal(first.length, 1)
    assert.equal(first[0].filename, 'test.jar')
    assert.notEqual(first[0].sha256, second[0].sha256)
  } finally { await rm(root, { recursive: true, force: true }) }
})
