import { playerNames } from './configuration.mjs'
import { delay } from './transport.mjs'
import { performance } from 'node:perf_hooks'

export function randomFor(player) {
  return () => {
    let value = player.randomState >>> 0
    value ^= value << 13
    value ^= value >>> 17
    value ^= value << 5
    player.randomState = value >>> 0 || 1
    return player.randomState / 4294967296
  }
}

export function sampleSeconds(range, random) { return (range[0] + random() * (range[1] - range[0])) * 1000 }

export function createRoster(profile) {
  return playerNames(profile).map((username, index) => ({
    id: `player-${index + 1}`, username, role: profile.playerRoles[index % profile.playerRoles.length],
    randomState: ((profile.seed + Math.imul(index + 1, 2654435761)) >>> 0) || 1,
    lifecycle: 'offline', generation: 0, homeWorld: profile.playerWorlds[index % profile.playerWorlds.length],
    socialGroup: `group-${Math.floor(index / profile.population.groupSize) + 1}`,
    backend: profile.worlds.find((world) => world.id === profile.playerWorlds[index % profile.playerWorlds.length]).backend,
    dueAtMs: index * profile.population.arrivalIntervalSeconds * 1000,
    sessions: 0, joins: 0, failures: 0, consecutiveFailures: 0, intent: {}, observations: {}, task: null,
    counters: {}, status: 'Waiting for scheduled arrival'
  }))
}

export function desiredPopulation(profile, elapsedMs) {
  let target = profile.population.concurrent
  for (const stage of profile.population.stages) {
    if (elapsedMs < stage.atSeconds * 1000) break
    target = stage.concurrent
  }
  return target
}

export function arrivalsDue(players, elapsedMs, capacity) {
  return players.filter((player) => player.lifecycle === 'offline' && player.dueAtMs <= elapsedMs)
    .sort((left, right) => left.dueAtMs - right.dueAtMs || left.id.localeCompare(right.id))
    .slice(0, Math.max(0, capacity))
}

export function admitNextArrival(players, population, elapsedMs, capacity, intervalMs) {
  if (capacity <= 0 || elapsedMs < (population.nextArrivalAtMs ?? 0)) return undefined
  const player = arrivalsDue(players, elapsedMs, 1)[0]
  if (!player) return undefined
  population.nextArrivalAtMs = elapsedMs + intervalMs
  return player
}

export class SessionConnectionGate {
  constructor(state, intervalMs, { now = Date.now, monotonicNow = () => performance.now(), wait = delay, resume = false } = {}) {
    this.state = state
    this.intervalMs = intervalMs
    this.now = now
    this.monotonicNow = monotonicNow
    this.wait = wait
    this.pending = Promise.resolve()
    state.nextConnectionAtEpochMs = Math.max(state.nextConnectionAtEpochMs ?? 0, resume ? now() + intervalMs : 0)
    this.nextConnectionAt = monotonicNow() + Math.max(0, state.nextConnectionAtEpochMs - now())
  }

  async run(start, signal) {
    const queued = this.pending.then(async () => {
      while (this.monotonicNow() < this.nextConnectionAt) await this.wait(this.nextConnectionAt - this.monotonicNow(), signal)
      signal?.throwIfAborted()
      this.state.lastConnectionAttemptAtEpochMs = this.now()
      try {
        // The queue owns synchronous connection setup; the handshake promise remains independent.
        return { operation: start() }
      } finally {
        this.state.nextConnectionAtEpochMs = this.now() + this.intervalMs
        this.nextConnectionAt = this.monotonicNow() + this.intervalMs
      }
    })
    this.pending = queued.then(() => {}, () => {})
    return (await queued).operation
  }
}

export function prepareResume(players, profile, elapsedMs) {
  const expected = createRoster(profile)
  if (players.length !== expected.length) throw new Error('Checkpoint roster size changed')
  for (let index = 0; index < players.length; index++) {
    const player = players[index]
    if (player.id !== expected[index].id || player.username !== expected[index].username || player.role !== expected[index].role || !Number.isInteger(player.randomState)) throw new Error('Checkpoint identity does not match the profile')
    player.generation += 1
    if (player.lifecycle !== 'retired') {
      if (player.lifecycle !== 'offline' || player.interrupted) player.dueAtMs = elapsedMs
      player.lifecycle = 'offline'
      player.status = player.task ? 'Reconnecting to reconcile interrupted work' : 'Waiting to resume'
    }
  }
}

export function goalsSatisfied(profile, summary, counters) {
  const goals = Object.entries(profile.goals)
  if (!goals.length) return summary.goalsMet === true
  return goals.every(([name, expected]) => Number(summary[name] ?? counters[name] ?? 0) >= expected)
}

const LATENCY_LIMITS = [10, 25, 50, 100, 250, 500, 1000, 2500, 5000, 10000, 30000, 60000, 300000, Infinity]
export function recordLatency(metrics, outcome, elapsedMs) {
  const entry = metrics[outcome] ??= { count: 0, totalMs: 0, maxMs: 0, buckets: LATENCY_LIMITS.map((upperMs) => ({ upperMs: Number.isFinite(upperMs) ? upperMs : null, count: 0 })) }
  entry.count += 1
  entry.totalMs += elapsedMs
  entry.maxMs = Math.max(entry.maxMs, elapsedMs)
  entry.buckets[LATENCY_LIMITS.findIndex((upperMs) => elapsedMs <= upperMs)].count += 1
}
