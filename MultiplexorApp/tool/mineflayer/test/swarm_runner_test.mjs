import assert from 'node:assert/strict'
import { EventEmitter } from 'node:events'
import { mkdtemp, readFile, readdir, rm } from 'node:fs/promises'
import os from 'node:os'
import path from 'node:path'
import test from 'node:test'

import { runSwarm } from '../src/swarm_runner.mjs'

const profiles = [
  { name: 'idle', requiresArena: false }, { name: 'wander', requiresArena: false },
  { name: 'workshop', requiresArena: true }, { name: 'stress', requiresArena: false }
]

async function fixture(t, options = {}) {
  const directory = await mkdtemp(path.join(os.tmpdir(), 'swarm-runner-'))
  t.after(() => rm(directory, { recursive: true, force: true }))
  const clients = []
  const signals = new EventEmitter()
  let clock = 0
  let viewersOpened = 0
  let viewersClosed = 0
  const configuration = {
    profile: 'wander', host: '127.0.0.1', port: 25565, auth: 'offline',
    instance: 'isolated-test', bots: 2, durationMs: 1000, seed: 42,
    joinIntervalMs: 100, radius: 16, prefix: 'Test', controller: 'Controller',
    buildArena: false, origin: { x: 0, y: 80, z: 0 }, connectTimeoutMs: 1000,
    actionTimeoutMs: 1000, artifactsDirectory: directory, viewerEnabled: true,
    ...options.configuration
  }
  const dependencies = {
    signals, now: () => clock, cleanupTimeoutMs: 20,
    createBot: (botOptions) => {
      const bot = new EventEmitter()
      Object.assign(bot, {
        username: botOptions.username, options: botOptions, version: '1.21.11',
        player: { uuid: `uuid-${botOptions.username}` },
        entity: { position: { x: 0.5, y: 81, z: 0.5 } },
        controlsCleared: 0, diggingStopped: 0, goalsCleared: 0, pathStopped: 0,
        quitCalls: 0, endCalls: 0,
        clearControlStates() { this.controlsCleared += 1 },
        stopDigging() { this.diggingStopped += 1 },
        quit() { this.quitCalls += 1; if (!options.hangQuit) queueMicrotask(() => this.emit('end', 'quit')) },
        end() { this.endCalls += 1; queueMicrotask(() => this.emit('end', 'forced')) }
      })
      bot.pathfinder = {
        setGoal: (goal) => { assert.equal(goal, null); bot.goalsCleared += 1 },
        stop: () => { bot.pathStopped += 1 }
      }
      clients.push(bot)
      queueMicrotask(() => {
        if (options.onConnect) options.onConnect(bot, clients)
        else bot.emit('spawn')
      })
      return bot
    },
    configureMovements: (bot) => { bot.movementsConfigured = true },
    startWebFeed: async ({ bot }) => {
      viewersOpened += 1
      assert.equal(bot.username, 'Test01')
      return { enabled: true, status: 'active', url: 'http://127.0.0.1:12345/' }
    },
    stopWebFeed: async (bot, state) => { viewersClosed += 1; state.status = 'closed' },
    behaviors: {
      SWARM_PROFILES: profiles,
      SwarmCoordinator: class {},
      prepareSwarmArena: async ({ bots, record }) => {
        for (const bot of bots) record({ bot: bot.username, action: 'arena', status: 'passed' })
        return { origin: configuration.origin, tiles: bots.map(() => ({ spawn: {} })) }
      },
      scatterSwarm: async ({ bots, record }) => {
        for (const bot of bots) record({ bot: bot.username, action: 'scatter', status: 'passed' })
      },
      runSwarmWorker: async ({ bot, index, record, deadline }) => {
        record({ bot: bot.username, index, action: 'walk', status: 'passed' })
        clock = deadline
      },
      ...options.behaviors
    },
    ...options.dependencies
  }
  return { configuration, dependencies, clients, signals, setClock: (value) => { clock = value },
    viewers: () => ({ opened: viewersOpened, closed: viewersClosed }) }
}

function assertClean(fixture, report) {
  assert.equal(fixture.signals.listenerCount('SIGINT'), 0)
  assert.equal(fixture.signals.listenerCount('SIGTERM'), 0)
  assert.equal(report.cleanup.disconnected, fixture.clients.length)
  for (const bot of fixture.clients) {
    assert.ok(bot.controlsCleared > 0)
    assert.ok(bot.diggingStopped > 0)
    assert.ok(bot.goalsCleared > 0)
    assert.ok(bot.pathStopped > 0)
  }
}

test('runner staggers workers, shares coordinator, records all workers, and closes one viewer', async (t) => {
  const fixture_ = await fixture(t)
  const joins = []
  const coordinators = []
  const original = fixture_.dependencies.createBot
  fixture_.dependencies.createBot = (options) => { joins.push(performance.now()); return original(options) }
  fixture_.dependencies.behaviors.runSwarmWorker = async ({ bot, record, coordinator, deadline }) => {
    coordinators.push(coordinator)
    record({ bot: bot.username, action: 'walk', status: 'passed' })
    fixture_.setClock(deadline)
  }
  const report = await runSwarm(fixture_.configuration, fixture_.dependencies)
  assert.equal(report.status, 'passed')
  assert.ok(joins[1] - joins[0] >= 80)
  assert.equal(report.controller, undefined)
  assert.deepEqual(report.bots.map((bot) => bot.actions), [1, 1])
  assert.equal(report.actionCounts.walk.passed, 2)
  assert.equal(coordinators[0], coordinators[1])
  assert.deepEqual(fixture_.viewers(), { opened: 1, closed: 1 })
  assert.equal(report.viewer.status, 'closed')
  assert.ok(fixture_.clients.every((bot) => bot.movementsConfigured && bot.options.auth === 'offline'))
  assert.equal(JSON.parse(await readFile(report.artifact)).status, 'passed')
  assertClean(fixture_, report)
})

test('arena controller is separate and setup actions cannot satisfy worker success', async (t) => {
  const fixture_ = await fixture(t, {
    configuration: { profile: 'workshop', buildArena: true },
    behaviors: { runSwarmWorker: async () => {} }
  })
  const report = await runSwarm(fixture_.configuration, fixture_.dependencies)
  assert.equal(report.status, 'failed')
  assert.match(report.errors[0].message, /No successful action/)
  assert.equal(report.controller.username, 'Controller')
  assert.equal(fixture_.clients.length, 3)
  assert.equal(report.bots.length, 2)
  assert.equal(report.setupActionCounts.arena.passed, 2)
  assert.deepEqual(report.bots.map((bot) => bot.actions), [0, 0])
  assertClean(fixture_, report)
})

test('failure during a partial join prevents more workers and cleans the owned client', async (t) => {
  const fixture_ = await fixture(t, {
    configuration: { bots: 4 },
    onConnect: (bot) => bot.emit('kicked', 'Test rejection')
  })
  const report = await runSwarm(fixture_.configuration, fixture_.dependencies)
  assert.equal(report.status, 'failed')
  assert.equal(fixture_.clients.length, 1)
  assert.match(report.errors[0].message, /kicked.*Test rejection/)
  assert.deepEqual(fixture_.viewers(), { opened: 0, closed: 0 })
  assertClean(fixture_, report)
})

test('worker death aborts concurrent actions and forces a client that ignores quit to end', async (t) => {
  let abortedWorkers = 0
  const fixture_ = await fixture(t, {
    hangQuit: true,
    behaviors: {
      runSwarmWorker: ({ bot, index, signal }) => new Promise((resolve, reject) => {
        signal.addEventListener('abort', () => { abortedWorkers += 1; reject(signal.reason) }, { once: true })
        if (index === 0) setImmediate(() => bot.emit('death'))
      })
    }
  })
  const report = await runSwarm(fixture_.configuration, fixture_.dependencies)
  assert.equal(report.status, 'failed')
  assert.match(report.errors[0].message, /died/)
  assert.equal(abortedWorkers, 2)
  assert.ok(report.bots.every((bot) => bot.forcedDisconnect))
  assert.ok(fixture_.clients.every((bot) => bot.endCalls === 1))
  assertClean(fixture_, report)
})

test('SIGTERM while connecting writes a cancelled report and cleans signal listeners', async (t) => {
  const fixture_ = await fixture(t, { onConnect: () => {} })
  const running = runSwarm(fixture_.configuration, fixture_.dependencies)
  setTimeout(() => fixture_.signals.emit('SIGTERM'), 10)
  const report = await running
  assert.equal(report.status, 'cancelled')
  assert.match(report.errors[0].message, /SIGTERM/)
  assert.equal(JSON.parse(await readFile(report.artifact)).status, 'cancelled')
  assertClean(fixture_, report)
})

test('connection timeout is bounded and reports failure instead of leaving a spawned listener', async (t) => {
  const fixture_ = await fixture(t, { configuration: { bots: 1 }, onConnect: () => {} })
  const started = performance.now()
  const report = await runSwarm(fixture_.configuration, fixture_.dependencies)
  assert.equal(report.status, 'failed')
  assert.match(report.errors[0].message, /spawn timed out/)
  assert.ok(performance.now() - started < 1800)
  assert.equal(fixture_.clients[0].listenerCount('spawn'), 0)
  assertClean(fixture_, report)
})

test('report retains bounded recent events with complete action totals', async (t) => {
  const fixture_ = await fixture(t, { configuration: { bots: 1 } })
  fixture_.dependencies.behaviors.runSwarmWorker = async ({ bot, record, deadline }) => {
    for (let index = 0; index < 800; index += 1) record({ bot: bot.username, action: 'walk', status: 'passed', detail: 'x'.repeat(1000) })
    fixture_.setClock(deadline)
  }
  const report = await runSwarm(fixture_.configuration, fixture_.dependencies)
  assert.equal(report.status, 'passed')
  assert.equal(report.events.length, 500)
  assert.equal(report.eventCount, 801)
  assert.equal(report.events[0].detail.length, 512)
  assert.equal(report.actionCounts.walk.passed, 800)
  assert.equal(report.bots[0].actions, 800)
})

test('custom plans may leave some actors idle but must finish every phase', async (t) => {
  const plan = { name: 'One actor', phases: [{ action: 'chat', actors: [1], messages: ['Ready'] }] }
  const fixture_ = await fixture(t, {
    configuration: { profile: 'custom', plan },
    dependencies: {
      plans: {
        validateSwarmPlan: (value, { bots }) => { assert.equal(bots, 2); return value },
        runSwarmPlan: async ({ bots, record }) => {
          record({ bot: bots[0].username, action: 'chat', status: 'passed' })
          record({ action: 'phase', phase: 1, status: 'passed' })
        }
      }
    }
  })
  const report = await runSwarm(fixture_.configuration, fixture_.dependencies)
  assert.equal(report.status, 'passed')
  assert.deepEqual(report.bots.map((bot) => bot.actions), [1, 0])
  assert.equal(report.controller.username, 'Controller')
  assertClean(fixture_, report)
})

test('direct runner calls validate loopback and plan before creating clients', async (t) => {
  const fixture_ = await fixture(t)
  await assert.rejects(runSwarm({ ...fixture_.configuration, host: 'example.org' }, fixture_.dependencies), /loopback/)
  assert.equal(fixture_.clients.length, 0)
  await assert.rejects(runSwarm({ ...fixture_.configuration, profile: 'custom', plan: {} }, {
    ...fixture_.dependencies, plans: { validateSwarmPlan: () => { throw new Error('Invalid plan') } }
  }), /Invalid plan/)
  assert.equal(fixture_.clients.length, 0)
})

test('scatter uses a separate controller and completes before the activity deadline begins', async (t) => {
  const fixture_ = await fixture(t, { configuration: { scatter: 32 } })
  fixture_.dependencies.behaviors.scatterSwarm = async ({ bots, controller, record }) => {
    assert.equal(controller.username, 'Controller')
    assert.equal(bots.length, 2)
    fixture_.setClock(5000)
    for (const bot of bots) record({ bot: bot.username, action: 'scatter', status: 'passed' })
  }
  fixture_.dependencies.behaviors.runSwarmWorker = async ({ bot, deadline, record }) => {
    assert.equal(deadline, 6000)
    record({ bot: bot.username, action: 'walk', status: 'passed' })
    fixture_.setClock(deadline)
  }
  const report = await runSwarm(fixture_.configuration, fixture_.dependencies)
  assert.equal(report.status, 'passed')
  assert.equal(report.setupActionCounts.scatter.passed, 2)
  assert.equal(report.actionCounts.scatter, undefined)
  assert.equal(report.actionDurationMs, 1000)
  assert.deepEqual(report.bots.map((bot) => bot.actions), [1, 1])
  assertClean(fixture_, report)
})

test('custom plan missing a completed phase cannot silently succeed', async (t) => {
  const fixture_ = await fixture(t, {
    configuration: { profile: 'custom', plan: { name: 'Wait', phases: [{ action: 'wait', seconds: 1 }] } },
    dependencies: { plans: { validateSwarmPlan: (plan) => plan, runSwarmPlan: async () => {} } }
  })
  const report = await runSwarm(fixture_.configuration, fixture_.dependencies)
  assert.equal(report.status, 'failed')
  assert.match(report.errors[0].message, /did not complete every phase/)
  assertClean(fixture_, report)
})

test('idle swarms allow zero actions but still fail unexpected disconnection during the requested duration', async (t) => {
  const fixture_ = await fixture(t, {
    configuration: { profile: 'idle', bots: 1 },
    behaviors: { runSwarmWorker: async ({ bot }) => { setTimeout(() => bot.emit('end', 'Connection lost'), 10) } }
  })
  const report = await runSwarm(fixture_.configuration, fixture_.dependencies)
  assert.equal(report.status, 'failed')
  assert.match(report.errors[0].message, /disconnected.*Connection lost/)
  assert.equal(report.bots[0].actions, 0)
  assertClean(fixture_, report)
})

async function stressFixture(t, options = {}) {
  const workload = { name: 'Stress test', bounds: { min: [0, 80, 0], max: [11, 85, 11] },
    completion: 'goals', goals: { patrol: 1 }, reportIntervalSeconds: 10 }
  return fixture(t, {
    ...options,
    configuration: { profile: 'stress', workload, ...options.configuration },
    dependencies: {
      workloads: { validateWorkload: (value) => value },
      stressActions: { createStressExecutor: async () => async () => ({ completed: 1 }) },
      stress: { runStressWorkload: async () => ({ status: 'passed', completed: 1, goals: { patrol: { target: 1, completed: 1, met: true } } }) },
      ...options.dependencies
    }
  })
}

test('stress setup is excluded from action time and goal completion ends a long run early', async (t) => {
  const fixture_ = await stressFixture(t, { configuration: { durationMs: 604800000 } })
  fixture_.dependencies.stressActions.createStressExecutor = async ({ bots, record }) => {
    fixture_.setClock(10000)
    record({ bot: bots[0].username, action: 'setup', status: 'passed' })
    return async () => ({ completed: 1 })
  }
  fixture_.dependencies.stress.runStressWorkload = async ({ bots, now, record, executeActivity }) => {
    assert.equal(now(), 10000)
    assert.deepEqual(await executeActivity(), { completed: 1 })
    fixture_.setClock(10050)
    record({ bot: bots[0].username, action: 'patrol', status: 'passed' })
    return { status: 'passed', completed: 1 }
  }
  const started = performance.now()
  const report = await runSwarm(fixture_.configuration, fixture_.dependencies)
  assert.equal(report.status, 'passed')
  assert.ok(performance.now() - started < 1000)
  assert.equal(report.actionDurationMs, 50)
  assert.equal(report.setupActionCounts.setup.passed, 1)
  assert.equal(report.actionCounts.patrol.passed, 1)
  assert.equal(report.workloadSummary.completed, 1)
  assertClean(fixture_, report)
})

test('running checkpoints are valid JSON with bounded host metrics and final status replaces them', async (t) => {
  const fixture_ = await stressFixture(t, {
    configuration: { bots: 1 },
    dependencies: {
      checkpointIntervalMs: 5, metricsHistoryLimit: 3,
      stress: { runStressWorkload: async () => { await new Promise((resolve) => setTimeout(resolve, 80)); return { status: 'passed', completed: 1 } } }
    }
  })
  const running = runSwarm(fixture_.configuration, fixture_.dependencies)
  await new Promise((resolve) => setTimeout(resolve, 40))
  const filename = (await readdir(fixture_.configuration.artifactsDirectory)).find((file) => file.endsWith('.json'))
  const checkpoint = JSON.parse(await readFile(path.join(fixture_.configuration.artifactsDirectory, filename)))
  assert.equal(checkpoint.status, 'running')
  assert.ok(checkpoint.checkpointCount >= 2)
  assert.equal(checkpoint.metrics.scope, 'node-process')
  assert.ok(checkpoint.metrics.history.length <= 3)
  assert.ok(checkpoint.metrics.latest.rssBytes > 0)
  assert.ok(Number.isFinite(checkpoint.metrics.latest.cpuPercent))
  const report = await running
  assert.equal(JSON.parse(await readFile(report.artifact)).status, 'passed')
  assert.ok(report.metrics.sampleCount > report.metrics.history.length)
  assertClean(fixture_, report)
})

test('an in-flight worker leaving bounds cancels the run and retains failed goal details', async (t) => {
  const fixture_ = await stressFixture(t, { configuration: { bots: 1 } })
  fixture_.dependencies.stress.runStressWorkload = ({ bots, signal }) => new Promise((resolve, reject) => {
    signal.addEventListener('abort', () => reject(Object.assign(new Error('Bounds interrupted workload'),
      { summary: { status: 'failed', goals: { patrol: { target: 1, completed: 0, met: false } } } })), { once: true })
    setImmediate(() => { bots[0].entity.position.x = -0.5; bots[0].emit('move') })
  })
  const report = await runSwarm(fixture_.configuration, fixture_.dependencies)
  assert.equal(report.status, 'failed')
  assert.match(report.errors[0].message, /left the configured workload bounds/)
  assert.equal(report.workloadSummary.goals.patrol.met, false)
  assertClean(fixture_, report)
})

test('stress failure summaries survive scheduler rejection and final report persistence', async (t) => {
  const fixture_ = await stressFixture(t, { configuration: { bots: 1 } })
  fixture_.dependencies.stress.runStressWorkload = async () => {
    throw Object.assign(new Error('Goals were not met'), { summary: { status: 'failed', completed: 0 } })
  }
  const report = await runSwarm(fixture_.configuration, fixture_.dependencies)
  assert.equal(report.status, 'failed')
  assert.equal(report.workloadSummary.completed, 0)
  assert.equal(JSON.parse(await readFile(report.artifact)).workloadSummary.status, 'failed')
  assertClean(fixture_, report)
})
