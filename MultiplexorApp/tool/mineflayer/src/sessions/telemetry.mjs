import { open } from 'node:fs/promises'

const MAX_SNAPSHOT_BYTES = 1024 * 1024

export async function readObserverSnapshot(filePath, { now = Date.now, maxAgeMs = 15000, kind } = {}) {
  if (!filePath) return { status: 'missing' }
  let file
  try {
    file = await open(filePath, 'r')
    const size = (await file.stat()).size
    if (size > MAX_SNAPSHOT_BYTES) return { status: 'invalid', reason: 'Observer snapshot exceeds 1 MiB' }
    const buffer = Buffer.alloc(Math.min(MAX_SNAPSHOT_BYTES + 1, size + 1))
    let length = 0
    while (length < buffer.length) {
      const read = await file.read(buffer, length, buffer.length - length, null)
      if (read.bytesRead === 0) break
      length += read.bytesRead
    }
    if (length > MAX_SNAPSHOT_BYTES) return { status: 'invalid', reason: 'Observer snapshot exceeds 1 MiB' }
    const snapshot = JSON.parse(buffer.subarray(0, length).toString('utf8'))
    if (snapshot?.schemaVersion !== 1 || !['paper', 'velocity'].includes(snapshot.kind) ||
        (kind && kind !== snapshot.kind) || !['running', 'stopped'].includes(snapshot.status)) {
      return { status: 'invalid', reason: 'Invalid observer snapshot contract' }
    }
    const observedAt = Date.parse(snapshot.observedAt)
    const ageMs = now() - observedAt
    if (!Number.isFinite(observedAt) || ageMs < -5000) return { status: 'invalid', reason: 'Invalid observer timestamp' }
    if (!Array.isArray(snapshot.players) || snapshot.players.length > 4096 || !Array.isArray(snapshot.events) || snapshot.events.length > 256) {
      return { status: 'invalid', reason: 'Invalid observer player or event collection' }
    }
    if (kind === 'paper' && (!Array.isArray(snapshot.worlds) || snapshot.worlds.length > 256)) {
      return { status: 'invalid', reason: 'Invalid observer world collection' }
    }
    if (snapshot.tick != null && !['p50Ms', 'p95Ms', 'p99Ms', 'maxMs', 'count', 'longTicks'].every((key) =>
      Number.isFinite(snapshot.tick[key]) && snapshot.tick[key] >= 0)) {
      return { status: 'invalid', reason: 'Invalid observer tick measurements' }
    }
    if (ageMs > maxAgeMs || snapshot.status !== 'running') return { status: 'stale', ageMs: Math.max(0, ageMs) }
    return { status: 'available', ageMs: Math.max(0, ageMs), snapshot }
  } catch (error) {
    return { status: error.code === 'ENOENT' ? 'missing' : 'invalid', reason: error.message }
  } finally {
    await file?.close()
  }
}

export function createSessionTelemetry({ target, profile, now = Date.now, initialState }) {
  const settings = profile.telemetry ?? {}
  const maxAgeMs = (settings.maxAgeSeconds ?? 15) * 1000
  const observedBackends = new Set(initialState?.observedBackends ?? [])
  const violationCounts = new Map(Object.entries(initialState?.violations ?? {}))
  let samples = initialState?.samples ?? 0
  let unavailableSamples = initialState?.unavailableSamples ?? 0
  let proxyObserved = initialState?.proxyObserved ?? false
  let latest
  let firstSampleAt
  let evaluatedSamples = initialState?.evaluatedSamples ?? 0
  const violation = (key) => violationCounts.set(key, (violationCounts.get(key) ?? 0) + 1)

  return {
    async sample() {
      firstSampleAt ??= now()
      const evaluate = now() - firstSampleAt >= (settings.warmupSeconds ?? 60) * 1000
      const backends = await Promise.all((target.backends ?? []).map(async (backend) => ({
        alias: backend.alias,
        ...(await readObserverSnapshot(backend.observerPath, { now, maxAgeMs, kind: 'paper' }))
      })))
      const proxy = target.kind === 'network'
        ? await readObserverSnapshot(target.observerPath, { now, maxAgeMs, kind: 'velocity' })
        : undefined
      samples += 1
      if (evaluate) evaluatedSamples += 1
      let unavailable = false
      for (const backend of backends) {
        if (backend.status !== 'available') {
          unavailable = true
          continue
        }
        observedBackends.add(backend.alias)
        for (const [setting, metric] of [['maxP95TickMs', 'p95Ms'], ['maxP99TickMs', 'p99Ms']]) {
          if (settings[setting] === undefined) continue
          if (!backend.snapshot.tick || backend.snapshot.tick.count === 0) unavailable = true
          else if (evaluate && backend.snapshot.tick[metric] > settings[setting]) violation(`${backend.alias}.${metric}`)
        }
      }
      if (proxy?.status === 'available') proxyObserved = true
      else if (target.kind === 'network') unavailable = true
      if (unavailable) unavailableSamples += 1
      latest = { sampledAt: new Date(now()).toISOString(), backends, ...(proxy ? { proxy } : {}) }
      return latest
    },
    currentBackend(username) {
      const proxy = latest?.proxy
      if (proxy?.status !== 'available' || now() - Date.parse(proxy.snapshot.observedAt) > maxAgeMs) return undefined
      return proxy.snapshot.players.find((player) => player.username === username)?.backend
    },
    checkpoint() {
      return {
        samples, evaluatedSamples, unavailableSamples, proxyObserved,
        observedBackends: [...observedBackends], violations: Object.fromEntries(violationCounts)
      }
    },
    summary() {
      const limitsConfigured = settings.maxP95TickMs !== undefined || settings.maxP99TickMs !== undefined
      const coverage = observedBackends.size === (target.backends ?? []).length &&
        (target.kind !== 'network' || proxyObserved) && samples > 0 && observedBackends.size > 0
      const unavailable = !coverage || unavailableSamples > 0 || evaluatedSamples === 0
      return {
        status: violationCounts.size > 0 || (settings.required === true && unavailable)
          ? 'failed' : unavailable ? 'unavailable' : limitsConfigured ? 'passed' : 'measured',
        limitsConfigured,
        required: settings.required === true, samples, evaluatedSamples, unavailableSamples,
        observedBackends: [...observedBackends], proxyObserved,
        violations: Object.fromEntries(violationCounts)
      }
    },
    close() {}
  }
}
