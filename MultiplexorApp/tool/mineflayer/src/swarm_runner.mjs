import { setMaxListeners } from 'node:events'
import { mkdir, rename, writeFile } from 'node:fs/promises'
import path from 'node:path'
import { monitorEventLoopDelay, performance } from 'node:perf_hooks'

import { swarmNeedsController, swarmWorkerNames, validateSwarmConfiguration } from './swarm_config.mjs'
import { startWebFeed, stopWebFeed } from './web_feed.mjs'

export async function runSwarm(configuration, dependencies = {}) {
  const behaviors = dependencies.behaviors ?? await import('./swarm_behaviors.mjs')
  validateSwarmConfiguration(configuration, behaviors.SWARM_PROFILES)
  let plans
  let stress
  let stressActions
  let containsWorker
  if (configuration.profile === 'custom') {
    plans = dependencies.plans ?? await import('./swarm_plans.mjs')
    configuration = { ...configuration, plan: plans.validateSwarmPlan(configuration.plan, { bots: configuration.bots }) }
  }
  if (configuration.profile === 'stress') {
    const workloads = dependencies.workloads ?? await import('./swarm_workload.mjs')
    const workload = configuration.workload === undefined
      ? workloads.defaultWorkload(configuration)
      : workloads.validateWorkload(configuration.workload, configuration)
    configuration = { ...configuration, workload, bounds: workload.bounds }
    stress = dependencies.stress ?? await import('./swarm_stress.mjs')
    stressActions = dependencies.stressActions ?? await import('./swarm_stress_actions.mjs')
    containsWorker = dependencies.containsWorker ?? (await import('./swarm_world_bounds.mjs')).containsWorker
  }
  const runtime = dependencies.createBot === undefined ? await loadRuntime() : dependencies
  const now = dependencies.now ?? (() => performance.now())
  const signals = dependencies.signals ?? process
  const cleanupTimeoutMs = dependencies.cleanupTimeoutMs ?? 2000
  const notice = configuration.notice ?? (() => {})
  const abort = new AbortController()
  setMaxListeners(0, abort.signal)
  const started = now()
  const startedAt = new Date().toISOString()
  const report = {
    schemaVersion: 1,
    status: 'running',
    profile: configuration.profile,
    server: {
      instance: configuration.instance, host: configuration.host, port: configuration.port,
      minecraftVersion: configuration.version, logPath: configuration.logPath
    },
    configuration: {
      bots: configuration.bots, durationMs: configuration.durationMs, seed: configuration.seed,
      joinIntervalMs: configuration.joinIntervalMs, radius: configuration.radius,
      prefix: configuration.prefix, origin: configuration.origin, buildArena: configuration.buildArena,
      scatter: configuration.scatter, chat: configuration.chat === true,
      connectTimeoutMs: configuration.connectTimeoutMs, actionTimeoutMs: configuration.actionTimeoutMs,
      sourcePath: configuration.sourcePath, plan: configuration.plan,
      workloadSource: configuration.workloadSource, workload: configuration.workload, bounds: configuration.bounds
    },
    bots: swarmWorkerNames(configuration).map((username, index) => ({
      index, username, status: 'pending', actions: 0, actionCounts: {}
    })),
    controller: undefined,
    viewer: { enabled: configuration.viewerEnabled, status: configuration.viewerEnabled ? 'pending' : 'disabled' },
    actionCounts: {}, setupActionCounts: {}, events: [], eventCount: 0, errors: [], startedAt,
    metrics: { scope: 'node-process', sampleCount: 0, history: [] }, checkpointCount: 0
  }
  const clients = []
  let closing = false
  let cancelled = false
  let failure
  let viewerState
  let viewerBot
  let progress
  let checkpointTimer
  let boundsTimer
  let checkpointTask = Promise.resolve()
  let writingCheckpoint = false
  let hostMetrics
  let stressSettlement
  let actionsActive = false
  let passedPhases = 0
  let stage = 'connecting'
  let actionStart
  const viewerMetadata = { instance: configuration.instance, scenario: `swarm-${configuration.profile}` }
  const stopViewer = dependencies.stopWebFeed ?? stopWebFeed
  const fail = (error) => {
    if (closing || failure !== undefined) return
    failure = error instanceof Error ? error : new Error(message(error))
    abort.abort(failure)
  }
  const handleSignal = (name) => {
    cancelled = true
    fail(new Error(`Swarm cancelled by ${name}`))
  }
  const onInterrupt = () => handleSignal('SIGINT')
  const onTerminate = () => handleSignal('SIGTERM')
  signals.on('SIGINT', onInterrupt)
  signals.on('SIGTERM', onTerminate)

  const record = (event) => {
    if (closing) return
    let detail = event
    if (event.type === 'stress-summary' && event.summary !== undefined) {
      report.workloadSummary = structuredClone(event.summary)
      const { elapsedMs, activeBots, completed, failed, skipped } = event.summary
      detail = { type: event.type, elapsedMs, activeBots, completed, failed, skipped }
    }
    const entry = { ...boundedValue(detail), stage: actionsActive ? 'actions' : 'setup', at: new Date().toISOString() }
    report.eventCount += 1
    report.events.push(entry)
    if (report.events.length > 500) report.events.shift()
    if (typeof event.action !== 'string' || !['passed', 'failed', 'skipped'].includes(event.status)) return
    const action = event.action.slice(0, 80)
    const totals = actionsActive ? report.actionCounts : report.setupActionCounts
    const counts = totals[action] ??= { passed: 0, failed: 0, skipped: 0 }
    counts[event.status] += 1
    if (!actionsActive) return
    if (action === 'phase' && event.status === 'passed') passedPhases += 1
    const worker = report.bots.find((item) => item.username === event.bot)
    if (worker === undefined) return
    const workerCounts = worker.actionCounts[action] ??= { passed: 0, failed: 0, skipped: 0 }
    workerCounts[event.status] += 1
    if (event.status === 'passed') worker.actions += 1
  }

  const captureMetrics = () => {
    const sample = hostMetrics.sample()
    report.metrics.sampleCount += 1
    report.metrics.latest = sample
    report.metrics.history.push(sample)
    if (report.metrics.history.length > (dependencies.metricsHistoryLimit ?? 360)) report.metrics.history.shift()
  }
  const checkpoint = () => {
    if (closing || writingCheckpoint) return
    writingCheckpoint = true
    captureMetrics()
    report.checkpointAt = new Date().toISOString()
    report.checkpointCount += 1
    report.durationMs = Math.max(0, Math.round(now() - started))
    checkpointTask = writeReport(report, configuration.artifactsDirectory)
      .catch((error) => fail(new Error(`Swarm checkpoint failed: ${message(error)}`)))
      .finally(() => { writingCheckpoint = false })
  }
  const checkBounds = (bot) => {
    if (!actionsActive || closing || containsWorker === undefined) return
    if (!containsWorker(configuration.bounds, bot.entity?.position)) {
      cancelActions(bot)
      fail(new Error(`${bot.username} left the configured workload bounds`))
    }
  }

  async function connect(summary, role) {
    if (abort.signal.aborted) throw abort.signal.reason
    summary.status = 'connecting'
    const options = {
      host: configuration.host, port: configuration.port, username: summary.username,
      auth: 'offline', hideErrors: true, logErrors: false
    }
    if (configuration.version !== undefined) options.version = configuration.version
    const bot = runtime.createBot(options)
    const owned = { bot, summary, ended: false, listeners: [] }
    clients.push(owned)
    const on = (name, listener) => {
      bot.on(name, listener)
      owned.listeners.push([name, listener])
    }
    on('error', (error) => fail(new Error(`${summary.username}: ${message(error)}`)))
    on('kicked', (reason) => fail(new Error(`${summary.username} kicked: ${message(reason)}`)))
    on('death', () => fail(new Error(`${summary.username} died`)))
    on('end', (reason) => {
      owned.ended = true
      if (!closing) summary.status = 'disconnected'
      fail(new Error(`${summary.username} disconnected: ${message(reason)}`))
    })
    on('messagestr', (text) => record({ bot: summary.username, type: 'chat', message: String(text).slice(0, 512) }))
    if (role === 'worker' && containsWorker !== undefined) on('move', () => checkBounds(bot))
    const spawned = waitForSpawn(bot, abort.signal)
    spawned.catch(() => {})
    runtime.installPathfinder?.(bot)
    await bounded(spawned, configuration.connectTimeoutMs, `${summary.username} spawn`, abort.signal)
    runtime.configureMovements?.(bot)
    summary.status = 'joined'
    summary.uuid = bot.player?.uuid
    summary.version = bot.version
    summary.joinedAt = new Date().toISOString()
    record({ bot: summary.username, type: 'join', role })
    return bot
  }

  try {
    hostMetrics = (dependencies.createHostMetrics ?? createHostMetrics)()
    checkpoint()
    await checkpointTask
    if (abort.signal.aborted) throw abort.signal.reason
    checkpointTimer = setInterval(checkpoint,
      dependencies.checkpointIntervalMs ?? (configuration.workload?.reportIntervalSeconds ?? 30) * 1000)
    notice(`[INFO] Connecting ${configuration.bots} swarm workers${swarmNeedsController(configuration) ? ' plus one setup controller' : ''}`)
    progress = setInterval(() => {
      const elapsed = actionStart === undefined ? '' : `; ${Math.min(configuration.durationMs, Math.round(now() - actionStart)) / 1000}s active`
      notice(`[INFO] Swarm ${stage}: ${report.bots.filter((bot) => !['pending', 'connecting'].includes(bot.status)).length}/${configuration.bots} joined; ${report.bots.reduce((total, bot) => total + bot.actions, 0)} actions${elapsed}`)
    }, dependencies.progressIntervalMs ?? 5000)
    let controller
    if (swarmNeedsController(configuration)) {
      report.controller = { username: configuration.controller, status: 'pending' }
      controller = await connect(report.controller, 'controller')
    }
    const joins = []
    for (const summary of report.bots) {
      if (joins.length > 0) await delay(configuration.joinIntervalMs, abort.signal)
      const joined = connect(summary, 'worker').catch((error) => {
        fail(error)
        throw error
      })
      joined.catch(() => {})
      joins.push(joined)
    }
    const bots = await Promise.all(joins)
    if (abort.signal.aborted) throw abort.signal.reason
    viewerBot = bots[0]
    if (configuration.viewerEnabled) {
      const opening = (dependencies.startWebFeed ?? startWebFeed)({
        ...viewerMetadata, artifactsDirectory: configuration.artifactsDirectory,
        bot: viewerBot, notice, port: configuration.viewerPort
      }).then(async (state) => {
        viewerState = state
        report.viewer = state
        if (closing) await stopViewer(viewerBot, state, viewerMetadata)
        return state
      })
      opening.catch(() => {})
      await bounded(opening, configuration.connectTimeoutMs, 'Swarm viewer startup', abort.signal)
    }
    const setupTimeoutMs = configuration.actionTimeoutMs * Math.max(4, configuration.bots * 8)
    stage = 'setup'
    let arena
    if (configuration.buildArena) {
      arena = await bounded(behaviors.prepareSwarmArena({
        controller, bots, origin: configuration.origin, signal: abort.signal,
        actionTimeoutMs: configuration.actionTimeoutMs, record
      }), setupTimeoutMs, 'Swarm arena setup', abort.signal)
      report.arena = boundedValue(arena)
    }
    if (configuration.scatter !== undefined) {
      await bounded(behaviors.scatterSwarm({
        controller, bots, origin: configuration.origin, radius: configuration.scatter,
        signal: abort.signal, actionTimeoutMs: configuration.actionTimeoutMs, record
      }), setupTimeoutMs, 'Swarm scatter', abort.signal)
    }
    let executeActivity
    if (configuration.profile === 'stress') {
      executeActivity = await bounded(stressActions.createStressExecutor({
        bots, controller, arena, configuration, signal: abort.signal, record,
        actionTimeoutMs: configuration.actionTimeoutMs
      }), setupTimeoutMs, 'Stress workload setup', abort.signal)
    }
    actionStart = now()
    stage = 'actions'
    actionsActive = true
    const coordinator = behaviors.SwarmCoordinator === undefined ? undefined : new behaviors.SwarmCoordinator()
    const deadline = actionStart + configuration.durationMs
    if (containsWorker !== undefined) {
      for (const bot of bots) checkBounds(bot)
      if (abort.signal.aborted) throw abort.signal.reason
      boundsTimer = setInterval(() => { for (const bot of bots) checkBounds(bot) }, 100)
    }
    report.actionsStartedAt = new Date().toISOString()
    for (const summary of report.bots) summary.status = 'running'
    notice(`[INFO] Swarm ${configuration.profile}: ${bots.length} workers${controller ? ' plus one setup controller' : ''}; ${configuration.durationMs / 1000}s; seed ${configuration.seed}`)
    const work = configuration.profile === 'stress'
      ? stress.runStressWorkload({ bots, controller, arena, configuration, signal: abort.signal, record, executeActivity, now })
      : configuration.profile === 'custom'
      ? plans.runSwarmPlan({
        bots, controller, plan: configuration.plan, origin: configuration.origin, seed: configuration.seed,
        deadline, signal: abort.signal, record, actionTimeoutMs: configuration.actionTimeoutMs, chat: configuration.chat
      })
      : Promise.all(bots.map((bot, index) => Promise.resolve().then(() => behaviors.runSwarmWorker({
        bot, index, profile: configuration.profile, arena, seed: configuration.seed,
        radius: configuration.radius, deadline, signal: abort.signal, record,
        actionTimeoutMs: configuration.actionTimeoutMs, observer: controller ?? bots[0], chat: configuration.chat,
        coordinator
      }))))
    if (configuration.profile === 'stress') {
      stressSettlement = Promise.resolve(work).then(
        (summary) => { report.workloadSummary = summary },
        (error) => { if (error?.summary !== undefined) report.workloadSummary = error.summary }
      )
    }
    const result = await bounded(work, configuration.durationMs + configuration.actionTimeoutMs + 1000, 'Swarm actions', abort.signal)
    if (configuration.profile === 'stress') {
      report.workloadSummary = result
      if (result?.status !== 'passed') throw Object.assign(new Error('Stress workload did not satisfy its completion requirements'), { summary: result })
    } else if (configuration.profile === 'custom') {
      if (passedPhases !== configuration.plan.phases.length) throw new Error('Custom swarm plan did not complete every phase')
    } else if (configuration.profile !== 'idle') {
      const inactive = report.bots.filter((bot) => bot.actions === 0)
      if (inactive.length > 0) throw new Error(`No successful action completed by: ${inactive.map((bot) => bot.username).join(', ')}`)
    }
    if (abort.signal.aborted) throw abort.signal.reason
    if (!['custom', 'stress'].includes(configuration.profile) && now() < deadline) {
      await delay(deadline - now(), abort.signal)
    }
    report.actionDurationMs = Math.max(0, Math.round(now() - actionStart))
    report.status = 'passed'
    for (const summary of report.bots) summary.status = 'passed'
  } catch (error) {
    if (error?.summary !== undefined) report.workloadSummary = error.summary
    fail(error)
    report.status = cancelled ? 'cancelled' : 'failed'
    report.errors.push({ name: failure?.name ?? 'Error', message: message(failure ?? error) })
    for (const summary of report.bots) {
      if (summary.status !== 'pending') summary.status = report.status
    }
  } finally {
    closing = true
    abort.abort(new Error('Swarm finished'))
    clearInterval(progress)
    clearInterval(checkpointTimer)
    clearInterval(boundsTimer)
    for (const owned of clients) cancelActions(owned.bot)
    const cleanup = await Promise.allSettled([
      bounded((async () => {
        if (viewerState !== undefined) await stopViewer(viewerBot, viewerState, viewerMetadata)
        else await viewerBot?.viewer?.close?.()
      })(), cleanupTimeoutMs, 'Viewer cleanup'),
      ...clients.map((owned) => disconnect(owned, cleanupTimeoutMs))
    ])
    if (stressSettlement !== undefined) {
      cleanup.push(await bounded(stressSettlement, dependencies.stressCleanupTimeoutMs ?? 6000, 'Stress scheduler cleanup')
        .then(() => ({ status: 'fulfilled' }), (reason) => ({ status: 'rejected', reason })))
    }
    for (const result of cleanup) {
      if (result.status === 'rejected') {
        report.errors.push({ name: 'CleanupError', message: message(result.reason) })
        if (report.status === 'passed') report.status = 'failed'
      }
    }
    signals.removeListener('SIGINT', onInterrupt)
    signals.removeListener('SIGTERM', onTerminate)
    report.finishedAt = new Date().toISOString()
    report.durationMs = Math.max(0, Math.round(now() - started))
    report.cleanup = { clients: clients.length, disconnected: clients.filter((client) => client.ended).length }
    if (report.controller !== undefined) report.controller.status = report.status === 'passed' ? 'completed' : report.status
    if (hostMetrics !== undefined) { captureMetrics(); hostMetrics.close() }
  }
  await checkpointTask
  await writeReport(report, configuration.artifactsDirectory)
  return report
}

async function loadRuntime() {
  const mineflayerModule = await import('mineflayer')
  const { Movements, pathfinder } = await import('mineflayer-pathfinder')
  const mineflayer = mineflayerModule.default ?? mineflayerModule
  return {
    createBot: (options) => mineflayer.createBot(options),
    installPathfinder: (bot) => bot.loadPlugin(pathfinder),
    configureMovements: (bot) => {
      const movements = new Movements(bot)
      movements.canDig = false
      movements.allow1by1towers = false
      movements.scafoldingBlocks = []
      movements.allowParkour = false
      bot.pathfinder.setMovements(movements)
      bot.pathfinder.tickTimeout = 5
      bot.pathfinder.thinkTimeout = 1000
    }
  }
}

function createHostMetrics() {
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
      const sample = {
        at: new Date().toISOString(), rssBytes: process.memoryUsage().rss,
        cpuPercent: cpuMicroseconds / (elapsedMs * 10),
        eventLoopDelayMs: { mean: finite(lag.mean / 1e6), max: finite(lag.max / 1e6), p95: finite(lag.percentile(95) / 1e6) }
      }
      previousCpu = currentCpu
      previousTime = currentTime
      lag.reset()
      return sample
    },
    close() { lag.disable() }
  }
}

function waitForSpawn(bot, signal) {
  return new Promise((resolve, reject) => {
    const cleanup = () => {
      bot.removeListener('spawn', spawned)
      signal.removeEventListener('abort', aborted)
    }
    const spawned = () => { cleanup(); resolve() }
    const aborted = () => { cleanup(); reject(signal.reason) }
    bot.once('spawn', spawned)
    signal.addEventListener('abort', aborted, { once: true })
    if (signal.aborted) aborted()
  })
}

function bounded(promise, milliseconds, label, signal) {
  return new Promise((resolve, reject) => {
    const timer = setTimeout(() => finish(reject, new Error(`${label} timed out after ${milliseconds}ms`)), milliseconds)
    const abort = () => finish(reject, signal.reason)
    const finish = (settle, value) => {
      clearTimeout(timer)
      signal?.removeEventListener('abort', abort)
      settle(value)
    }
    signal?.addEventListener('abort', abort, { once: true })
    Promise.resolve(promise).then((value) => finish(resolve, value), (error) => finish(reject, error))
    if (signal?.aborted) abort()
  })
}

function delay(milliseconds, signal) {
  return new Promise((resolve, reject) => {
    const timer = setTimeout(() => { cleanup(); resolve() }, milliseconds)
    const abort = () => { cleanup(); reject(signal.reason) }
    const cleanup = () => { clearTimeout(timer); signal.removeEventListener('abort', abort) }
    signal.addEventListener('abort', abort, { once: true })
    if (signal.aborted) abort()
  })
}

function cancelActions(bot) {
  for (const action of [
    () => bot.pathfinder?.setGoal(null), () => bot.pathfinder?.stop(),
    () => bot.clearControlStates?.(), () => bot.stopDigging?.()
  ]) {
    try { Promise.resolve(action()).catch(() => {}) } catch {}
  }
}

async function disconnect(owned, timeoutMs) {
  const { bot, summary } = owned
  try {
    if (!owned.ended) {
      const ended = new Promise((resolve) => bot.once('end', resolve))
      try { bot.quit('Multiplexor swarm complete') } catch {}
      try {
        await bounded(ended, timeoutMs, `${summary.username} disconnect`)
      } catch {
        summary.forcedDisconnect = true
        try { bot.end('Multiplexor swarm cleanup') } catch {}
        try { bot._client?.end?.('Multiplexor swarm cleanup') } catch {}
        try { bot._client?.socket?.destroy?.() } catch {}
        try { await bounded(ended, timeoutMs, `${summary.username} forced disconnect`) } catch {
          throw new Error(`${summary.username} did not confirm disconnection after forced cleanup`)
        }
      }
    }
    summary.disconnected = true
  } finally {
    if (owned.ended) {
      for (const [event, listener] of owned.listeners) bot.removeListener(event, listener)
    }
  }
}

function boundedValue(value, depth = 0) {
  if (value === null || typeof value === 'boolean' || typeof value === 'number') return value
  if (typeof value === 'string') return value.slice(0, 512)
  if (depth > 4) return '[truncated]'
  if (Array.isArray(value)) return value.slice(0, 64).map((entry) => boundedValue(entry, depth + 1))
  if (value !== undefined && typeof value === 'object') {
    return Object.fromEntries(Object.entries(value).slice(0, 32).map(([key, entry]) => [key, boundedValue(entry, depth + 1)]))
  }
  return undefined
}

function message(value) {
  if (value instanceof Error) return value.message.slice(0, 2048)
  if (typeof value === 'string') return value.slice(0, 2048)
  try { return JSON.stringify(boundedValue(value)) ?? String(value) } catch { return String(value).slice(0, 2048) }
}

async function writeReport(report, directory) {
  await mkdir(directory, { recursive: true })
  const timestamp = report.startedAt.replaceAll(':', '').replaceAll('.', '-')
  const instance = String(report.server.instance).replaceAll(/[^A-Za-z0-9_.-]/g, '-')
  report.artifact = path.join(directory, `${timestamp}-${instance}-swarm-${report.configuration.prefix}.json`)
  const temporary = `${report.artifact}.${process.pid}.tmp`
  await writeFile(temporary, `${JSON.stringify(report, null, 2)}\n`)
  await rename(temporary, report.artifact)
}
