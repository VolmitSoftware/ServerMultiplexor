import assert from 'node:assert/strict'
import { spawnSync } from 'node:child_process'
import test from 'node:test'
import { fileURLToPath } from 'node:url'
import { protocolCapability } from '../src/protocol_capability.mjs'

function layers() {
  const states = Object.fromEntries(['handshaking', 'status', 'login', 'configuration', 'play'].map(state => [state, { toServer: {}, toClient: {} }]))
  return {
    data: () => ({ version: { minecraftVersion: '26.1', version: 775 }, protocol: states, blocks: [], items: [], entities: [] }),
    mineflayer: { testedVersions: ['26.1'] },
    protocol: { createSerializer: () => ({ destroy() {} }), createDeserializer: () => ({ destroy() {} }) },
    packets: () => undefined,
    packages: { mineflayer: 'fixture', 'minecraft-data': 'fixture', 'minecraft-protocol': 'fixture' }
  }
}

test('metadata without usable data is unsupported and never compiles an older codec', async () => {
  const dependencies = layers()
  dependencies.data = () => null
  dependencies.protocol.createSerializer = () => assert.fail('No codec should be created')
  const result = await protocolCapability('26.2', dependencies)
  assert.equal(result.status, 'unsupported')
  assert.equal(result.dataAvailable, false)
  assert.equal(result.resolvedVersion, null)
  assert.deepEqual(result.codecs, [])
  assert.match(result.errors[0], /no usable data for 26\.2/)
})

test('offline capability requires Mineflayer support in addition to data and codecs', async () => {
  const dependencies = layers()
  dependencies.mineflayer.testedVersions = []
  const result = await protocolCapability('26.1', dependencies)
  assert.equal(result.status, 'unsupported')
  assert.equal(result.codecs.length, 10)
  assert.equal(result.mineflayerTested, false)
})

test('codec failure identifies the state and direction without reporting support', async () => {
  const dependencies = layers()
  dependencies.protocol.createDeserializer = options => {
    if (options.state === 'play') throw new Error('Missing component codec')
    return { destroy() {} }
  }
  const result = await protocolCapability('26.1', dependencies)
  assert.equal(result.status, 'unsupported')
  assert.deepEqual(result.codecs.filter(codec => codec.status === 'failed'), [
    { state: 'play', direction: 'toClient', status: 'failed', error: 'Missing component codec' }
  ])
})

test('missing required protocol state and missing item data fail capability', async () => {
  const dependencies = layers()
  const data = dependencies.data()
  delete data.items
  delete data.protocol.login
  dependencies.data = () => data
  const result = await protocolCapability('26.1', dependencies)
  assert.equal(result.status, 'unsupported')
  assert.equal(result.dataAvailable, false)
  assert.equal(result.codecs.filter(codec => codec.state === 'login' && codec.status === 'failed').length, 2)
})

test('blank malformed and oversized requested versions are rejected', async () => {
  for (const version of ['', '26.2,26.3', '--json', '26.1\n', '2'.repeat(65)]) {
    await assert.rejects(protocolCapability(version, layers()), /one Minecraft version/)
  }
})

test('dependency and lookup failures retain structured target evidence', async () => {
  const missing = layers()
  delete missing.protocol
  const brokenData = layers()
  brokenData.data = () => { throw new Error('Corrupt data mapping') }
  const brokenPackets = layers()
  brokenPackets.packets = () => { throw new Error('Cannot load protocol override') }
  for (const [dependencies, expected] of [
    [missing, /dependency loading: .*dependency API is unavailable/],
    [brokenData, /minecraft-data lookup: Corrupt data mapping/],
    [brokenPackets, /protocol override loading: Cannot load protocol override/]
  ]) {
    const result = await protocolCapability('26.1', dependencies)
    assert.equal(result.status, 'unsupported')
    assert.equal(result.dependencyFailure, true)
    assert.equal(result.requestedVersion, '26.1')
    assert.match(result.errors[0], expected)
    assert.deepEqual(result.codecs, [])
  }
})

for (const version of ['1.21.11', '26.1', '26.1.2']) {
  test(`${version} compiles installed codecs without connecting and reports real resolution`, async () => {
    const result = await protocolCapability(version)
    assert.equal(result.status, 'supported')
    assert.equal(result.resolvedVersion, version === '26.1.2' ? '26.1' : version)
    assert.equal(result.protocolVersion, version === '1.21.11' ? 774 : 775)
    assert.equal(result.codecs.length, 10)
    assert.ok(result.codecs.every(codec => codec.status === 'passed'))
    assert.match(result.scope, /joining and gameplay remain unverified/)
  })
}

for (const version of ['26.2', '26.3']) {
  test(`${version} is not supplied by the pinned installed protocol stack`, async () => {
    const result = await protocolCapability(version)
    assert.equal(result.status, 'unsupported')
    assert.equal(result.dataAvailable, false)
    assert.equal(result.resolvedVersion, null)
  })
}

test('doctor separates dependency health from target support and retains untargeted output', () => {
  const cli = fileURLToPath(new URL('../src/cli.mjs', import.meta.url))
  const ordinary = spawnSync(process.execPath, [cli, 'doctor', '--json'], { encoding: 'utf8', timeout: 15000 })
  assert.equal(ordinary.status, 0, ordinary.stderr)
  const ordinaryReport = JSON.parse(ordinary.stdout)
  assert.equal(ordinaryReport.status, 'passed')
  assert.equal('protocolCapability' in ordinaryReport, false)
  assert.equal('dependencyStatus' in ordinaryReport, false)
  for (const version of ['26.1.2', '26.2', '26.3']) {
    const targeted = spawnSync(process.execPath, [cli, 'doctor', '--version', version, '--json'], { encoding: 'utf8', timeout: 15000 })
    assert.equal(targeted.status, version === '26.1.2' ? 0 : 1, targeted.stderr)
    const report = JSON.parse(targeted.stdout)
    assert.equal(report.dependencyStatus, 'passed')
    assert.equal(report.protocolCapability.requestedVersion, version)
  }
  const missing = spawnSync(process.execPath, [cli, 'doctor', '--version', '--json'], { encoding: 'utf8', timeout: 15000 })
  assert.equal(missing.status, 2)
  assert.match(JSON.parse(missing.stdout).error, /requires one Minecraft version/)
})
