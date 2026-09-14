import assert from 'node:assert/strict'
import test from 'node:test'
import { defaultWorkload, loadWorkload, normalizeBounds, containsPosition, validateWorkload } from '../src/swarm_workload.mjs'

const options = { bots: 4, durationMs: 60000, buildArena: true, origin: { x: 0, y: 80, z: 0 } }
const raw = (overrides = {}) => ({ schemaVersion: 1, name: 'Test workload', roles: [{ name: 'player', weight: 1, activities: { patrol: 3, mine: 1, build: 1, chat: 1 } }], ...overrides })

test('default workloads cover real player activities and validate idempotently', () => {
  const arena = defaultWorkload(options)
  assert.deepEqual(Object.keys(arena.roles[0].activities), ['patrol', 'explore', 'mine', 'build', 'redstone', 'farm', 'craft', 'storage', 'chat', 'idle'])
  assert.deepEqual(arena.bounds, { min: [0, 80, 0], max: [23, 85, 23] })
  assert.deepEqual(validateWorkload(arena, options), arena)
  const outdoor = defaultWorkload({ bots: 256, durationMs: 7 * 24 * 3600000, radius: 64 })
  assert.deepEqual(Object.keys(outdoor.roles[0].activities), ['patrol', 'explore', 'chat', 'idle'])
  assert.deepEqual(outdoor.bounds, { min: [-64, -48, -64], max: [64, 256, 64] })
})

test('bounds include fractional block cells and reject malformed or reversed corners', () => {
  const bounds = normalizeBounds('-10,80,-10:10,90,10')
  assert(containsPosition(bounds, { x: 10.99, y: 90.5, z: -10 }))
  assert(!containsPosition(bounds, [11, 80, 0]))
  assert(!containsPosition(bounds, [-10.01, 80, 0]))
  assert(!containsPosition(bounds, [0, NaN, 0]))
  for (const value of ['0,80:1,90,1', '1,80,1:0,90,0', '0,80,0:1,80,1', '0,-49,0:1,90,1', { min: [0, 80, 0], max: [1, 90, 1], extra: true }]) {
    assert.throws(() => normalizeBounds(value))
  }
})

test('arena bounds reject any fixture extent outside the box before setup', () => {
  assert.throws(() => validateWorkload(raw(), { ...options, bounds: '0,80,0:22,85,23' }), /complete arena/)
  assert.throws(() => defaultWorkload({ ...options, origin: { x: 0, y: 252, z: 0 } }), /256/)
  assert.throws(() => defaultWorkload({ ...options, origin: { x: 29998999, y: 80, z: 0 } }), /29999000/)
})

test('explicit target edits require locations and cannot escape overriding bounds', () => {
  const workload = raw({ bounds: { min: [0, 80, 0], max: [30, 100, 30] }, targets: { mine: [[25, 81, 25]], build: [[26, 81, 25]] } })
  assert.doesNotThrow(() => validateWorkload(workload, { ...options, buildArena: false }))
  assert.throws(() => validateWorkload(workload, { ...options, buildArena: false, bounds: '0,80,0:20,100,20' }), /outside/)
  assert.throws(() => validateWorkload(raw(), { ...options, buildArena: false }), /explicit targets/)
  assert.throws(() => validateWorkload(raw({ targets: { mine: [[1, 81, 1], [1, 81, 1]] } }), options), /duplicate/)
})

test('roles, goals, pacing, failure budgets, and workload fields reject invalid input', () => {
  for (const workload of [
    raw({ schemaVersion: 2 }), raw({ extra: true }), raw({ roles: [] }),
    raw({ roles: [{ name: 'player', activities: { teleport: 1 } }] }),
    raw({ roles: [{ name: 'player', activities: { patrol: -1 } }] }),
    raw({ roles: [{ name: 'player', activities: { idle: 1 } }] }),
    raw({ goals: { storage: 1 } }), raw({ goals: { mine: 0 } }),
    raw({ completion: 'goals' }), raw({ completion: 'whenever' }),
    raw({ pacing: { minMs: 200, maxMs: 100 } }),
    raw({ failurePolicy: { maxTotal: 0 } }), raw({ reportIntervalSeconds: 0 }),
    raw({ stallTimeoutSeconds: 4 }), raw({ messages: ['/op stranger'] }),
    raw({ messages: ['unsupported {target}'] }), raw({ messages: ['line\nbreak'] }), raw({ messages: ['{bot}'.repeat(30)] })
  ]) assert.throws(() => validateWorkload(workload, options))
  const result = validateWorkload(raw({ goals: { mine: 10 } }), { ...options, goals: { build: 5 }, completion: 'goals' })
  assert.deepEqual(result.goals, { build: 5 })
  assert.equal(result.completion, 'goals')
})

test('load schedule stays ordered, within run duration, and within connected population', () => {
  for (const schedule of [
    [], [{ atSeconds: 1, activeBots: 1 }], [{ atSeconds: 0, activeBots: 5 }],
    [{ atSeconds: 0, activeBots: 0 }], [{ atSeconds: 0, activeBots: 1 }, { atSeconds: 60, activeBots: 2 }],
    [{ atSeconds: 0, activeBots: 1 }, { atSeconds: 10, activeBots: 2 }, { atSeconds: 10, activeBots: 4 }]
  ]) assert.throws(() => validateWorkload(raw({ schedule }), options))
  assert.deepEqual(validateWorkload(raw({ schedule: [{ atSeconds: 0, activeBots: 0 }, { atSeconds: 10, activeBots: 4 }] }), options).schedule, [{ atSeconds: 0, activeBots: 0 }, { atSeconds: 10, activeBots: 4 }])
})

test('shipped endurance and goal workloads validate at their documented sizes', async () => {
  const endurance = await loadWorkload(new URL('../workloads/mixed-endurance.json', import.meta.url), { ...options, bots: 32, durationMs: 28800000 })
  assert.equal(endurance.schedule.at(-1).atSeconds, 21600)
  const goals = await loadWorkload(new URL('../workloads/mixed-goals.json', import.meta.url), { ...options, durationMs: 3600000 })
  assert.equal(goals.completion, 'goals')
  const outdoor = await loadWorkload(new URL('../workloads/outdoor-endurance.json', import.meta.url), { ...options, buildArena: false, bots: 16, durationMs: 14400000 })
  assert.equal(outdoor.roles.length, 2)
})
