import test from 'node:test'
import assert from 'node:assert/strict'
import { mkdtemp, rm, writeFile } from 'node:fs/promises'
import os from 'node:os'
import path from 'node:path'
import { createSessionTelemetry, readObserverSnapshot } from '../src/sessions/telemetry.mjs'

async function fixture(t) {
  const directory = await mkdtemp(path.join(os.tmpdir(), 'session-observer-'))
  t.after(() => rm(directory, { recursive: true, force: true }))
  const file = path.join(directory, 'metrics.json')
  const now = Date.now()
  const snapshot = {
    schemaVersion: 1, kind: 'paper', status: 'running', observedAt: new Date(now).toISOString(),
    worlds: [], players: [], events: [], tick: { count: 40, p50Ms: 4, p95Ms: 60, p99Ms: 100, maxMs: 120, longTicks: 3 }
  }
  await writeFile(file, JSON.stringify(snapshot))
  return { file, now, snapshot }
}

test('observer missing, malformed, stale and future snapshots stay unavailable', async (t) => {
  const { file, now, snapshot } = await fixture(t)
  assert.equal((await readObserverSnapshot()).status, 'missing')
  assert.equal((await readObserverSnapshot(file, { now: () => now + 16000 })).status, 'stale')
  assert.equal((await readObserverSnapshot(file, { now: () => now - 6000 })).status, 'invalid')
  await writeFile(file, '{')
  assert.equal((await readObserverSnapshot(file)).status, 'invalid')
  await writeFile(file, JSON.stringify({ ...snapshot, tick: { ...snapshot.tick, p95Ms: -1 } }))
  assert.equal((await readObserverSnapshot(file)).status, 'invalid')
})

test('telemetry retains breaches after a healthy sample and validates required coverage', async (t) => {
  const { file, now, snapshot } = await fixture(t)
  const collector = createSessionTelemetry({
    target: { kind: 'instance', backends: [{ alias: 'survival', observerPath: file }] },
    profile: { telemetry: { required: true, maxP95TickMs: 50, warmupSeconds: 0 } }, now: () => now
  })
  await collector.sample()
  await writeFile(file, JSON.stringify({ ...snapshot, tick: { ...snapshot.tick, p95Ms: 10 } }))
  await collector.sample()
  assert.equal(collector.summary().status, 'failed')
  assert.equal(collector.summary().violations['survival.p95Ms'], 1)
  const missing = createSessionTelemetry({ target: { backends: [{ alias: 'missing' }] }, profile: { telemetry: { required: true } } })
  await missing.sample()
  assert.equal(missing.summary().status, 'failed')
})

test('warmup does not report a short run as a measured performance pass', async (t) => {
  const { file, now } = await fixture(t)
  const collector = createSessionTelemetry({ target: { kind: 'instance', backends: [{ alias: 'town', observerPath: file }] }, profile: {}, now: () => now })
  await collector.sample()
  assert.equal(collector.summary().status, 'unavailable')
  assert.equal(collector.summary().evaluatedSamples, 0)
})

test('observer coverage without acceptance limits reports measured performance', async (t) => {
  const { file, now } = await fixture(t)
  const collector = createSessionTelemetry({
    target: { kind: 'instance', backends: [{ alias: 'town', observerPath: file }] },
    profile: { telemetry: { required: true, warmupSeconds: 0 } }, now: () => now
  })
  await collector.sample()
  assert.equal(collector.summary().status, 'measured')
  assert.equal(collector.summary().limitsConfigured, false)
})

test('proxy destinations require fresh observed state', async (t) => {
  const { file, now, snapshot } = await fixture(t)
  let clock = now
  await writeFile(file, JSON.stringify({ ...snapshot, kind: 'velocity', players: [{ username: 'Returning01', backend: 'survival' }] }))
  const collector = createSessionTelemetry({ target: { kind: 'network', observerPath: file, backends: [] }, profile: {}, now: () => clock })
  await collector.sample()
  assert.equal(collector.currentBackend('Returning01'), 'survival')
  assert.equal(collector.currentBackend('Unknown'), undefined)
  clock += 16000
  assert.equal(collector.currentBackend('Returning01'), undefined)
})

test('resume retains performance breaches while routing waits for a fresh snapshot', async (t) => {
  const { file, now, snapshot } = await fixture(t)
  const options = {
    target: { kind: 'instance', backends: [{ alias: 'town', observerPath: file }] },
    profile: { telemetry: { required: true, maxP95TickMs: 50, warmupSeconds: 0 } }, now: () => now
  }
  const previous = createSessionTelemetry(options)
  await previous.sample()
  await writeFile(file, JSON.stringify({ ...snapshot, tick: { ...snapshot.tick, p95Ms: 10 } }))
  const resumed = createSessionTelemetry({ ...options, initialState: JSON.parse(JSON.stringify(previous.checkpoint())) })
  assert.equal(resumed.currentBackend('Returning01'), undefined)
  await resumed.sample()
  assert.equal(resumed.summary().status, 'failed')
  assert.equal(resumed.summary().samples, 2)
  assert.equal(resumed.summary().violations['town.p95Ms'], 1)
})

test('Folia process observations stay available without inventing tick threshold passes', async (t) => {
  const { file, now, snapshot } = await fixture(t)
  await writeFile(file, JSON.stringify({ ...snapshot, platform: 'folia', tick: null,
    capabilities: { globalTickTimings: false, regionTickTimings: false },
    process: { heapUsedBytes: 1000 },
    worlds: [{ id: 'world-id', name: 'world', loadedChunks: null, entities: null }]
  }))
  const options = { target: { kind: 'instance', backends: [{ alias: 'regions', observerPath: file }] }, now: () => now }
  const observed = await readObserverSnapshot(file, { now: () => now, kind: 'paper' })
  assert.equal(observed.status, 'available')
  assert.equal(observed.snapshot.tick, null)
  const processOnly = createSessionTelemetry({ ...options, profile: { telemetry: { required: true, warmupSeconds: 0 } } })
  await processOnly.sample()
  assert.equal(processOnly.summary().status, 'measured')
  const timingRequired = createSessionTelemetry({ ...options,
    profile: { telemetry: { required: true, maxP95TickMs: 50, warmupSeconds: 0 } } })
  await timingRequired.sample()
  assert.equal(timingRequired.summary().status, 'failed')
  assert.equal(timingRequired.summary().unavailableSamples, 1)
  assert.deepEqual(timingRequired.summary().violations, {})
})
