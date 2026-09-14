import { setMaxListeners } from 'node:events'
import { pause, seededRandom } from './swarm_actions.mjs'
import { assignRoles, STRESS_ACTIVITIES } from './swarm_workload.mjs'

const LATENCY_BOUNDS = [10, 25, 50, 100, 250, 500, 1000, 2500, 5000, 10000, 30000, 60000, 120000, Infinity]

export class StressCoordinator {
  #claims = new Set()
  async claim(position, action) {
    const key = typeof position === 'string' ? position : `${position.x ?? position[0]},${position.y ?? position[1]},${position.z ?? position[2]}`
    if (this.#claims.has(key)) return { status: 'skipped', skipped: true, reason: 'Target is reserved by another worker' }
    this.#claims.add(key)
    try { return await action() } finally { this.#claims.delete(key) }
  }
  get reserved() { return this.#claims.size }
}

export function weightedChoice(weights, random) {
  const entries = Object.entries(weights).filter(([, weight]) => weight > 0)
  const total = entries.reduce((sum, [, weight]) => sum + weight, 0)
  if (!entries.length || !Number.isFinite(total)) throw new Error('Activity weights must have a finite positive total')
  let choice = random() * total
  for (const [name, weight] of entries) {
    choice -= weight
    if (choice < 0) return name
  }
  return entries.at(-1)[0]
}


class RunComplete extends Error {}

function serializeLatency(entry) {
  const percentile = (fraction) => {
    const threshold = Math.ceil(entry.count * fraction)
    let cumulative = 0
    for (let index = 0; index < entry.buckets.length; index++) {
      cumulative += entry.buckets[index]
      if (cumulative >= threshold) return Number.isFinite(LATENCY_BOUNDS[index]) ? LATENCY_BOUNDS[index] : entry.maxMs
    }
    return 0
  }
  return {
    count: entry.count, minMs: entry.minMs, maxMs: entry.maxMs, meanMs: entry.totalMs / entry.count,
    p50UpperMs: percentile(0.5), p95UpperMs: percentile(0.95),
    buckets: entry.buckets.map((count, index) => ({ upperMs: Number.isFinite(LATENCY_BOUNDS[index]) ? LATENCY_BOUNDS[index] : null, count }))
  }
}

async function executeBounded(action, timeoutMs, parent, onAbort) {
  const controller = new AbortController()
  const timeoutError = new Error(`Stress activity timed out after ${Math.ceil(timeoutMs)}ms`)
  let settlementTimer
  let unresponsiveReject
  const unresponsive = new Promise((resolve, reject) => { unresponsiveReject = reject })
  const cancel = () => {
    controller.abort(parent.reason)
  }
  const aborted = () => {
    onAbort?.()
    // Never dispatch another job while a cancelled action can still own its bot.
    settlementTimer = setTimeout(() => {
      const error = new Error('Cancelled stress activity did not settle within 5 seconds')
      error.fatal = true
      unresponsiveReject(error)
    }, 5000)
  }
  controller.signal.addEventListener('abort', aborted, { once: true })
  parent.throwIfAborted()
  parent.addEventListener('abort', cancel, { once: true })
  const timer = setTimeout(() => controller.abort(timeoutError), timeoutMs)
  try {
    const result = await Promise.race([Promise.resolve().then(() => action(controller.signal)), unresponsive])
    controller.signal.throwIfAborted()
    return result
  } finally {
    clearTimeout(timer)
    clearTimeout(settlementTimer)
    parent.removeEventListener('abort', cancel)
    controller.signal.removeEventListener('abort', aborted)
  }
}

export async function runStressWorkload({ bots, controller, arena, configuration, signal, record = () => {}, executeActivity, now = () => performance.now() }) {
  const workload = configuration.workload
  if (!workload || typeof executeActivity !== 'function') throw new Error('Stress workloads require normalized configuration and an activity executor')
  signal?.throwIfAborted()
  const started = now()
  const deadline = started + configuration.durationMs
  const run = new AbortController()
  setMaxListeners(0, run.signal)
  const coordinator = new StressCoordinator()
  const roles = assignRoles(workload.roles, bots.length)
  const maximumActive = Math.max(...workload.schedule.map((stage) => stage.activeBots))
  for (const goal of Object.keys(workload.goals)) {
    if (!roles.slice(0, maximumActive).some((role) => role.activities[goal] > 0)) {
      throw new Error(`Goal ${goal} has no assigned active worker; add bots, change the schedule, or revise role weights`)
    }
  }
  const workers = bots.map((bot, index) => ({
    username: bot.username, index, role: roles[index].name, state: 'scheduled', completed: 0, productive: 0,
    attempted: 0, failed: 0, skipped: 0, blocksWalked: 0, newChunkVisits: 0, consecutiveFailures: 0, lastActivity: null, lastError: null,
    activeMs: 0, activeSince: null, lastProgress: started, everActive: false, counts: {}
  }))
  const totals = { completed: 0, attempted: 0, failed: 0, skipped: 0, blocksWalked: 0, newChunkVisits: 0 }
  const counts = {}
  const latency = new Map()
  let scheduleIndex = 0
  let failure
  let status = 'running'
  const goalsMet = () => Object.entries(workload.goals).every(([activity, target]) => (counts[activity] ?? 0) >= target)
  const stageAt = () => {
    while (scheduleIndex + 1 < workload.schedule.length && now() - started >= workload.schedule[scheduleIndex + 1].atSeconds * 1000) {
      scheduleIndex++
      record({ type: 'stress-stage', scheduleIndex, ...workload.schedule[scheduleIndex] })
    }
    return workload.schedule[scheduleIndex]
  }
  const snapshot = () => ({
    name: workload.name, status, completion: workload.completion, elapsedMs: Math.max(0, now() - started), activeBots: stageAt().activeBots,
    ...totals, counts: { ...counts }, scheduleIndex, reservations: coordinator.reserved,
    goals: Object.fromEntries(Object.entries(workload.goals).map(([activity, target]) => [activity, { target, completed: counts[activity] ?? 0, met: (counts[activity] ?? 0) >= target }])),
    latency: Object.fromEntries([...latency].map(([activity, entry]) => [activity, serializeLatency(entry)])),
    workers: workers.map((worker) => ({ ...worker, counts: { ...worker.counts }, activeMs: worker.activeMs + (worker.activeSince === null ? 0 : now() - worker.activeSince), activeSince: undefined, lastProgress: undefined }))
  })
  const publish = () => record({ type: 'stress-summary', summary: snapshot() })
  const fail = (error) => {
    if (!failure) failure = error instanceof Error ? error : new Error(String(error))
    if (!run.signal.aborted) run.abort(failure)
  }
  const parentCancelled = () => { run.abort(signal.reason ?? new Error('Stress run cancelled')) }
  signal?.addEventListener('abort', parentCancelled, { once: true })
  const durationTimer = setTimeout(() => run.abort(new RunComplete('Duration reached')), configuration.durationMs)
  const reportTimer = setInterval(() => {
    try { publish() } catch (error) { fail(error) }
  }, workload.reportIntervalSeconds * 1000)
  const deactivate = (worker) => {
    if (worker.activeSince !== null) {
      worker.activeMs += Math.max(0, now() - worker.activeSince)
      worker.activeSince = null
    }
  }
  const runWorker = async (bot, index) => {
    const worker = workers[index]
    const role = roles[index]
    const random = seededRandom((configuration.seed + Math.imul(index + 1, 2654435761)) >>> 0)
    try {
      while (!run.signal.aborted) {
        if (now() >= deadline) { run.abort(new RunComplete('Duration reached')); break }
        if (index >= stageAt().activeBots) {
          worker.state = 'scheduled'
          deactivate(worker)
          await pause(Math.min(250, deadline - now()), run.signal)
          continue
        }
        if (worker.activeSince === null) {
          worker.activeSince = now()
          worker.lastProgress = now()
          worker.everActive = true
        }
        if (now() - worker.lastProgress >= workload.stallTimeoutSeconds * 1000) throw new Error(`${bot.username} made no productive progress for ${workload.stallTimeoutSeconds} seconds`)
        const weights = workload.completion === 'goals'
          ? Object.fromEntries(Object.entries(role.activities).map(([activity, weight]) => [activity,
              weight * (workload.goals[activity] !== undefined && (counts[activity] ?? 0) < workload.goals[activity] ? 4 : 1)]))
          : role.activities
        const activity = weightedChoice(weights, random)
        worker.lastActivity = activity
        worker.state = 'working'
        worker.attempted++
        totals.attempted++
        const jobStarted = now()
        let outcome = 'cancelled'
        try {
          const result = await executeBounded((current) => executeActivity({
            bot, index, activity, role, signal: current, deadline, record, coordinator, workload,
            configuration, controller, observer: controller, arena, random, worker, counts
          }), configuration.actionTimeoutMs, run.signal, () => bot.clearControlStates?.())
          run.signal.throwIfAborted()
          if (result?.skipped || result?.status === 'skipped') {
            worker.skipped++
            totals.skipped++
            outcome = 'skipped'
            record({ bot: bot.username, index, action: activity, status: 'skipped', stress: true, reason: String(result.reason ?? 'No available job').slice(0, 512) })
          } else {
            const verified = result?.counts ?? { [activity]: 1 }
            if (!verified || typeof verified !== 'object' || Array.isArray(verified) || Object.keys(verified).length === 0 || Object.entries(verified).some(([name, count]) => !STRESS_ACTIVITIES.includes(name) || !Number.isSafeInteger(count) || count < 1 || count > 1000000)) {
              const error = new Error('Activity executor returned invalid verified counts')
              error.fatal = true
              throw error
            }
            for (const source of ['distance', 'chunks']) {
              const value = result?.[source] ?? 0
              if (!Number.isFinite(value) || value < 0 || (source === 'chunks' && !Number.isSafeInteger(value))) {
                const error = new Error(`Activity executor returned invalid ${source}`)
                error.fatal = true
                throw error
              }
            }
            totals.blocksWalked += result?.distance ?? 0
            worker.blocksWalked += result?.distance ?? 0
            totals.newChunkVisits += result?.chunks ?? 0
            worker.newChunkVisits += result?.chunks ?? 0
            outcome = 'passed'
            worker.completed++
            totals.completed++
            worker.consecutiveFailures = 0
            worker.lastError = null
            if (Object.keys(verified).some((name) => name !== 'idle') || Object.keys(role.activities).every((name) => name === 'idle')) {
              worker.productive++
              worker.lastProgress = now()
            }
            for (const [name, count] of Object.entries(verified)) {
              counts[name] = (counts[name] ?? 0) + count
              worker.counts[name] = (worker.counts[name] ?? 0) + count
            }
            const details = {}
            if (result?.destination) {
              const destination = Array.isArray(result.destination) ? result.destination : [result.destination.x, result.destination.y, result.destination.z]
              if (destination.length === 3 && destination.every(Number.isFinite)) details.destination = [...destination]
            }
            for (const key of ['item', 'message']) if (typeof result?.[key] === 'string') details[key] = result[key].slice(0, 256)
            if (Number.isSafeInteger(result?.count) && result.count >= 0) details.count = result.count
            if (result?.distance !== undefined) details.distance = result.distance
            if (result?.chunks !== undefined) details.newChunkVisits = result.chunks
            record({ bot: bot.username, index, action: activity, status: 'passed', stress: true, counts: { ...verified }, latencyMs: Math.max(0, now() - jobStarted), ...details })
            if (workload.completion === 'goals' && goalsMet()) run.abort(new RunComplete('Goals reached'))
          }
        } catch (error) {
          if (run.signal.aborted) {
            if (error?.fatal) fail(error)
            throw error
          }
          worker.failed++
          totals.failed++
          worker.consecutiveFailures++
          worker.lastError = String(error?.message ?? error).slice(0, 512)
          outcome = 'failed'
          record({ bot: bot.username, index, action: activity, status: 'failed', stress: true, error: worker.lastError })
          if (error?.fatal || worker.consecutiveFailures >= workload.failurePolicy.maxConsecutive || totals.failed >= workload.failurePolicy.maxTotal) throw error
        } finally {
          if (outcome === 'passed') {
            const duration = Math.max(0, now() - jobStarted)
            const entry = latency.get(activity) ?? { count: 0, minMs: Infinity, maxMs: 0, totalMs: 0, buckets: LATENCY_BOUNDS.map(() => 0) }
            entry.count++
            entry.minMs = Math.min(entry.minMs, duration)
            entry.maxMs = Math.max(entry.maxMs, duration)
            entry.totalMs += duration
            entry.buckets[LATENCY_BOUNDS.findIndex((bound) => duration <= bound)]++
            latency.set(activity, entry)
          }
        }
        if (run.signal.aborted) break
        worker.state = 'resting'
        const delay = workload.pacing.minMs + Math.floor(random() * (workload.pacing.maxMs - workload.pacing.minMs + 1))
        const backoff = outcome === 'passed' ? 0 : Math.min(10000, 250 * 2 ** Math.min(worker.consecutiveFailures, 5))
        await pause(Math.max(1, Math.min(Math.max(delay, backoff), deadline - now())), run.signal)
      }
    } catch (error) {
      if (!run.signal.aborted) fail(error)
    } finally {
      deactivate(worker)
      worker.state = failure ? 'failed' : 'stopped'
    }
  }
  try {
    publish()
    await Promise.all(bots.map(runWorker))
    if (signal?.aborted) throw signal.reason ?? new Error('Stress run cancelled')
    if (failure) throw failure
    if (!goalsMet()) throw new Error(`Stress goals were not reached: ${Object.entries(workload.goals).filter(([activity, target]) => (counts[activity] ?? 0) < target).map(([activity, target]) => `${activity} ${counts[activity] ?? 0}/${target}`).join(', ')}`)
    if (totals.completed === 0 || !Object.keys(counts).some((activity) => activity !== 'idle')) throw new Error('Stress workload completed no productive activities')
    if (workload.completion === 'duration') {
      const starved = workers.filter((worker) => worker.everActive && worker.productive === 0)
      if (starved.length) throw new Error(`Workers completed no productive activities: ${starved.map((worker) => worker.username).join(', ')}`)
    }
    status = 'passed'
    publish()
    return snapshot()
  } catch (reason) {
    const error = reason instanceof Error ? reason : new Error(String(reason))
    status = signal?.aborted ? 'cancelled' : 'failed'
    for (const worker of workers) worker.state = status
    error.summary = snapshot()
    publish()
    throw error
  } finally {
    clearTimeout(durationTimer)
    clearInterval(reportTimer)
    signal?.removeEventListener('abort', parentCancelled)
    if (!run.signal.aborted) run.abort(new RunComplete('Run closed'))
  }
}
