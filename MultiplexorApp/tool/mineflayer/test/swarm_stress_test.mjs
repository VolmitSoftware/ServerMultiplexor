import assert from 'node:assert/strict'
import { getEventListeners } from 'node:events'
import test from 'node:test'
import { pause, seededRandom } from '../src/swarm_actions.mjs'
import { assignRoles, validateWorkload } from '../src/swarm_workload.mjs'
import { runStressWorkload, StressCoordinator, weightedChoice } from '../src/swarm_stress.mjs'

function fixture({ workers = 2, durationMs = 1000, workload: changes = {} } = {}) {
  const workload = validateWorkload({
    schemaVersion: 1, name: 'Scheduler test', roles: [{ name: 'player', weight: 1, activities: { patrol: 4, chat: 1 } }],
    pacing: { minMs: 0, maxMs: 1 }, ...changes
  }, { bots: workers, durationMs: Math.max(1000, durationMs), buildArena: true })
  return {
    bots: Array.from({ length: workers }, (_, index) => ({ username: `Worker${index + 1}`, clearControlStates() {} })),
    configuration: { bots: workers, durationMs, seed: 19, actionTimeoutMs: 100, workload },
    signal: new AbortController().signal
  }
}

test('role populations preserve rare roles when workers permit and respect weights', () => {
  const roles = [{ name: 'miner', weight: 5, activities: { mine: 1 } }, { name: 'builder', weight: 2, activities: { build: 1 } }, { name: 'farmer', weight: 1, activities: { farm: 1 } }]
  assert.deepEqual(assignRoles(roles, 3).map((role) => role.name), ['miner', 'builder', 'farmer'])
  const population = assignRoles(roles, 11).reduce((counts, role) => ({ ...counts, [role.name]: (counts[role.name] ?? 0) + 1 }), {})
  assert.deepEqual(population, { miner: 6, builder: 3, farmer: 2 })
  const sequence = () => {
    const random = seededRandom(19)
    return Array.from({ length: 100 }, () => weightedChoice({ mine: 5, build: 1 }, random))
  }
  assert.deepEqual(sequence(), sequence())
  assert(sequence().filter((name) => name === 'mine').length > 70)
})

test('unreachable assigned-role goals fail workload validation before setup', () => {
  assert.throws(() => validateWorkload({
    schemaVersion: 1, name: 'No farmer', completion: 'goals', goals: { farm: 1 },
    roles: [{ name: 'miner', weight: 100, activities: { mine: 1 } }, { name: 'farmer', weight: 1, activities: { farm: 1 } }]
  }, { bots: 1, buildArena: true }), /no assigned active worker/)
})

test('goals count verified operations and cancel remaining workers promptly', async () => {
  const options = fixture({ workload: { completion: 'goals', goals: { patrol: 5 } } })
  let inFlight = 0
  const records = []
  const summary = await runStressWorkload({ ...options, record: (event) => records.push(event), executeActivity: async ({ signal, activity }) => {
    inFlight++
    try { await pause(3, signal); return { counts: { [activity]: 1 } } } finally { inFlight-- }
  } })
  assert.equal(summary.status, 'passed')
  assert.equal(summary.counts.patrol, 5)
  assert(summary.elapsedMs < 200)
  assert.equal(inFlight, 0)
  assert.equal(summary.goals.patrol.met, true)
  assert.equal(summary.latency.patrol.count, 5)
  assert.equal(records.at(-1).type, 'stress-summary')
  assert.equal(records.at(-1).summary.status, 'passed')
})

test('duration mode continues after quotas are met and keeps constant-size latency buckets', async () => {
  const options = fixture({ durationMs: 100, workload: { completion: 'duration', goals: { patrol: 1 } } })
  const summary = await runStressWorkload({ ...options, executeActivity: async ({ activity, signal }) => { await pause(2, signal); return { counts: { [activity]: 1 } } } })
  assert(summary.elapsedMs >= 90)
  assert(summary.completed > 5)
  assert.equal(summary.goals.patrol.met, true)
  assert.equal(summary.latency.patrol.buckets.length, 14)
  assert.equal(summary.latency.patrol.buckets.reduce((total, bucket) => total + bucket.count, 0), summary.counts.patrol)
})

test('blocked jobs never advance goals and a run with no productive work fails', async () => {
  const options = fixture({ durationMs: 50, workload: { completion: 'goals', goals: { patrol: 1 } } })
  await assert.rejects(runStressWorkload({ ...options, executeActivity: async () => ({ status: 'skipped', reason: 'all targets leased' }) }), (error) => {
    assert.match(error.message, /goals were not reached/)
    assert.equal(error.summary.completed, 0)
    assert.equal(error.summary.failed, 0)
    assert(error.summary.skipped >= options.bots.length)
    assert.equal(error.summary.attempted, error.summary.skipped)
    assert.deepEqual(error.summary.latency, {})
    return true
  })
})

test('target reservations exclude overlap and release after failure', async () => {
  const coordinator = new StressCoordinator()
  let release
  const first = coordinator.claim([1, 80, 2], () => new Promise((resolve) => { release = resolve }))
  assert.equal(coordinator.reserved, 1)
  assert.equal((await coordinator.claim({ x: 1, y: 80, z: 2 }, () => assert.fail('overlap'))).status, 'skipped')
  release('done')
  assert.equal(await first, 'done')
  await assert.rejects(coordinator.claim([1, 80, 2], () => { throw new Error('job failed') }), /job failed/)
  assert.equal(coordinator.reserved, 0)
})

test('recoverable failures back off, retry, and stay separate from verified counts', async () => {
  const options = fixture({ workers: 1, durationMs: 2000, workload: { completion: 'goals', goals: { patrol: 2 } } })
  let attempts = 0
  const summary = await runStressWorkload({ ...options, executeActivity: async () => {
    if (++attempts === 1) throw new Error('blocked route')
    return { counts: { patrol: 1 } }
  } })
  assert.equal(summary.failed, 1)
  assert.equal(summary.completed, 2)
  assert.equal(summary.counts.patrol, 2)
  assert(summary.elapsedMs >= 490)
  assert.equal(summary.workers[0].consecutiveFailures, 0)
})

test('fatal errors stop immediately while ordinary failures obey budgets', async () => {
  for (const fatal of [false, true]) {
    const options = fixture({ workers: 1, workload: { failurePolicy: { maxConsecutive: 1, maxTotal: 3 } } })
    let attempts = 0
    await assert.rejects(runStressWorkload({ ...options, executeActivity: async () => {
      attempts++
      const error = new Error('cannot continue')
      error.fatal = fatal
      throw error
    } }), (error) => {
      assert.equal(error.summary.failed, 1)
      assert.equal(error.summary.status, 'failed')
      return true
    })
    assert.equal(attempts, 1)
  }
})

test('deadline cancellation waits for active cleanup and removes parent listeners', async () => {
  const parent = new AbortController()
  const options = fixture({ workers: 1, durationMs: 80 })
  let cleaned = false
  let attempts = 0
  await assert.rejects(runStressWorkload({ ...options, signal: parent.signal, executeActivity: async ({ signal }) => {
    attempts++
    try { await pause(10000, signal) } finally { await pause(15); cleaned = true }
  } }), /no productive activities/)
  assert(cleaned)
  assert.equal(attempts, 1)
  assert.equal(getEventListeners(parent.signal, 'abort').length, 0)
})

test('parent cancellation preserves a cancelled summary after every worker settles', async () => {
  const parent = new AbortController()
  const options = fixture()
  let active = 0
  const task = runStressWorkload({ ...options, signal: parent.signal, executeActivity: async ({ signal }) => {
    active++
    try { await pause(10000, signal) } finally { active-- }
  } })
  setTimeout(() => parent.abort(new Error('operator cancelled')), 10)
  await assert.rejects(task, (error) => {
    assert.equal(error.message, 'operator cancelled')
    assert.equal(error.summary.status, 'cancelled')
    return true
  })
  assert.equal(active, 0)
})

test('load stages activate extra workers and emit bounded periodic summaries', async (context) => {
  context.mock.timers.enable({ apis: ['setTimeout', 'setInterval', 'Date'], now: 0 })
  const options = fixture({ durationMs: 1150, workload: { reportIntervalSeconds: 1, schedule: [{ atSeconds: 0, activeBots: 1 }, { atSeconds: 1, activeBots: 2 }] } })
  const records = []
  let firstSecondWorker
  const advance = async (milliseconds) => {
    for (let elapsed = 0; elapsed < milliseconds; elapsed++) {
      context.mock.timers.tick(1)
      await new Promise((resolve) => setImmediate(resolve))
    }
  }
  const task = runStressWorkload({ ...options, now: () => Date.now(), record: (event) => records.push(event), executeActivity: async ({ index, activity, signal }) => {
    if (index === 1 && firstSecondWorker === undefined) firstSecondWorker = Date.now()
    await pause(3, signal)
    return { counts: { [activity]: 1 } }
  } })
  await advance(999)
  assert.equal(firstSecondWorker, undefined)
  assert.equal(records.filter((event) => event.type === 'stress-stage').length, 0)
  assert.equal(records.filter((event) => event.type === 'stress-summary').length, 1)
  await advance(1)
  assert.equal(firstSecondWorker, 1000)
  assert.equal(records.filter((event) => event.type === 'stress-summary').length, 2)
  await advance(150)
  const summary = await task
  assert.equal(summary.elapsedMs, 1150)
  assert.equal(summary.scheduleIndex, 1)
  assert(summary.workers.every((worker) => worker.completed > 0))
  assert.equal(records.filter((event) => event.type === 'stress-stage').length, 1)
  assert.equal(records.filter((event) => event.type === 'stress-summary').length, 3)
})

test('malformed executor counts cannot satisfy goals or silently inflate evidence', async () => {
  const options = fixture({ workers: 1, workload: { goals: { patrol: 1 }, completion: 'goals' } })
  for (const counts of [{ patrol: 0 }, { patrol: NaN }, {}, { unknown: 100 }, { patrol: 1.5 }]) {
    await assert.rejects(runStressWorkload({ ...options, executeActivity: async () => ({ counts }) }), /invalid verified counts/)
  }
})

test('movement totals aggregate verified distances and worker-local chunk visits', async () => {
  const options = fixture({ workers: 1, workload: { goals: { patrol: 2 }, completion: 'goals' } })
  const events = []
  const summary = await runStressWorkload({ ...options, record: (event) => events.push(event), executeActivity: async () => ({ counts: { patrol: 1 }, distance: 12.5, chunks: 2, destination: { x: 1, y: 80, z: 2 }, item: 'stone', count: 3, message: 'Moving supplies' }) })
  assert.equal(summary.blocksWalked, 25)
  assert.equal(summary.newChunkVisits, 4)
  assert.equal(summary.workers[0].blocksWalked, 25)
  assert.equal(summary.workers[0].newChunkVisits, 4)
  const completed = events.find((event) => event.status === 'passed')
  assert.deepEqual(completed.destination, [1, 80, 2])
  assert.equal(completed.message, 'Moving supplies')
})

test('action timeout settles previous bot ownership before a retry starts', async () => {
  const options = fixture({ workers: 1, durationMs: 1200, workload: { goals: { patrol: 1 }, completion: 'goals' } })
  options.configuration.actionTimeoutMs = 10
  let attempts = 0
  let active = 0
  let maximumActive = 0
  const summary = await runStressWorkload({ ...options, executeActivity: async ({ signal }) => {
    active++
    maximumActive = Math.max(maximumActive, active)
    try {
      if (++attempts === 1) await pause(10000, signal)
      return { counts: { patrol: 1 } }
    } finally {
      if (attempts === 1) await pause(20)
      active--
    }
  } })
  assert.equal(maximumActive, 1)
  assert.equal(active, 0)
  assert.equal(summary.failed, 1)
  assert.equal(summary.completed, 1)
})

test('invalid movement metrics fail without partially updating verified evidence', async () => {
  const options = fixture({ workers: 1 })
  await assert.rejects(runStressWorkload({ ...options, executeActivity: async () => ({ counts: { patrol: 1 }, distance: 8, chunks: NaN }) }), (error) => {
    assert.match(error.message, /invalid chunks/)
    assert.equal(error.summary.blocksWalked, 0)
    assert.equal(error.summary.completed, 0)
    assert.deepEqual(error.summary.counts, {})
    return true
  })
})

test('goal selection retains replenishment activities after their smaller quota is met', async () => {
  const options = fixture({ workers: 1, durationMs: 4000, workload: {
    roles: [{ name: 'player', weight: 1, activities: { mine: 1, build: 1 } }],
    completion: 'goals', goals: { mine: 5, build: 1 }
  } })
  let stock = 0
  const summary = await runStressWorkload({ ...options, executeActivity: async ({ activity }) => {
    if (activity === 'build') stock += 2
    else if (stock > 0) stock--
    else return { status: 'skipped', reason: 'Mining needs a builder to refill the work area' }
    return { counts: { [activity]: 1 } }
  } })
  assert.equal(summary.counts.mine, 5)
  assert(summary.counts.build >= 3)
  assert.equal(summary.goals.build.met, true)
  assert.equal(summary.status, 'passed')
})

test('duration expiry aborts in-flight inventory work as normal completion', async () => {
  const options = fixture({ workers: 1, durationMs: 60 })
  options.configuration.actionTimeoutMs = 1000
  let attempts = 0
  let reasonName
  let cleaned = false
  const summary = await runStressWorkload({ ...options, executeActivity: async ({ signal }) => {
    if (++attempts === 1) return { counts: { patrol: 1 } }
    try { await pause(10000, signal) } catch (error) {
      reasonName = signal.reason.constructor.name
      if (reasonName !== 'RunComplete') error.fatal = true
      throw error
    } finally { await pause(5); cleaned = true }
  } })
  assert.equal(reasonName, 'RunComplete')
  assert(cleaned)
  assert.equal(summary.failed, 0)
  assert.equal(summary.completed, 1)
  assert.equal(summary.status, 'passed')
})
