import { setMaxListeners } from 'node:events'
import { monitorEventLoopDelay, performance } from 'node:perf_hooks'
import { loadSessionProfile, playerNames, profileFingerprint, validateSessionConfiguration } from './configuration.mjs'
import { createSessionStore, processAlive, SessionLeases } from './store.mjs'
import { admitNextArrival, createRoster, desiredPopulation, goalsSatisfied, prepareResume, randomFor, recordLatency, sampleSeconds, SessionConnectionGate } from './scheduler.mjs'
import { bounded, createSessionTransport, delay, loadSessionRuntime, sessionError } from './transport.mjs'
import { executeBounded } from './executor.mjs'
import { duePluginActivity, executePluginActivity } from './plugin_activities.mjs'
import { startWebFeed, stopWebFeed } from '../web_feed.mjs'

export async function runSessions(rawConfiguration, dependencies = {}) {
  const configuration = validateSessionConfiguration(rawConfiguration)
  const profile = dependencies.profile ?? await loadSessionProfile(configuration.profilePath, configuration.target)
  const names = playerNames(profile)
  if (configuration.controller.username && names.includes(configuration.controller.username)) throw new Error('Controller identity overlaps the player roster')
  const now = dependencies.now ?? (() => performance.now())
  const signals = dependencies.signals ?? process
  const notice = dependencies.notice ?? ((line) => process.stdout.write(`${line}\n`))
  const runtime = dependencies.runtime ?? await loadSessionRuntime()
  const fingerprint = profileFingerprint(profile, configuration.target)
  const store = await createSessionStore(configuration.artifactsDirectory, {
    runId: configuration.runId, fingerprint, resume: configuration.resume
  })
  const abort = new AbortController()
  setMaxListeners(0, abort.signal)
  const sessions = new Map()
  const recordedErrors = new WeakSet()
  let state
  let report
  let actions
  let telemetry
  let metrics
  let transport
  let currentViewer
  let viewerPort = configuration.viewerPort
  let viewerClosing = Promise.resolve()
  let stopped = false
  let fatal
  let closing = false
  let clockStarted
  let baseElapsed = 0
  let telemetryAt = -Infinity
  let checkpointAt = -Infinity
  let reportAt = -Infinity
  let ownerCheckAt = -Infinity
  let controlPoll
  let controlReading = false
  let previousPopulationAt = 0
  const elapsed = () => baseElapsed + (clockStarted === undefined ? 0 : Math.max(0, now() - clockStarted))
  const fail = (error) => {
    if (fatal) return
    fatal = error instanceof Error ? error : new Error(String(error))
    abort.abort(fatal)
  }
  const stop = (reason) => {
    stopped = true
    abort.abort(sessionError(reason, 'stop'))
  }
  const interrupt = () => stop('SIGINT')
  const terminate = () => stop('SIGTERM')
  signals.on('SIGINT', interrupt)
  signals.on('SIGTERM', terminate)
  const leases = new SessionLeases({ now: () => elapsed(), isOwnerLive: (owner) => [...sessions.values()].some((session) => session.owner === owner) })
  const record = (event) => {
    const entry = { ...boundedValue(event), elapsedMs: Math.round(elapsed()) }
    state.journal.push(entry)
    state.eventCount += 1
    if (state.journal.length > 1000) state.journal.shift()
  }
  const checkpoint = async () => {
    state.elapsedMs = elapsed()
    state.leases = leases.snapshot()
    if (telemetry?.checkpoint) state.telemetryHistory = telemetry.checkpoint()
    state.checkpointAt = new Date().toISOString()
    await store.checkpoint(state)
  }
  const checkControl = async () => {
    if (closing || controlReading) return
    controlReading = true
    try {
      if (await store.stopRequested()) { stop('Stop requested'); return }
      if (configuration.parentPid && now() - ownerCheckAt >= 1000) {
        ownerCheckAt = now()
        if (!processAlive(configuration.parentPid)) fail(sessionError('Session host process disappeared', 'host'))
      }
    } catch (error) { fail(error) } finally { controlReading = false }
  }
  const worldSummary = () => {
    const summaries = [...actions].map(([id, action]) => ({ id, ...action.adapter.verifyGoals() }))
    const result = { projectsCompleted: 0, projectsTotal: 0, blocksVerified: 0, resourceTransfers: 0, foodCrafted: 0, worlds: summaries, projects: [] }
    for (const summary of summaries) {
      for (const key of ['projectsCompleted', 'projectsTotal', 'blocksVerified', 'resourceTransfers', 'foodCrafted']) result[key] += summary[key] ?? 0
      for (const project of summary.projects ?? []) result.projects.push({ ...project, world: summary.id })
    }
    result.goalsMet = result.projectsTotal > 0 && result.projectsCompleted === result.projectsTotal
    return result
  }
  const snapshot = (status) => {
    const summary = actions ? worldSummary() : {}
    const population = state.players.filter((player) => player.lifecycle === 'playing').length
    return {
      schemaVersion: 1, runId: configuration.runId, fingerprint, pid: process.pid, status, profileName: profile.name,
      target: configuration.target, startedAt: state.startedAt, updatedAt: new Date().toISOString(),
      elapsedSeconds: elapsed() / 1000, durationSeconds: profile.durationSeconds,
      desiredPopulation: desiredPopulation(profile, elapsed()), connectedPopulation: population,
      transportConnections: transport?.connections.size ?? 0,
      players: state.players.map(({ id, username, role, lifecycle, backend, homeWorld, socialGroup, status: activity, joins, sessions, failures, task }) => ({
        id, username, role, lifecycle, backend, homeWorld, socialGroup, activity, joins, sessions, failures, task: task?.kind
      })),
      projects: summary.projects ?? [], goals: profile.goals, goalSummary: summary, counters: state.counters,
      activityCounts: state.activityCounts, waitingReasons: state.waitingReasons,
      population: state.population, latency: state.latency, generator: state.generator,
      telemetry: state.telemetry, performance: telemetry?.summary() ?? { status: 'unavailable', required: profile.telemetry.required },
      viewer: report.viewer, errors: report.errors
    }
  }

  async function closeViewer() {
    if (!currentViewer) return viewerClosing
    const previous = currentViewer
    currentViewer = undefined
    viewerClosing = (dependencies.stopWebFeed ?? stopWebFeed)(previous.owned.bot, previous.state, { instance: configuration.target.name, scenario: 'sessions' })
    await viewerClosing
    report.viewer = previous.state
  }

  async function updateViewer() {
    if (!configuration.viewerEnabled || closing) return
    await viewerClosing
    if (currentViewer?.owned.ended || currentViewer?.owned.closing || currentViewer?.owned.signal.aborted) await closeViewer()
    if (currentViewer) return
    const owned = [...sessions.values()].find((session) => session.player.lifecycle === 'playing' && !session.owned?.signal.aborted)?.owned
    if (!owned) return
    const opening = (dependencies.startWebFeed ?? startWebFeed)({
      artifactsDirectory: configuration.artifactsDirectory, bot: owned.bot, instance: configuration.target.name,
      scenario: 'sessions', notice, port: viewerPort
    }).then(async (viewer) => {
      viewerPort ??= viewer.port
      report.viewer = viewer
      currentViewer = { owned, state: viewer }
      if (closing || owned.signal.aborted) await closeViewer()
    })
    opening.catch(() => {})
    await bounded(opening, profile.timeouts.connectSeconds * 1000, 'Session viewer startup', abort.signal)
  }

  async function runPlayer(player, session) {
    const random = randomFor(player)
    let owned
    let failure
    let scheduledEnd = false
    const started = elapsed()
    const scheduledArrival = player.dueAtMs
    const sessionDuration = sampleSeconds(profile.population.sessionSeconds, random)
    const lifecycleDeadline = started + sessionDuration
    const generation = player.generation
    const home = actions.get(player.homeWorld)
    let action = home
    let nextSwitch = started + sampleSeconds(profile.network.switchEverySeconds, random)
    let routeIndex = 0
    const assertCurrent = () => {
      if (player.generation !== generation || sessions.get(player.id) !== session || session.abort.signal.aborted || owned?.signal.aborted) throw sessionError('Player action ownership expired', 'fenced')
    }
    const context = (signal) => ({
      signal, random, assertCurrent: () => { signal.throwIfAborted(); assertCurrent() }, checkpoint, record, owner: session.owner, coordinator: leases,
      backend: player.backend, world: action?.world, timeoutMs: profile.timeouts.actionSeconds * 1000,
      observerPath: configuration.target.backends.find((backend) => backend.alias === player.backend)?.observerPath,
      worldTransition: (operation) => transport.worldTransition(owned, operation),
      failTransition: (error) => owned.abort.abort(error),
      peers: state.players.filter((peer) => peer.socialGroup === player.socialGroup && peer.lifecycle === 'playing').map((peer) => ({ id: peer.id, username: peer.username, backend: peer.backend, homeWorld: peer.homeWorld }))
    })
    try {
      player.lifecycle = 'connecting'
      player.status = 'Connecting'
      state.population.scheduledArrivals += 1
      const lateness = Math.max(0, started - scheduledArrival)
      state.population.totalArrivalDelayMs += lateness
      state.population.maxArrivalDelayMs = Math.max(state.population.maxArrivalDelayMs, lateness)
      if (lateness > 1000) state.population.lateArrivals += 1
      record({ type: 'arrival-start', player: player.id, scheduledArrivalMs: scheduledArrival, delayMs: lateness })
      await checkpoint()
      owned = await transport.connect(player, session.abort.signal)
      session.owned = owned
      player.backend = owned.backend
      if (owned.backend !== home.world.backend) {
        player.lifecycle = 'loading'
        player.status = `Routing to ${home.world.backend}`
        await transport.switchBackend(owned, home.world.backend)
        player.backend = owned.backend
      }
      player.lifecycle = 'loading'
      await executeBounded(async (signal) => {
        await action.adapter.arrive?.(owned.bot, player, context(signal))
        const observation = await action.adapter.observe(owned.bot, player, context(signal))
        assertCurrent()
        player.observations[action.world.id] = observation
        if (player.task) record({ type: 'reconcile', player: player.id, previousTask: player.task.kind, world: action.world.id })
        player.task = null
      }, { bot: owned.bot, signal: owned.signal, timeoutMs: profile.timeouts.actionSeconds * 1000, settleMs: profile.timeouts.settleSeconds * 1000, assertCurrent })
      player.lifecycle = 'playing'
      player.interrupted = false
      player.status = 'Choosing work'
      player.joins += 1
      player.version = owned.bot.version
      state.counters.joins += 1
      recordLatency(state.latency, 'join', elapsed() - started)
      record({ type: 'arrival', player: player.id, backend: player.backend, uuid: owned.bot.player?.uuid })
      while (elapsed() < lifecycleDeadline && elapsed() < profile.durationSeconds * 1000) {
        assertCurrent()
        if (profile.network.routes.length && elapsed() >= nextSwitch) {
          const route = profile.network.routes[routeIndex++ % profile.network.routes.length]
          nextSwitch = elapsed() + sampleSeconds(profile.network.switchEverySeconds, random)
          if (route !== player.backend) {
            player.lifecycle = 'loading'
            player.status = `Switching to ${route}`
            leases.releaseOwner(session.owner)
            player.task = null
            await checkpoint()
            const switchStarted = elapsed()
            try {
              await transport.switchBackend(owned, route)
              player.backend = owned.backend
              action = route === home.world.backend ? home : [...actions.values()].find((candidate) => candidate.world.backend === route)
              if (action) {
                await executeBounded(async (signal) => {
                  await action.adapter.arrive?.(owned.bot, player, context(signal))
                  player.observations[action.world.id] = await action.adapter.observe(owned.bot, player, context(signal))
                }, { bot: owned.bot, signal: owned.signal, timeoutMs: profile.timeouts.actionSeconds * 1000, settleMs: profile.timeouts.settleSeconds * 1000, assertCurrent })
              }
              state.counters.switches += 1
              recordLatency(state.latency, 'switch', elapsed() - switchStarted)
              record({ type: 'switch', player: player.id, backend: route })
            } catch (error) { recordLatency(state.latency, 'switch-failed', elapsed() - switchStarted); throw error }
            player.lifecycle = 'playing'
          }
        }
        const pluginActivity = duePluginActivity(profile.pluginActivities, player, player.backend, elapsed(), random)
        if (!action && !pluginActivity) {
          player.status = `Visiting ${player.backend}`
          await delay(500, owned.signal)
          continue
        }
        const operationStarted = elapsed()
        try {
          const result = await executeBounded(async (signal) => {
            const current = context(signal)
            let task
            if (pluginActivity) task = { kind: `plugin:${pluginActivity.id}` }
            else {
              const observation = await action.adapter.observe(owned.bot, player, current)
              assertCurrent()
              player.observations[action.world.id] = observation
              task = action.adapter.chooseTask(player, observation, action.shared, current)
            }
            if (!task || typeof task.kind !== 'string') throw sessionError('Activity pack returned no finite task', 'invariant')
            player.task = { ...task, world: action?.world.id, backend: player.backend, generation, startedAtMs: operationStarted }
            player.status = task.reason ?? task.kind
            record({ type: 'task-start', player: player.id, world: action?.world.id, backend: player.backend, task: task.kind })
            await checkpoint()
            signal.throwIfAborted()
            assertCurrent()
            const result = pluginActivity ? await executePluginActivity(owned.bot, pluginActivity, current)
              : await action.adapter.executeTask(owned.bot, player, task, current)
            assertCurrent()
            if (!result || !['completed', 'waiting'].includes(result.status)) throw sessionError('Activity pack returned an invalid task outcome', 'invariant')
            player.task = null
            return result
          }, { bot: owned.bot, signal: owned.signal, timeoutMs: profile.timeouts.actionSeconds * 1000, settleMs: profile.timeouts.settleSeconds * 1000, assertCurrent })
          player.consecutiveFailures = 0
          const increments = Object.entries(result.metrics ?? {})
          if (increments.length > 32 || increments.some(([key, amount]) => !/^[A-Za-z][A-Za-z0-9_]{0,63}$/.test(key) || !Number.isFinite(amount) || amount < 0)) throw sessionError('Activity metrics must be named, finite, nonnegative increments', 'invariant')
          for (const [key, amount] of increments) {
            state.counters[key] = (state.counters[key] ?? 0) + amount
            player.counters[key] = (player.counters[key] ?? 0) + amount
          }
          state.counters[result.status === 'completed' ? 'tasksCompleted' : 'tasksWaiting'] += 1
          const activity = String(result.kind ?? 'unknown').slice(0, 80)
          const activityCounts = state.activityCounts[activity] ??= { completed: 0, waiting: 0 }
          activityCounts[result.status] += 1
          if (result.status === 'waiting') {
            const reason = String(result.reason ?? activity).slice(0, 160)
            const key = Object.hasOwn(state.waitingReasons, reason) || Object.keys(state.waitingReasons).length < 64 ? reason : 'Other waiting reasons'
            state.waitingReasons[key] = (state.waitingReasons[key] ?? 0) + 1
          }
          player.status = result.reason ?? result.kind
          recordLatency(state.latency, result.status, elapsed() - operationStarted)
          record({ type: 'task-end', player: player.id, result })
          await checkpoint()
        } catch (error) {
          const cancelled = session.abort.signal.aborted && ['stop', 'logout'].includes(session.abort.signal.reason?.kind)
          recordLatency(state.latency, cancelled ? 'cancelled' : error.kind === 'timeout' ? 'timeout' : 'failed', elapsed() - operationStarted)
          if (owned.signal.aborted || session.abort.signal.aborted || error.kind === 'invariant' || error.fatal) throw error
          recordFailure(player, error)
          if (player.consecutiveFailures >= profile.recovery.maxConsecutiveFailures || state.counters.failures >= profile.recovery.maxTotalFailures) throw error
          player.status = `Recovering: ${error.message}`
          await delay(profile.recovery.retrySeconds * 1000, owned.signal)
        } finally { leases.releaseOwner(session.owner) }
        if (profile.completion === 'goals' && goalsSatisfied(profile, worldSummary(), state.counters)) break
        await delay(sampleSeconds([profile.pacing.minSeconds, profile.pacing.maxSeconds], random), owned.signal)
      }
      scheduledEnd = true
    } catch (error) {
      failure = error
      if (!session.abort.signal.aborted && error.kind !== 'logout' && error.kind !== 'stop') {
        if (player.joins === 0 || player.lifecycle === 'connecting') recordLatency(state.latency, 'join-failed', elapsed() - started)
        recordFailure(player, error)
        if (error.kind === 'invariant' || error.fatal || state.counters.failures >= profile.recovery.maxTotalFailures) fail(error)
      }
    } finally {
      player.generation += 1
      player.lifecycle = 'leaving'
      if (currentViewer?.owned === owned) {
        try { await closeViewer() } catch (error) { fail(error) }
      }
      try { await transport.disconnect(owned) } catch (error) { fail(error) }
      leases.releaseOwner(session.owner)
      if (scheduledEnd) {
        player.sessions += 1
        state.counters.sessionsCompleted += 1
        state.population.totalLogoutDelayMs += Math.max(0, elapsed() - lifecycleDeadline)
      }
      const retired = player.consecutiveFailures >= profile.recovery.maxConsecutiveFailures || (failure?.kind === 'death' && profile.recovery.death === 'retire')
      player.interrupted = Boolean(failure && abort.signal.aborted)
      player.lifecycle = retired ? 'retired' : 'offline'
      player.dueAtMs = elapsed() + (failure ? profile.recovery.retrySeconds * 1000 : sampleSeconds(profile.population.offlineSeconds, random))
      player.status = retired ? 'Retired after recovery limit' : 'Waiting for next session'
      record({ type: 'departure', player: player.id, retired, scheduled: scheduledEnd, reason: failure?.message })
      await checkpoint().catch(fail)
    }
  }

  function recordFailure(player, error) {
    if (recordedErrors.has(error)) return
    recordedErrors.add(error)
    player.failures += 1
    player.consecutiveFailures += 1
    state.counters.failures += 1
    if (error.kind === 'rate-limit') state.counters.rateLimited = (state.counters.rateLimited ?? 0) + 1
    const entry = { player: player.id, message: String(error.message).slice(0, 1024), kind: error.kind ?? 'action', elapsedMs: elapsed() }
    report.errors.push(entry)
    if (report.errors.length > 128) report.errors.shift()
    record({ type: 'failure', ...entry })
  }

  try {
    state = configuration.resume ? await store.load() : {
      startedAt: new Date().toISOString(), elapsedMs: 0, players: createRoster(profile), shared: { worlds: {} },
      journal: [], eventCount: 0, counters: { joins: 0, switches: 0, sessionsCompleted: 0, tasksCompleted: 0, tasksWaiting: 0, failures: 0 },
      population: { scheduledArrivals: 0, lateArrivals: 0, totalArrivalDelayMs: 0, maxArrivalDelayMs: 0, totalLogoutDelayMs: 0, desiredPlayerMs: 0, achievedPlayerMs: 0, history: [] },
      latency: {}, generator: { scope: 'node-process', samples: 0, history: [] }
    }
    state.activityCounts ??= {}
    state.waitingReasons ??= {}
    baseElapsed = state.elapsedMs
    previousPopulationAt = baseElapsed
    if (configuration.resume) prepareResume(state.players, profile, state.elapsedMs)
    state.errors ??= []
    report = { errors: state.errors, viewer: { enabled: configuration.viewerEnabled, status: configuration.viewerEnabled ? 'pending' : 'disabled' } }
    const connectionGate = new SessionConnectionGate(state.population, profile.population.arrivalIntervalSeconds * 1000, { resume: configuration.resume })
    transport = createSessionTransport({ runtime, target: configuration.target, timeoutMs: profile.timeouts.connectSeconds * 1000, cleanupTimeoutMs: dependencies.cleanupTimeoutMs ?? 2000, deathPolicy: profile.recovery.death, connectionGate, record })
    actions = new Map()
    const createActions = dependencies.createActions ?? (await import('./actions.mjs')).createSessionActions
    for (const world of profile.worlds) {
      state.shared.worlds[world.id] ??= {}
      const shared = { get world() { return state.shared.worlds[world.id] }, set world(value) { state.shared.worlds[world.id] = value } }
      const adapter = await createActions({ profile: { ...profile, world }, shared, record, checkpoint })
      if (configuration.resume) adapter.resume?.()
      actions.set(world.id, { adapter, world, shared })
    }
    metrics = (dependencies.createGeneratorMetrics ?? createGeneratorMetrics)()
    telemetry = dependencies.telemetry ?? (await import('./telemetry.mjs')).createSessionTelemetry({ target: configuration.target, profile, initialState: state.telemetryHistory })
    await store.status(snapshot('starting'))
    await checkpoint()
    controlPoll = setInterval(() => { void checkControl() }, 100)
    await checkControl()
    abort.signal.throwIfAborted()
    if (configuration.resume && [...actions.values()].some((action) => action.world.setup.kind === 'settlement' && !action.shared.world.prepared)) throw new Error('Fixture setup was interrupted; restore the baseline and start a new run instead of repeating setup over an uncertain world')
    const setups = [...actions.values()].filter((action) => !action.shared.world.prepared)
    let controller
    try {
      if (setups.some((action) => action.world.setup.kind === 'settlement')) {
        if (!configuration.controller.username) throw new Error('Settlement fixture setup requires an operator controller')
        controller = await transport.connect({ id: 'controller', username: configuration.controller.username }, abort.signal)
      }
      for (const action of setups) {
        if (action.world.setup.kind === 'settlement' && controller.backend !== action.world.backend) await transport.switchBackend(controller, action.world.backend)
        await executeBounded((signal) => action.adapter.prepare({ controller: controller?.bot, signal }), {
          bot: controller?.bot, signal: abort.signal, timeoutMs: Math.max(60000, profile.timeouts.actionSeconds * 10000), settleMs: profile.timeouts.settleSeconds * 1000
        })
        action.shared.world.prepared = true
        await checkpoint()
      }
    } finally { await transport.disconnect(controller) }
    clockStarted = now()
    notice(`[INFO] Persistent sessions ${configuration.runId}: ${profile.population.identities} identities, ${profile.population.concurrent} initial concurrent players`)
    await store.status(snapshot('running'))
    while (!abort.signal.aborted && elapsed() < profile.durationSeconds * 1000) {
      const current = elapsed()
      const desired = desiredPopulation(profile, current)
      const achieved = state.players.filter((player) => player.lifecycle === 'playing').length
      const delta = Math.max(0, current - previousPopulationAt)
      state.population.desiredPlayerMs += desired * delta
      state.population.achievedPlayerMs += achieved * delta
      previousPopulationAt = current
      const active = [...sessions.values()]
      if (active.length > desired) {
        for (const session of active.slice(desired)) session.abort.abort(sessionError('Population stage ended this session', 'logout'))
      }
      const arriving = admitNextArrival(state.players, state.population, current, desired - sessions.size, profile.population.arrivalIntervalSeconds * 1000)
      if (arriving) {
        const player = arriving
        player.generation += 1
        player.lifecycle = 'connecting'
        const sessionAbort = new AbortController()
        const stopSession = () => sessionAbort.abort(abort.signal.reason)
        abort.signal.addEventListener('abort', stopSession, { once: true })
        const session = { player, abort: sessionAbort, owner: `${player.id}:${player.generation}` }
        sessions.set(player.id, session)
        session.promise = runPlayer(player, session).catch(fail).finally(() => { sessions.delete(player.id); abort.signal.removeEventListener('abort', stopSession) })
      }
      if (state.players.every((player) => player.lifecycle === 'retired')) { fail(new Error('All persistent players reached their recovery limit')); break }
      if (current - telemetryAt >= 1000) {
        telemetryAt = current
        const sample = metrics.sample()
        state.generator.samples += 1
        state.generator.latest = sample
        state.generator.history.push(sample)
        if (state.generator.history.length > 360) state.generator.history.shift()
        state.generator.maxRssBytes = Math.max(state.generator.maxRssBytes ?? 0, sample.rssBytes)
        state.generator.maxEventLoopDelayMs = Math.max(state.generator.maxEventLoopDelayMs ?? 0, sample.eventLoopDelayMs.p95)
        try {
          state.telemetry = await telemetry.sample()
          if (telemetry.checkpoint) state.telemetryHistory = telemetry.checkpoint()
        } catch (error) { state.telemetry = { status: 'unavailable', error: String(error.message).slice(0, 512) } }
        state.population.history.push({ elapsedMs: current, desired, achieved, connecting: state.players.filter((player) => ['connecting', 'loading'].includes(player.lifecycle)).length })
        if (state.population.history.length > 360) state.population.history.shift()
        await store.status(snapshot('running'))
        await updateViewer()
      }
      if (current - checkpointAt >= profile.checkpointSeconds * 1000) { checkpointAt = current; await checkpoint() }
      if (current - reportAt >= 10000) {
        reportAt = current
        await store.report({ ...snapshot('running'), profile, recentEvents: state.journal.slice(-100) })
        notice(`[INFO] Sessions: ${achieved}/${desired} active; ${state.counters.joins} joins; ${state.counters.tasksCompleted} completed tasks; ${state.counters.failures} failures`)
      }
      if (profile.completion === 'goals' && goalsSatisfied(profile, worldSummary(), state.counters)) break
      await delay(dependencies.pollIntervalMs ?? 100, abort.signal).catch((error) => { if (!abort.signal.aborted) throw error })
    }
  } catch (error) {
    if (!stopped) fail(error)
  } finally {
    closing = true
    clearInterval(controlPoll)
    baseElapsed = elapsed()
    clockStarted = undefined
    abort.abort(sessionError('Run finished', 'stop'))
    await Promise.allSettled([...sessions.values()].map((session) => session.promise))
    try { await closeViewer() } catch (error) { fail(error) }
    let cleanup
    try { cleanup = await transport?.close() } catch (error) { fail(error) }
    for (const action of actions?.values() ?? []) {
      try { await action.adapter.dispose() } catch (error) { fail(error) }
    }
    metrics?.close()
    telemetry?.close()
    signals.removeListener('SIGINT', interrupt)
    signals.removeListener('SIGTERM', terminate)
    if (state && report) {
      if (fatal) { report.errors.push({ kind: fatal.kind ?? 'run', message: fatal.message }); if (report.errors.length > 128) report.errors.shift() }
      const summary = actions ? worldSummary() : {}
      const goalsMet = goalsSatisfied(profile, summary, state.counters)
      const hasGoals = Object.keys(profile.goals).length > 0 || profile.completion === 'goals'
      const performanceResult = telemetry?.summary() ?? { status: 'unavailable' }
      const achievedFraction = state.population.desiredPlayerMs > 0 ? state.population.achievedPlayerMs / state.population.desiredPlayerMs : 0
      const achievedLoadFailed = profile.population.minimumAchievedFraction !== undefined && achievedFraction < profile.population.minimumAchievedFraction
      const status = fatal ? 'failed' : stopped ? 'stopped' : (hasGoals && !goalsMet) || performanceResult.status === 'failed' || achievedLoadFailed ? 'failed' : 'passed'
      const final = { ...snapshot(status), profile, finishedAt: new Date().toISOString(), cleanup,
        completion: { requested: profile.completion, durationReached: elapsed() >= profile.durationSeconds * 1000, goalsMet },
        workload: { status: fatal || (hasGoals && !goalsMet) ? 'failed' : stopped ? 'stopped' : 'passed' },
        achievedLoad: { status: profile.population.minimumAchievedFraction === undefined ? 'measured' : achievedLoadFailed ? 'failed' : 'passed',
          fraction: achievedFraction, minimumRequired: profile.population.minimumAchievedFraction,
          desiredPlayerMinutes: state.population.desiredPlayerMs / 60000, achievedPlayerMinutes: state.population.achievedPlayerMs / 60000,
          retiredPlayers: state.players.filter((player) => player.lifecycle === 'retired').length,
          waitingTaskFraction: state.counters.tasksWaiting / Math.max(1, state.counters.tasksCompleted + state.counters.tasksWaiting) },
        generatorAssessment: { status: state.generator.maxEventLoopDelayMs > 100 ? 'constrained' : 'unverified', scope: 'node-process', note: 'Capacity equivalence requires an independently provisioned generator and real-session calibration' },
        recentEvents: state.journal, eventCount: state.eventCount,
        artifact: `${configuration.artifactsDirectory}/report.json`
      }
      try { await checkpoint(); await store.report(final); await store.status(final) } catch (error) { fatal = error; final.status = 'failed'; final.errors.push({ kind: 'checkpoint', message: error.message }) }
      report = final
    }
    await store.close()
  }
  if (!report) throw fatal ?? new Error('Session engine failed before initializing a report')
  return report
}

function createGeneratorMetrics() {
  const lag = monitorEventLoopDelay({ resolution: 20 })
  lag.enable()
  let previousCpu = process.cpuUsage()
  let previousTime = performance.now()
  return {
    sample() {
      const currentTime = performance.now()
      const currentCpu = process.cpuUsage()
      const elapsedMs = Math.max(1, currentTime - previousTime)
      const cpuMicroseconds = currentCpu.user + currentCpu.system - previousCpu.user - previousCpu.system
      const finite = (value) => Number.isFinite(value) ? value : 0
      const result = { at: new Date().toISOString(), rssBytes: process.memoryUsage().rss,
        cpuPercent: cpuMicroseconds / (elapsedMs * 10),
        eventLoopDelayMs: { mean: finite(lag.mean / 1e6), max: finite(lag.max / 1e6), p95: finite(lag.percentile(95) / 1e6) } }
      previousTime = currentTime
      previousCpu = currentCpu
      lag.reset()
      return result
    },
    close() { lag.disable() }
  }
}

function boundedValue(value, depth = 0) {
  if (value === null || typeof value === 'boolean' || typeof value === 'number') return value
  if (typeof value === 'string') return value.slice(0, 512)
  if (depth > 4) return '[truncated]'
  if (Array.isArray(value)) return value.slice(0, 32).map((item) => boundedValue(item, depth + 1))
  if (value && typeof value === 'object') return Object.fromEntries(Object.entries(value).slice(0, 32).map(([key, item]) => [key, boundedValue(item, depth + 1)]))
  return undefined
}
