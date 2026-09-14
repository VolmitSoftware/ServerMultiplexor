import assert from 'node:assert/strict'
import { mkdtemp, readFile, rm, writeFile } from 'node:fs/promises'
import os from 'node:os'
import path from 'node:path'
import { execFile } from 'node:child_process'
import { promisify } from 'node:util'
import { fileURLToPath } from 'node:url'
import test from 'node:test'

import { parseSwarmConfiguration, swarmNeedsController, swarmWorkerNames } from '../src/swarm_config.mjs'
import { SWARM_PROFILES } from '../src/swarm_behaviors.mjs'

const parse = (tokens) => parseSwarmConfiguration(tokens, SWARM_PROFILES)
const command = promisify(execFile)
const cli = fileURLToPath(new URL('../src/cli.mjs', import.meta.url))

test('swarm configuration converts units, preserves seed zero, and generates distinct deterministic names', async () => {
  const config = await parse(['wander', '--port', '25565', '--prefix', 'Load', '--seed', '0'])
  assert.equal(config.durationMs, 60000)
  assert.equal(config.connectTimeoutMs, 30000)
  assert.equal(config.actionTimeoutMs, 15000)
  assert.equal(config.joinIntervalMs, 1000)
  assert.equal(config.seed, 0)
  assert.deepEqual(config.origin, { x: 0, y: 80, z: 0 })
  assert.deepEqual(swarmWorkerNames(config), ['Load01', 'Load02', 'Load03', 'Load04'])
  assert.equal(config.auth, 'offline')
  assert.equal(swarmNeedsController(config), false)
})

test('swarm parser rejects unsafe hosts, malformed numbers, duplicate options, and missing values', async () => {
  for (const arguments_ of [
    ['--host', 'example.org'], ['--host', '0.0.0.0'], ['--bots', '4bots'],
    ['--bots', '0'], ['--bots', '257'], ['--duration', '0'], ['--duration', '604801'],
    ['--seed', '-1'], ['--seed', '4294967296'], ['--join-interval', '99'],
    ['--join-interval', '10001'], ['--radius', '3'], ['--radius', '65'],
    ['--origin', '0,80'], ['--origin', '30000000,80,0'], ['--origin', '0,257,0'],
    ['--prefix', 'too_long_username'], ['--no-viewer=true'], ['--unknown'],
    ['--bots', '2', '--bots', '3'], ['--bots'], ['--scatter', '7'], ['--scatter', '4097'],
    ['--no-viewer', '--viewer-port', '8080']
  ]) await assert.rejects(parse(['idle', '--port', '25565', ...arguments_]))
  await assert.rejects(parse(['idle']), /port/)
})

test('arena and scatter require a separate reserved controller and cannot be combined', async () => {
  await assert.rejects(parse(['workshop', '--port', '25565']), /requires --build-arena/)
  await assert.rejects(parse(['workshop', '--port', '25565', '--build-arena']), /controller/)
  await assert.rejects(parse(['idle', '--port', '25565', '--scatter', '32']), /controller/)
  await assert.rejects(parse(['idle', '--port', '25565', '--prefix', 'Test', '--build-arena', '--controller', 'test01']), /different username/)
  await assert.rejects(parse(['idle', '--port', '25565', '--build-arena', '--scatter', '32', '--controller', 'Control']), /cannot be combined/)
  await assert.rejects(parse(['idle', '--port', '25565', '--origin', '29998000,80,0', '--scatter', '4096', '--controller', 'Control']), /world coordinates/)
  const config = await parse(['wander', '--port', '25565', '--scatter', '32', '--controller', 'Control', '--chat'])
  assert.equal(config.scatter, 32)
  assert.equal(config.chat, true)
  assert.equal(swarmNeedsController(config), true)
})

test('custom plans validate actual actor count before a run and preserve their normalized contents', async (t) => {
  const directory = await mkdtemp(path.join(os.tmpdir(), 'swarm-config-'))
  t.after(() => rm(directory, { recursive: true, force: true }))
  const filename = path.join(directory, 'plan.JSON')
  const plan = { name: 'Two workers', phases: [{ action: 'chat', actors: [2], messages: ['Ready {bot}'] }] }
  await writeFile(filename, JSON.stringify(plan))
  await assert.rejects(parse([filename, '--port', '25565', '--bots', '1', '--controller', 'Control']), /actors/)
  const config = await parse([filename, '--port', '25565', '--bots', '2', '--controller', 'Control'])
  assert.equal(config.profile, 'custom')
  assert.equal(config.sourcePath, filename)
  assert.deepEqual(config.plan, plan)
  assert.equal(swarmNeedsController(config), true)
  assert.deepEqual(JSON.parse(await readFile(filename)), plan)
})

test('Node CLI lists profiles and validates local plans without connecting', async (t) => {
  const directory = await mkdtemp(path.join(os.tmpdir(), 'swarm-cli-'))
  t.after(() => rm(directory, { recursive: true, force: true }))
  const filename = path.join(directory, 'plan.json')
  await writeFile(filename, JSON.stringify({ name: 'Pause', phases: [{ action: 'wait', seconds: 1 }] }))
  const profiles = await command(process.execPath, [cli, 'swarm-profiles', '--json'])
  assert.deepEqual(JSON.parse(profiles.stdout).profiles.map((profile) => profile.name), ['idle', 'wander', 'redstone', 'workshop', 'mixed', 'stress'])
  const valid = await command(process.execPath, [cli, 'swarm-validate', filename, '--json'])
  assert.equal(JSON.parse(valid.stdout).status, 'passed')
  await writeFile(filename, JSON.stringify({ name: 'Two actors', phases: [{ action: 'chat', actors: [2], messages: ['Ready'] }] }))
  await assert.rejects(command(process.execPath, [cli, 'swarm-validate', filename, '--bots', '1', '--json']), (error) => {
    assert.equal(error.code, 2)
    assert.match(JSON.parse(error.stdout).error, /actors/)
    return true
  })
  await writeFile(filename, JSON.stringify({ name: 'Unsafe chat', phases: [{ action: 'chat', messages: ['/op anyone'] }] }))
  await assert.rejects(command(process.execPath, [cli, 'swarm-validate', filename, '--json']), (error) => {
    assert.equal(error.code, 2)
    assert.equal(JSON.parse(error.stdout).status, 'failed')
    return true
  })
})

test('all profiles accept 256 distinct usernames and durations up to seven days', async () => {
  const config = await parse(['idle', '--port', '25565', '--bots', '256', '--duration', '604800', '--prefix', 'MaximumNames'])
  assert.equal(config.durationMs, 604800000)
  const names = swarmWorkerNames(config)
  assert.equal(names.length, 256)
  assert.equal(new Set(names).size, 256)
  assert.equal(names[0], 'MaximumNames01')
  assert.equal(names[99], 'MaximumNames100')
  assert.ok(names.every((name) => name.length <= 16))
})

test('stress normalizes bounds and goal overrides and rejects conflicting profile options', async () => {
  const config = await parse(['stress', '--port', '25565', '--controller', 'Control',
    '--bounds', '-8,70,-8:8,90,8', '--goals', 'patrol=10,chat=2', '--completion', 'goals'])
  assert.deepEqual(config.bounds, { min: [-8, 70, -8], max: [8, 90, 8] })
  assert.deepEqual(config.workload.goals, { patrol: 10, chat: 2 })
  assert.equal(config.workload.completion, 'goals')
  assert.equal(swarmNeedsController(config), true)
  for (const options of [
    ['--goals', 'patrol=1,patrol=2'], ['--goals', 'patrol=0'], ['--goals', 'patrol=1x'],
    ['--goals', 'invalid=3'], ['--completion', 'goals'], ['--scatter', '32'],
    ['--bounds', '0,0,0:0,0,0'], ['--build-arena', '--bounds', '0,80,0:2,81,2']
  ]) await assert.rejects(parse(['stress', '--port', '25565', '--controller', 'Control', ...options]))
  await assert.rejects(parse(['wander', '--port', '25565', '--bounds', '0,0,0:10,10,10']), /only with the stress/)
  await assert.rejects(parse(['stress', '--port', '25565']), /controller/)
})

test('workload validation CLI checks the selected count and arena footprint before effects', async () => {
  const valid = await command(process.execPath, [cli, 'swarm-workload-validate', '--bots', '256', '--duration', '604800', '--json'])
  assert.equal(JSON.parse(valid.stdout).status, 'passed')
  assert.equal(JSON.parse(valid.stdout).workload.schedule[0].activeBots, 256)
  await assert.rejects(command(process.execPath, [cli, 'swarm-workload-validate', '--build-arena', '--bounds', '0,80,0:2,81,2', '--json']), (error) => {
    assert.equal(error.code, 2)
    assert.match(JSON.parse(error.stdout).error, /arena footprint/)
    return true
  })
})
