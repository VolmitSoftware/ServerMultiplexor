async function walk(bot, point, signal) {
  const { walkTo } = await import('./swarm_actions.mjs')
  return walkTo(bot, point, signal)
}

function coordinate(value) {
  if (!value || !['x', 'y', 'z'].every((axis) => Number.isFinite(value[axis]))) throw new Error('Movement requires finite x, y, z coordinates')
  return { x: value.x, y: value.y, z: value.z }
}

export function circleRoute({ center, radius = 8, laps = 1, clockwise = true }) {
  center = coordinate(center)
  if (!Number.isFinite(radius) || radius < 4 || radius > 128) throw new Error('Circle radius must be 4–128 blocks')
  if (!Number.isInteger(laps) || laps < 1 || laps > 100) throw new Error('Circle laps must be 1–100')
  if (typeof clockwise !== 'boolean') throw new Error('Circle clockwise must be boolean')
  const segments = Math.ceil(2 * Math.PI * radius / 2)
  const direction = clockwise ? 1 : -1
  return Array.from({ length: segments * laps + 1 }, (_, index) => {
    const angle = direction * index * 2 * Math.PI / segments
    return { x: center.x + radius * Math.cos(angle), y: center.y, z: center.z + radius * Math.sin(angle) }
  })
}

export function createCircleTracker({ center, radius, clockwise = true, tolerance = 2 }) {
  center = coordinate(center)
  let previous
  let angle = 0
  let distance = 0
  let samples = 0
  const direction = clockwise ? 1 : -1
  return {
    sample(value) {
      const current = coordinate(value)
      const deviation = Math.abs(Math.hypot(current.x - center.x, current.z - center.z) - radius)
      if (deviation > tolerance) throw new Error(`Circle left its radius: ${deviation.toFixed(2)} blocks deviation`)
      if (Math.abs(current.y - center.y) > 2) throw new Error('Circle left its walking elevation')
      if (previous) {
        const step = Math.hypot(current.x - previous.x, current.y - previous.y, current.z - previous.z)
        if (step > 3) throw new Error('Circle position jumped instead of walking')
        const before = Math.atan2(previous.z - center.z, previous.x - center.x)
        const after = Math.atan2(current.z - center.z, current.x - center.x)
        angle += direction * Math.atan2(Math.sin(after - before), Math.cos(after - before))
        distance += step
      }
      previous = current
      samples += 1
    },
    result() { return { laps: angle / (2 * Math.PI), distance, samples } }
  }
}

export function createScenarioActions({ bot, signal, waitUntil, record = () => {}, move = walk }) {
  async function bounded(label, timeoutMs, action) {
    if (!Number.isFinite(timeoutMs) || timeoutMs <= 0 || timeoutMs > 3_600_000) throw new Error('Action timeout must be 1–3600000 ms')
    signal.throwIfAborted()
    const abort = new AbortController()
    const current = AbortSignal.any([signal, abort.signal])
    const timer = setTimeout(() => abort.abort(new Error(`${label} timed out`)), timeoutMs)
    let rejectAbort
    const stopped = new Promise((_, reject) => { rejectAbort = () => reject(current.reason); current.addEventListener('abort', rejectAbort, { once: true }) })
    try { return await Promise.race([Promise.resolve().then(() => action(current)), stopped]) }
    finally {
      clearTimeout(timer)
      current.removeEventListener('abort', rejectAbort)
      abort.abort(new Error(`${label} finished`))
      bot.pathfinder?.setGoal(null)
      bot.clearControlStates()
    }
  }

  return {
    async walkRoute(points, { timeoutMs = 30_000 } = {}) {
      if (!Array.isArray(points) || points.length < 1 || points.length > 50_000) throw new Error('Route requires 1–50000 points')
      const route = points.map(coordinate)
      return bounded('Walking route', timeoutMs, async (current) => {
        for (const point of route) { current.throwIfAborted(); await move(bot, point, current) }
        const result = { action: 'walkRoute', waypoints: route.length, position: coordinate(bot.entity.position) }
        record(result)
        return result
      })
    },
    async walkCircle({ center, radius = 8, laps = 1, clockwise = true, timeoutMs = 120_000 }) {
      const route = circleRoute({ center, radius, laps, clockwise })
      return bounded('Walking circle', timeoutMs, async (current) => {
        await move(bot, route[0], current)
        const tracker = createCircleTracker({ center, radius, clockwise })
        let error
        const sample = () => {
          if (error) return
          try { tracker.sample(bot.entity.position) } catch (failure) { error = failure; bot.pathfinder?.setGoal(null); bot.clearControlStates() }
        }
        sample()
        bot.on('physicsTick', sample)
        try {
          for (const point of route.slice(1)) {
            if (error) throw error
            current.throwIfAborted()
            await move(bot, point, current)
            sample()
          }
          if (error) throw error
          const result = tracker.result()
          if (result.laps < laps - 0.06) throw new Error(`Circle completed ${result.laps.toFixed(2)} of ${laps} laps`)
          record({ action: 'walkCircle', radius, requestedLaps: laps, ...result })
          return result
        } finally { bot.removeListener('physicsTick', sample) }
      })
    },
    async attackPlayer(target, { hits = 1, minimumHealth = 4, timeoutMs = 15_000 } = {}) {
      if (!target?.username || typeof target.on !== 'function' || typeof target.removeListener !== 'function' || target === bot || !Number.isInteger(hits) || hits < 1 || hits > 100) throw new Error('Combat requires another connected actor and 1–100 hits')
      return bounded('Player combat', timeoutMs, async (current) => {
        let confirmed = 0
        const damage = []
        for (; confirmed < hits; confirmed += 1) {
          current.throwIfAborted()
          if (!Number.isFinite(target.health) || target.health <= minimumHealth) throw new Error('Combat target reached its health floor')
          const entity = await waitUntil(() => {
            const candidate = bot.players[target.username]?.entity
            return candidate && bot.entity.position.distanceTo(candidate.position) <= 3 ? candidate : false
          }, { label: 'combat target within melee reach', timeoutMs: 2500, signal: current })
          await bot.lookAt(entity.position.offset(0, 1, 0), true)
          current.throwIfAborted()
          const before = target.health
          let attributed
          let observedHealth = before
          const healthChanged = () => { observedHealth = Math.min(observedHealth, target.health) }
          const hurt = (victim, source) => {
            if (victim?.id === entity.id && source?.id === bot.entity.id) {
              attributed = { victimId: victim.id, attackerId: source.id }
            }
          }
          bot.on('entityHurt', hurt)
          target.on('health', healthChanged)
          try {
            bot.attack(entity)
            const after = await waitUntil(() => { healthChanged(); return attributed && observedHealth < before ? { health: observedHealth } : false },
              { label: 'attacker-attributed combat damage and health loss', timeoutMs: 2500, signal: current })
            damage.push({ before, after: after.health, amount: before - after.health, ...attributed })
          } finally { bot.removeListener('entityHurt', hurt); target.removeListener('health', healthChanged) }
          const recoverAt = performance.now() + 650
          await waitUntil(() => performance.now() >= recoverAt, { label: 'combat recovery', timeoutMs: 2500, signal: current })
        }
        const result = { action: 'attackPlayer', target: target.username, confirmedHits: confirmed, damage, health: target.health }
        record(result)
        return result
      })
    }
  }
}
