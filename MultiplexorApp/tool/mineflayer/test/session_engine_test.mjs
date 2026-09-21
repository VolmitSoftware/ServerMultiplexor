import assert from 'node:assert/strict'
import { EventEmitter } from 'node:events'
import { mkdtemp, readFile, rm, writeFile } from 'node:fs/promises'
import os from 'node:os'
import path from 'node:path'
import { performance } from 'node:perf_hooks'
import test from 'node:test'
import { validateSessionProfile, validateSessionConfiguration, playerNames, profileFingerprint } from '../src/sessions/configuration.mjs'
import { defaultSettlementWorld } from '../src/sessions/world.mjs'
import { admitNextArrival, arrivalsDue, createRoster, desiredPopulation, goalsSatisfied, prepareResume, randomFor, recordLatency, SessionConnectionGate } from '../src/sessions/scheduler.mjs'
import { atomicJson, createSessionStore, SessionLeases } from '../src/sessions/store.mjs'
import { backendFromMessage, cancelBot, confirmBackend, createSessionTransport, delay, installArrivalReadiness, installConfigurationBarrier, reasonText } from '../src/sessions/transport.mjs'
import { executeBounded } from '../src/sessions/executor.mjs'
import { runSessions } from '../src/sessions/runner.mjs'

function profile(overrides = {}) {
  const world = { ...defaultSettlementWorld(), setup: { kind: 'existing' }, buildPlots: [] }
  return validateSessionProfile({ schemaVersion: 1, name: 'Engine test', durationSeconds: 2.7,
    population: { identities: 2, concurrent: 1, sessionSeconds: [1, 1], offlineSeconds: [0.1, 0.1], arrivalIntervalSeconds: 0.05 },
    playerRoles: ['social'], worlds: [world], pacing: { minSeconds: 0.01, maxSeconds: 0.01 },
    timeouts: { connectSeconds: 1, actionSeconds: 1, settleSeconds: 0.1 }, checkpointSeconds: 0.1, ...overrides })
}

async function temporary(t) {
  const directory = await mkdtemp(path.join(os.tmpdir(), 'multiplexor-sessions-'))
  t.after(() => rm(directory, { recursive: true, force: true }))
  return directory
}

function configuration(directory, overrides = {}) {
  return { schemaVersion: 1, runId: 'test-run', artifactsDirectory: directory, profilePath: path.join(directory, 'profile.json'), resume: false,
    target: { kind: 'instance', name: 'qa', host: '127.0.0.1', port: 25565, backends: [{ alias: 'standalone', instance: 'qa', port: 25565 }] },
    controller: {}, viewerEnabled: false, ...overrides }
}

function fakeRuntime(options = {}) {
  const clients = []
  const connected = new Set()
  const inventories = new Map()
  return {
    clients, connected, inventories,
    createBot(settings) {
      options.attempt?.(settings)
      assert.ok(!connected.has(settings.username), 'one connection per identity')
      connected.add(settings.username)
      const bot = new EventEmitter()
      Object.assign(bot, { username: settings.username, entity: { position: { x: 24, y: 80, z: 24 } }, player: { uuid: `uuid-${settings.username}` },
        inventory: { items: () => [{ name: 'cobblestone', count: inventories.get(settings.username) ?? 0 }] }, backend: 'standalone',
        quit() { connected.delete(settings.username); queueMicrotask(() => bot.emit('end', 'quit')) },
        end() { connected.delete(settings.username); queueMicrotask(() => bot.emit('end', 'forced')) },
        chat(message) {
          if (message.startsWith('/server ')) { bot.backend = message.slice(8); queueMicrotask(() => { bot.emit('respawn'); bot.emit('spawn') }) }
          if (message === '/server') queueMicrotask(() => bot.emit('message', `You are currently connected to ${bot.backend}.`, 'system'))
          if (message === '/balance') queueMicrotask(() => bot.emit('messagestr', 'Balance: 10'))
        }, clearControlStates() {}, stopDigging() {}, pathfinder: { setGoal() {}, stop() {} }
      })
      clients.push(bot)
      queueMicrotask(() => { if (options.connect) options.connect(bot); else bot.emit('spawn') })
      return bot
    }
  }
}

test('only a bounded declared transition may change a live session world', async () => {
  const transport = createSessionTransport({ runtime: fakeRuntime(), target: configuration('/tmp').target, timeoutMs: 100, cleanupTimeoutMs: 20 })
  const owned = await transport.connect({ id: 'one', username: 'WorldCheck' }, new AbortController().signal)
  await transport.worldTransition(owned, async () => { owned.bot.emit('respawn'); return 'verified' })
  assert.equal(owned.signal.aborted, false)
  assert.equal(owned.switching, false)
  owned.bot.emit('respawn')
  assert.equal(owned.signal.reason.kind, 'world-change')
  await transport.close()
})

test('failed declared arrival fences the session instead of resuming in the wrong world', async () => {
  const transport = createSessionTransport({ runtime: fakeRuntime(), target: configuration('/tmp').target, timeoutMs: 100, cleanupTimeoutMs: 20 })
  const owned = await transport.connect({ id: 'one', username: 'WorldFailure' }, new AbortController().signal)
  await assert.rejects(transport.worldTransition(owned, async () => { owned.bot.emit('respawn'); throw new Error('Wrong world UUID') }), /Wrong world/)
  assert.equal(owned.signal.aborted, true)
  assert.equal(owned.switching, false)
  await transport.close()
})

function engineDependencies(runtime, overrides = {}) {
  let setupCalls = 0
  const observed = []
  return {
    runtime, signals: new EventEmitter(), notice: () => {}, cleanupTimeoutMs: 20, pollIntervalMs: 10,
    telemetry: { sample: async () => ({ status: 'unavailable' }), summary: () => ({ status: 'unavailable' }), close() {} },
    createActions: ({ shared }) => ({
      async prepare() { setupCalls += 1; shared.world.prepared = true },
      async observe(bot, player) { const inventory = runtime.inventories.get(bot.username) ?? 0; observed.push({ username: bot.username, inventory, task: player.task?.kind }); return { inventory } },
      chooseTask: () => ({ kind: 'gather' }),
      async executeTask(bot, player, task, context) {
        await delay(25, context.signal)
        context.assertCurrent()
        runtime.inventories.set(bot.username, (runtime.inventories.get(bot.username) ?? 0) + 1)
        shared.world.completed = (shared.world.completed ?? 0) + 1
        return { status: 'completed', kind: task.kind, metrics: { collected: 1 } }
      },
      verifyGoals: () => ({ projectsCompleted: shared.world.completed ?? 0, resourceTransfers: shared.world.completed ?? 0, goalsMet: (shared.world.completed ?? 0) >= 4 }),
      async dispose() {}
    }),
    observations: observed, setups: () => setupCalls, ...overrides
  }
}

test('profile validation rejects unknown fields, missing producers, invalid ranges, and fake routes', () => {
  assert.throws(() => profile({ accidental: true }), /Unknown/)
  assert.throws(() => profile({ population: { identities: 1, sessionSeconds: [3, 1] } }), /minimum/)
  assert.throws(() => validateSessionProfile({ schemaVersion: 1, playerRoles: ['social'] }), /requires assigned/)
  assert.throws(() => profile({ goals: { madeUp: 1 } }), /Unknown/)
  assert.throws(() => validateSessionProfile({ schemaVersion: 1, network: { routes: ['invalid'] } }, configuration('/tmp').target), /require a Velocity/)
  assert.throws(() => validateSessionConfiguration(configuration('/tmp', { target: { ...configuration('/tmp').target, host: 'example.com' } })), /loopback/)
  assert.throws(() => profile({ telemetry: { warmupSeconds: -1 } }), /warmupSeconds/)
  assert.equal(playerNames(profile())[1], 'Sess002')
})

test('bundled plugin workflows resolve the standalone alias to the selected instance', async () => {
  const raw = JSON.parse(await readFile(new URL('../session-profiles/plugin-circuits.json', import.meta.url), 'utf8'))
  const target = { kind: 'instance', name: 'portal-qa', defaultBackend: 'portal-qa', backends: [{ alias: 'portal-qa' }] }
  const selected = validateSessionProfile(raw, target)
  assert.ok(selected.pluginActivities.length > 0)
  assert.ok(selected.pluginActivities.every((activity) => activity.backend === 'portal-qa'))
  assert.ok(selected.worlds.every((world) => world.backend === 'portal-qa'))
  assert.ok(raw.pluginActivities.every((activity) => activity.backend === 'standalone'))
})

test('roster resumes intent and random stream but fences old ownership and reconnects', () => {
  const selected = profile()
  const roster = createRoster(selected)
  const random = randomFor(roster[0])
  random()
  const saved = structuredClone(roster)
  const next = random()
  assert.equal(randomFor(saved[0])(), next)
  saved[0].lifecycle = 'playing'
  saved[0].task = { kind: 'withdraw' }
  const previousGeneration = saved[0].generation
  prepareResume(saved, selected, 300)
  assert.equal(saved[0].lifecycle, 'offline')
  assert.equal(saved[0].dueAtMs, 300)
  assert.equal(saved[0].task.kind, 'withdraw')
  assert.ok(saved[0].generation > previousGeneration)
})

test('population stages and arrival queue depend on time rather than task completions', () => {
  const selected = profile({ population: { identities: 3, concurrent: 1, stages: [{ atSeconds: 1, concurrent: 3 }, { atSeconds: 2, concurrent: 0 }] } })
  const players = createRoster(selected)
  assert.equal(desiredPopulation(selected, 0), 1)
  assert.equal(desiredPopulation(selected, 1200), 3)
  assert.equal(desiredPopulation(selected, 2100), 0)
  players[0].lifecycle = 'playing'
  assert.equal(arrivalsDue(players, 10000, 1)[0].id, 'player-2')
  assert.equal(arrivalsDue(players, 10000, 0).length, 0)
})

test('arrival spacing covers queued identities and reconnects without catching up in a burst', () => {
  const players = createRoster(profile())
  const population = {}
  assert.equal(admitNextArrival(players, population, 10000, 2, 50), players[0])
  players[0].lifecycle = 'connecting'
  assert.equal(admitNextArrival(players, population, 10000, 1, 50), undefined)
  const restored = JSON.parse(JSON.stringify(population))
  assert.equal(admitNextArrival(players, restored, 10049, 1, 50), undefined)
  assert.equal(admitNextArrival(players, restored, 10050, 1, 50), players[1])
  players[1].lifecycle = 'playing'
  players[0].lifecycle = 'offline'
  players[0].dueAtMs = 10060
  assert.equal(admitNextArrival(players, restored, 10099, 1, 50), undefined)
  assert.equal(admitNextArrival(players, restored, 10100, 1, 50), players[0])
})

test('connection admission survives resume and an interrupted wait can be cancelled', async () => {
  const state = { nextConnectionAtEpochMs: 1005 }
  new SessionConnectionGate(state, 40, { now: () => 1000, resume: true })
  assert.equal(state.nextConnectionAtEpochMs, 1040)
  const restored = JSON.parse(JSON.stringify(state))
  new SessionConnectionGate(restored, 40, { now: () => 1001 })
  assert.equal(restored.nextConnectionAtEpochMs, 1040)
  const abort = new AbortController()
  const gate = new SessionConnectionGate({ nextConnectionAtEpochMs: Date.now() + 10000 }, 40)
  const waiting = gate.run(() => true, abort.signal)
  abort.abort(new Error('cancel admission'))
  await assert.rejects(waiting, /cancel admission/)
})

test('admission starts connections inside its queue and spaces from setup completion despite wall-clock changes', async () => {
  let epoch = 1000
  let monotonic = 0
  const attempts = []
  const state = {}
  const gate = new SessionConnectionGate(state, 40, { now: () => epoch, monotonicNow: () => monotonic,
    wait: async (duration) => { monotonic += duration; epoch -= 100 } })
  const start = () => { attempts.push(monotonic); monotonic += 25; return attempts.length }
  assert.deepEqual(await Promise.all([gate.run(start), gate.run(start), gate.run(start)]), [1, 2, 3])
  assert.deepEqual(attempts, [0, 65, 130])
  assert.equal(state.nextConnectionAtEpochMs, epoch + 40)
})

test('goals use verified outcomes and latency keeps failed operations', () => {
  assert.equal(goalsSatisfied({ ...profile(), goals: { projectsCompleted: 2, joins: 3 } }, { projectsCompleted: 1 }, { joins: 30 }), false)
  assert.equal(goalsSatisfied({ ...profile(), goals: { projectsCompleted: 2, joins: 3 } }, { projectsCompleted: 2 }, { joins: 3 }), true)
  const latency = {}
  recordLatency(latency, 'timeout', 1000)
  recordLatency(latency, 'failed', 250)
  assert.equal(latency.timeout.count, 1)
  assert.equal(latency.failed.maxMs, 250)
})

test('leases cannot reassign a live actor and stale release cannot unlock a successor', () => {
  let time = 0
  let live = true
  const leases = new SessionLeases({ now: () => time, isOwnerLive: () => live })
  const first = leases.acquire('chest', 'player:1', 10)
  time = 11
  assert.equal(leases.acquire('chest', 'player:2', 10), undefined)
  assert.throws(() => leases.assert(first), /expired/)
  live = false
  const second = leases.acquire('chest', 'player:2', 10)
  leases.release(first)
  leases.assert(second)
  leases.releaseOwner('player:2')
  assert.equal(leases.snapshot().length, 0)
})

test('durable checkpoints reject tampering, concurrent ownership, and changed worlds', async (t) => {
  const directory = await temporary(t)
  const options = { runId: 'test', fingerprint: 'one' }
  const store = await createSessionStore(directory, options)
  await store.checkpoint({ players: [], shared: {}, elapsedMs: 2 })
  assert.equal((await store.load()).elapsedMs, 2)
  await assert.rejects(createSessionStore(directory, options), /still alive/)
  await store.close()
  await assert.rejects(createSessionStore(directory, { ...options, fingerprint: 'two', resume: true }), /does not match/)
  const raw = JSON.parse(await readFile(path.join(directory, 'checkpoint.json'), 'utf8'))
  raw.elapsedMs = 100
  await atomicJson(path.join(directory, 'checkpoint.json'), raw)
  await assert.rejects(createSessionStore(directory, { ...options, resume: true }), /integrity/)
  assert.notEqual(profileFingerprint(profile(), configuration(directory).target), profileFingerprint(profile({ seed: 43 }), configuration(directory).target))
})

test('backend acknowledgement accepts exact proxy system messages and excludes player chat', () => {
  assert.equal(backendFromMessage('You are currently connected to survival.', 'system'), 'survival')
  assert.equal(backendFromMessage('You are currently connected to survival.', 'chat'), undefined)
  assert.equal(backendFromMessage('<Player> You are currently connected to survival.'), undefined)
  assert.equal(backendFromMessage({ json: { translate: 'velocity.command.server-current-server', with: [{ text: 'lobby' }] } }), 'lobby')
})

test('routing refuses fallback and removes pending response listeners', async () => {
  const bot = new EventEmitter()
  bot.username = 'Test'
  bot.chat = () => queueMicrotask(() => bot.emit('message', 'You are currently connected to lobby.', 'system'))
  const target = { backends: [{ alias: 'lobby' }, { alias: 'survival' }] }
  await assert.rejects(confirmBackend(bot, target, { expected: 'survival', timeoutMs: 20 }), /not confirmed/)
  assert.equal(bot.listenerCount('message'), 0)
})

test('transport keeps one connection per identity and proves destination after switch', async () => {
  const runtime = fakeRuntime()
  const target = { kind: 'network', host: '127.0.0.1', port: 25565, backends: [{ alias: 'standalone' }, { alias: 'survival' }] }
  const transport = createSessionTransport({ runtime, target, timeoutMs: 1000, cleanupTimeoutMs: 20 })
  const player = { id: 'one', username: 'One' }
  const owned = await transport.connect(player, new AbortController().signal)
  await assert.rejects(transport.connect(player), /already has/)
  assert.equal(await transport.switchBackend(owned, 'survival'), 'survival')
  const cleanup = await transport.close()
  assert.equal(cleanup.remaining, 0)
  assert.equal(cleanup.disconnected, 1)
})

test('world readiness keeps upstream acknowledgments and resets for each actual backend login', async (t) => {
  const events = []
  const runtime = fakeRuntime({ connect(bot) {
    bot._client.emit('login')
    bot._client.write('player_loaded', {})
    bot.emit('spawn')
  } })
  const createBot = runtime.createBot
  let client
  runtime.createBot = (settings) => {
    const bot = createBot(settings)
    client = new EventEmitter()
    client.state = 'play'
    client.write = (name) => { events.push(name) }
    bot._client = client
    bot.supportFeature = (name) => name === 'sendsPlayerLoadedPacket'
    bot.waitForChunksToLoad = async () => { events.push('chunks-ready') }
    bot.chat = (message) => {
      if (message.startsWith('/server ')) {
        bot.backend = message.slice(8)
        queueMicrotask(() => { client.emit('login'); bot.emit('login'); bot.emit('forcedMove') })
      }
      if (message === '/server') queueMicrotask(() => bot.emit('message', `You are currently connected to ${bot.backend}.`, 'system'))
    }
    return bot
  }
  const target = { kind: 'network', host: '127.0.0.1', port: 25565, backends: [{ alias: 'standalone' }, { alias: 'survival' }] }
  const transport = createSessionTransport({ runtime, target, timeoutMs: 1000, cleanupTimeoutMs: 20 })
  t.after(() => transport.close())
  const owned = await transport.connect({ id: 'one', username: 'One' })
  assert.deepEqual(events, ['player_loaded', 'chunks-ready'])
  for (const alias of ['survival', 'standalone', 'survival']) {
    events.length = 0
    await transport.switchBackend(owned, alias)
    assert.deepEqual(events, ['chunks-ready', 'player_loaded'])
  }
  await transport.close()
  assert.equal(client.listenerCount('login'), 0)
  assert.equal(client.listenerCount('respawn'), 0)
})

test('arrival acknowledgment respects protocol support and refuses the configuration phase', () => {
  const client = new EventEmitter()
  const sent = []
  client.state = 'configuration'
  client.write = (packet) => { sent.push(packet) }
  const write = client.write
  const bot = { username: 'One', _client: client, supportFeature: () => false }
  const readiness = installArrivalReadiness(bot)
  readiness.acknowledge()
  assert.deepEqual(sent, [])
  bot.supportFeature = () => true
  assert.throws(() => readiness.acknowledge(), /not entered gameplay/)
  client.state = 'play'
  readiness.acknowledge()
  readiness.acknowledge()
  assert.deepEqual(sent, ['player_loaded'])
  client.emit('respawn')
  readiness.acknowledge()
  assert.deepEqual(sent, ['player_loaded', 'player_loaded'])
  readiness.dispose()
  assert.equal(client.write, write)
})

test('physical connection spacing includes the controller and does not wait for other handshakes', async (t) => {
  let controllerBot
  const attempts = []
  const runtime = fakeRuntime({ attempt(settings) { attempts.push({ username: settings.username, at: performance.now() }) }, connect(bot) {
    if (bot.username === 'Controller') controllerBot = bot
    else bot.emit('spawn')
  } })
  const population = {}
  const transport = createSessionTransport({ runtime, target: configuration('/tmp').target, timeoutMs: 1000, cleanupTimeoutMs: 20,
    connectionGate: new SessionConnectionGate(population, 40) })
  const controller = transport.connect({ id: 'controller', username: 'Controller' })
  controller.catch(() => {})
  t.after(async () => { controllerBot?.emit('spawn'); await Promise.allSettled([controller]); await transport.close() })
  const players = await Promise.all(['One', 'Two'].map((username) => transport.connect({ id: username, username })))
  assert.equal(attempts.length, 3)
  for (let index = 1; index < attempts.length; index++) assert.ok(attempts[index].at - attempts[index - 1].at >= 40, JSON.stringify(attempts))
  assert.ok(players.every((owned) => owned.spawned))
  assert.equal(transport.connections.get('Controller').spawned, false)
  controllerBot.emit('spawn')
  await controller
  assert.ok(population.lastConnectionAttemptAtEpochMs > 0)
  assert.equal((await transport.close()).remaining, 0)
})

test('an early rate-limit kick clears the original identity before a spaced retry', async () => {
  const attempts = []
  const runtime = fakeRuntime({ attempt() { attempts.push(performance.now()) }, connect(bot) {
    if (attempts.length === 1) {
      delete bot.username
      bot.emit('kicked', { text: 'You are logging in too fast, try again later.' })
    } else bot.emit('spawn')
  } })
  const transport = createSessionTransport({ runtime, target: configuration('/tmp').target, timeoutMs: 1000, cleanupTimeoutMs: 20,
    connectionGate: new SessionConnectionGate({}, 40) })
  const player = { id: 'one', username: 'One' }
  await assert.rejects(transport.connect(player), (error) => error.kind === 'rate-limit' && error.message.includes('arrivalIntervalSeconds'))
  assert.equal(transport.connections.size, 0)
  const retry = await transport.connect(player)
  assert.equal(retry.username, player.username)
  assert.ok(attempts[1] - attempts[0] >= 40)
  assert.deepEqual(await transport.close(), { connections: 2, disconnected: 2, remaining: 0 })
})

test('transport cleanup refuses success when an identity registration remains', async () => {
  const transport = createSessionTransport({ runtime: fakeRuntime(), target: configuration('/tmp').target, cleanupTimeoutMs: 20 })
  const owned = await transport.connect({ id: 'one', username: 'One' })
  transport.connections.set('unexpected', owned)
  await assert.rejects(transport.close(), (error) => error.kind === 'invariant' && error.message.includes('remain registered'))
})

test('unsettled actions stop before ownership can be reassigned', async () => {
  await assert.rejects(executeBounded(() => new Promise(() => {}), { timeoutMs: 10, settleMs: 10 }), /did not settle/)
})

test('immediate cancellation does not latch a graceful stop onto the next path', () => {
  let goal = 'walking'
  let stopped = false
  cancelBot({ pathfinder: { setGoal(value) { goal = value }, stop() { stopped = true } } })
  assert.equal(goal, null)
  assert.equal(stopped, false)
})

test('configuration barrier keeps configuration handshakes and suppresses stale gameplay packets', () => {
  const sent = []
  const suppressed = []
  const client = { state: 'configuration', version: 'test', write(name) { sent.push(name) } }
  const original = client.write
  const protocol = { configuration: { toServer: { types: { packet: ['container', [{}, { type: ['switch', { fields: { settings: {}, keep_alive: {}, finish_configuration: {} } }] }]] } } } }
  const remove = installConfigurationBarrier({ _client: client }, () => protocol, (event) => suppressed.push(event.packet))
  client.write('settings')
  client.write('position')
  client.write('chat_command')
  client.write('keep_alive')
  client.write('finish_configuration')
  client.state = 'play'
  client.write('position')
  assert.deepEqual(sent, ['settings', 'keep_alive', 'finish_configuration', 'position'])
  assert.deepEqual(suppressed, ['position', 'chat_command'])
  remove()
  assert.equal(client.write, original)
  assert.match(reasonText({ text: 'Connection failed' }), /Connection failed/)
})

test('sessions genuinely logout and rotate identities without resetting inventories', async (t) => {
  const directory = await temporary(t)
  const runtime = fakeRuntime()
  const ports = []
  let viewerOpen = false
  const dependencies = engineDependencies(runtime, { profile: profile({ durationSeconds: 3.6,
    population: { identities: 2, concurrent: 1, sessionSeconds: [1.4, 1.4], offlineSeconds: [0.1, 0.1], arrivalIntervalSeconds: 0.05 } }),
    async startWebFeed({ port }) { assert.equal(viewerOpen, false); viewerOpen = true; ports.push(port); return { enabled: true, port: port ?? 34567, status: 'active' } },
    async stopWebFeed(bot, state) { await delay(10); viewerOpen = false; state.status = 'closed' }
  })
  const report = await runSessions(configuration(directory, { viewerEnabled: true }), dependencies)
  assert.equal(report.status, 'passed', JSON.stringify(report.errors))
  assert.ok(report.counters.sessionsCompleted >= 2)
  assert.ok(report.counters.joins >= 3)
  assert.ok(runtime.clients.some((bot, index) => runtime.clients.slice(0, index).some((previous) => previous.username === bot.username)))
  assert.ok(dependencies.observations.some((observation) => observation.inventory > 0))
  assert.equal(report.cleanup.remaining, 0)
  assert.equal(runtime.connected.size, 0)
  assert.equal(dependencies.signals.listenerCount('SIGINT'), 0)
  assert.ok(report.generator.samples > 0)
  assert.ok(report.population.desiredPlayerMs > 0)
  assert.ok(ports.length >= 2)
  assert.equal(ports[0], undefined)
  assert.ok(ports.slice(1).every((port) => port === 34567))
  assert.equal(viewerOpen, false)
})

test('stop and resume preserve progress, setup ownership, and interrupted intent', async (t) => {
  const directory = await temporary(t)
  const runtime = fakeRuntime()
  const selected = profile({ completion: 'goals', goals: { resourceTransfers: 8 }, durationSeconds: 10,
    population: { identities: 1, concurrent: 1, sessionSeconds: [5, 5] } })
  const first = engineDependencies(runtime, { profile: selected })
  const stopTimer = setInterval(() => { if ((runtime.inventories.get('Sess001') ?? 0) >= 2) first.signals.emit('SIGTERM') }, 10)
  const interrupted = await runSessions(configuration(directory), first)
  clearInterval(stopTimer)
  assert.equal(interrupted.status, 'stopped')
  assert.equal(interrupted.cleanup.remaining, 0)
  const second = engineDependencies(runtime, { profile: selected })
  const finished = await runSessions(configuration(directory, { resume: true }), second)
  assert.equal(finished.status, 'passed', JSON.stringify(finished.errors))
  assert.equal(finished.completion.goalsMet, true)
  assert.equal(first.setups(), 1)
  assert.equal(second.setups(), 0)
  assert.ok(second.observations[0].inventory > 0)
  const checkpoint = JSON.parse(await readFile(path.join(directory, 'checkpoint.json'), 'utf8'))
  assert.ok(checkpoint.players[0].generation > 1)
})

test('stop request cancels bounded work and clears process ownership', async (t) => {
  const directory = await temporary(t)
  const runtime = fakeRuntime()
  const dependencies = engineDependencies(runtime, { profile: profile({ durationSeconds: 5 }) })
  const timer = setTimeout(() => writeFile(path.join(directory, 'stop.request'), 'stop'), 100)
  const report = await runSessions(configuration(directory), dependencies)
  clearTimeout(timer)
  assert.equal(report.status, 'stopped')
  assert.equal(report.cleanup.remaining, 0)
  await assert.rejects(readFile(path.join(directory, 'node.lock')), { code: 'ENOENT' })
})

test('dead host triggers cleanup and a failed report', async (t) => {
  const directory = await temporary(t)
  const dependencies = engineDependencies(fakeRuntime(), { profile: profile() })
  const report = await runSessions(configuration(directory, { parentPid: 2147483647 }), dependencies)
  assert.equal(report.status, 'failed')
  assert.ok(report.errors.some((error) => error.kind === 'host'))
  assert.equal(report.cleanup.remaining, 0)
})

test('stop is observed during setup and does not wait for the setup deadline', async (t) => {
  const directory = await temporary(t)
  const runtime = fakeRuntime()
  const dependencies = engineDependencies(runtime, { profile: profile(), createActions: () => ({
    async prepare({ signal }) { await writeFile(path.join(directory, 'stop.request'), 'stop'); await delay(30000, signal) },
    verifyGoals: () => ({ goalsMet: false }), async dispose() {}
  }) })
  const started = Date.now()
  const report = await runSessions(configuration(directory), dependencies)
  assert.equal(report.status, 'stopped')
  assert.ok(Date.now() - started < 2000)
})

test('explicit performance failure fails the run without discarding completed workload', async (t) => {
  const directory = await temporary(t)
  const selected = profile({ completion: 'goals', goals: { resourceTransfers: 1 } })
  const dependencies = engineDependencies(fakeRuntime(), { profile: selected, telemetry: {
    sample: async () => ({}), summary: () => ({ status: 'failed', violations: ['tick.p95Ms'] }), close() {}
  } })
  const report = await runSessions(configuration(directory), dependencies)
  assert.equal(report.status, 'failed')
  assert.equal(report.workload.status, 'passed')
  assert.equal(report.performance.status, 'failed')
})
