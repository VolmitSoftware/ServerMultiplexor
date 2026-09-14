import { readFile } from 'node:fs/promises'

export function sessionError(message, kind = 'transport') { const error = new Error(message); error.kind = kind; return error }

export function reasonText(reason) {
  if (typeof reason === 'string') return reason.slice(0, 1024)
  if (reason instanceof Error) return reason.message.slice(0, 1024)
  try { return JSON.stringify(reason).slice(0, 1024) } catch { return String(reason).slice(0, 1024) }
}

export function installConfigurationBarrier(bot, protocolForVersion, record = () => {}) {
  const client = bot._client
  if (!client || !protocolForVersion) return () => {}
  const write = client.write
  let allowed
  const guarded = function (name, params) {
    if (this.state === 'configuration') {
      allowed ??= new Set(Object.keys(protocolForVersion(this.version).configuration.toServer.types.packet[1][1].type[1].fields))
      // Mineflayer's physics timer can outlive PLAY until the next backend sends its login packet.
      if (!allowed.has(name)) { record({ type: 'configuration-packet-suppressed', packet: name }); return }
    }
    return write.call(this, name, params)
  }
  client.write = guarded
  return () => { if (client.write === guarded) client.write = write }
}

export function installArrivalReadiness(bot, record = () => {}) {
  const client = bot._client
  if (!client) return { acknowledge() {}, dispose() {} }
  let acknowledged = false
  const write = client.write
  const tracked = function (name, params) {
    const result = write.call(this, name, params)
    if (name === 'player_loaded' && this.state === 'play') acknowledged = true
    return result
  }
  const reset = () => { acknowledged = false }
  client.write = tracked
  client.on('login', reset)
  client.on('respawn', reset)
  return {
    acknowledge() {
      if (!bot.supportFeature?.('sendsPlayerLoadedPacket') || acknowledged) return
      if (client.state !== 'play') throw sessionError(`${bot.username} has not entered gameplay after loading the world`, 'world-readiness')
      // Proxy backend login can skip Mineflayer's spawn event and its player_loaded acknowledgment.
      client.write('player_loaded', {})
      record({ type: 'world-ready-acknowledged' })
    },
    dispose() {
      client.removeListener('login', reset)
      client.removeListener('respawn', reset)
      if (client.write === tracked) client.write = write
    }
  }
}

export function delay(milliseconds, signal) {
  return new Promise((resolve, reject) => {
    const cleanup = () => { clearTimeout(timer); signal?.removeEventListener('abort', aborted) }
    const aborted = () => { cleanup(); reject(signal.reason) }
    const timer = setTimeout(() => { cleanup(); resolve() }, Math.max(0, milliseconds))
    signal?.addEventListener('abort', aborted, { once: true })
    if (signal?.aborted) aborted()
  })
}

export function bounded(promise, milliseconds, label, signal) {
  return new Promise((resolve, reject) => {
    let done = false
    const finish = (settle, value) => {
      if (done) return
      done = true
      clearTimeout(timer)
      signal?.removeEventListener('abort', aborted)
      settle(value)
    }
    const aborted = () => finish(reject, signal.reason)
    const timer = setTimeout(() => finish(reject, sessionError(`${label} timed out after ${milliseconds}ms`, 'timeout')), milliseconds)
    signal?.addEventListener('abort', aborted, { once: true })
    Promise.resolve(promise).then((value) => finish(resolve, value), (error) => finish(reject, error))
    if (signal?.aborted) aborted()
  })
}

export function cancelBot(bot) {
  if (!bot) return
  for (const action of [() => bot.pathfinder?.setGoal(null), () => bot.clearControlStates?.(), () => bot.stopDigging?.(), () => { if (bot.currentWindow) bot.closeWindow(bot.currentWindow) }]) {
    try { Promise.resolve(action()).catch(() => {}) } catch {}
  }
}

export async function loadSessionRuntime() {
  const module = await import('mineflayer')
  const { Movements, pathfinder } = await import('mineflayer-pathfinder')
  const { default: minecraftData } = await import('minecraft-data')
  const mineflayer = module.default ?? module
  return {
    createBot: (options) => mineflayer.createBot(options),
    protocolForVersion: (version) => minecraftData(version).protocol,
    installPathfinder: (bot) => bot.loadPlugin(pathfinder),
    configureMovements(bot) {
      const movements = new Movements(bot)
      movements.canDig = false
      movements.allow1by1towers = false
      movements.scafoldingBlocks = []
      movements.allowParkour = false
      movements.maxDropDown = 1
      movements.infiniteLiquidDropdownDistance = false
      bot.pathfinder.setMovements(movements)
      bot.pathfinder.tickTimeout = 5
      bot.pathfinder.thinkTimeout = 5000
    }
  }
}

export function createSessionTransport({ runtime, target, timeoutMs = 45000, record = () => {}, cleanupTimeoutMs = 2000, deathPolicy = 'respawn', connectionGate }) {
  const connections = new Map()
  let totalConnections = 0
  let disconnected = 0
  return {
    connections,
    async connect(player, signal) {
      if (connections.has(player.username)) throw sessionError(`Identity ${player.username} already has a live connection`, 'invariant')
      signal?.throwIfAborted()
      const attempt = async () => {
        signal?.throwIfAborted()
        if (connections.has(player.username)) throw sessionError(`Identity ${player.username} already has a live connection`, 'invariant')
        const options = { host: target.host, port: target.port, username: player.username, auth: 'offline', hideErrors: true, logErrors: false, respawn: false }
        if (target.version) options.version = target.version
        record({ type: 'connection-attempt', player: player.id, username: player.username, attemptedAtEpochMs: Date.now() })
        const bot = runtime.createBot(options)
        const abort = new AbortController()
        const owned = { bot, username: player.username, abort, signal: abort.signal, ended: false, closing: false, spawned: false, switching: false, listeners: [] }
        owned.removeProtocolBarrier = installConfigurationBarrier(bot, runtime.protocolForVersion, (event) => record({ ...event, player: player.id }))
        owned.readiness = installArrivalReadiness(bot, (event) => record({ ...event, player: player.id }))
        connections.set(player.username, owned)
        totalConnections += 1
        const on = (name, listener) => { bot.on(name, listener); owned.listeners.push([name, listener]) }
        const fail = (error) => { if (!owned.closing) abort.abort(error) }
        on('error', (error) => fail(sessionError(`${player.username}: ${error.message}`)))
        on('kicked', (reason) => {
          const text = reasonText(reason)
          const limited = /logging in too fast|connection throttle|too many connections|rate.limit/i.test(text)
          fail(sessionError(`${player.username} kicked: ${text}${limited ? '; increase population.arrivalIntervalSeconds to meet the server or proxy login limit' : ''}`, limited ? 'rate-limit' : 'kicked'))
        })
        on('end', (reason) => {
          owned.ended = true
          fail(sessionError(`${player.username} disconnected: ${reasonText(reason)}`))
        })
        on('death', () => {
          record({ type: 'death', player: player.id })
          if (!owned.spawned && !owned.initialRespawn && deathPolicy === 'respawn') { owned.initialRespawn = true; bot.respawn(); return }
          fail(sessionError(`${player.username} died`, 'death'))
        })
        on('respawn', () => {
          if (owned.spawned && !owned.switching) fail(sessionError(`${player.username} changed world outside its planned route`, 'world-change'))
        })
        const externalAbort = () => abort.abort(signal.reason)
        signal?.addEventListener('abort', externalAbort, { once: true })
        owned.detachSignal = () => signal?.removeEventListener('abort', externalAbort)
        if (signal?.aborted) externalAbort()
        let spawned
        const spawn = new Promise((resolve) => { spawned = resolve; bot.once('spawn', spawned) })
        try {
          runtime.installPathfinder?.(bot)
          await bounded(spawn, timeoutMs, `${player.username} spawn`, owned.signal)
          await ready(owned, timeoutMs)
          runtime.configureMovements?.(bot)
          owned.spawned = true
          owned.backend = target.kind === 'instance' ? target.backends[0].alias : await confirmBackend(bot, target, { timeoutMs, signal: owned.signal })
          return owned
        } catch (error) {
          await this.disconnect(owned)
          throw error
        } finally { bot.removeListener('spawn', spawned) }
      }
      return connectionGate ? connectionGate.run(attempt, signal) : attempt()
    },
    async switchBackend(owned, alias) {
      if (!target.backends.some((backend) => backend.alias === alias)) throw sessionError(`Unknown backend ${alias}`, 'configuration')
      if (target.kind !== 'network') throw sessionError('Backend switching requires Velocity', 'configuration')
      owned.signal.throwIfAborted()
      cancelBot(owned.bot)
      owned.switching = true
      let transitionSeen = false
      let arrived
      const arrival = new Promise((resolve) => { arrived = () => { if (transitionSeen) resolve() } })
      const transition = () => { transitionSeen = true }
      const stateChanged = (state) => { if (state === 'configuration') transition() }
      owned.bot.on('spawn', arrived)
      owned.bot.on('forcedMove', arrived)
      owned.bot.on('respawn', transition)
      owned.bot.on('login', transition)
      owned.bot._client?.on('state', stateChanged)
      const previousBackend = owned.backend
      try {
        owned.bot.chat(`/server ${alias}`)
        if (previousBackend !== alias) await bounded(arrival, timeoutMs, `${owned.bot.username} backend arrival`, owned.signal)
        await ready(owned, timeoutMs)
        owned.backend = await confirmBackend(owned.bot, target, { expected: alias, timeoutMs, signal: owned.signal })
        runtime.configureMovements?.(owned.bot)
        return owned.backend
      } catch (error) {
        owned.abort.abort(error)
        throw error
      } finally {
        owned.switching = false
        owned.bot.removeListener('spawn', arrived)
        owned.bot.removeListener('forcedMove', arrived)
        owned.bot.removeListener('respawn', transition)
        owned.bot.removeListener('login', transition)
        owned.bot._client?.removeListener('state', stateChanged)
      }
    },
    async disconnect(owned) {
      if (!owned || owned.disposed) return
      if (owned.disconnecting) return owned.disconnecting
      owned.disconnecting = (async () => {
        owned.closing = true
        owned.abort.abort(sessionError('Session connection closed', 'logout'))
        cancelBot(owned.bot)
        let ended
        const end = new Promise((resolve) => { ended = resolve; owned.bot.once('end', ended) })
        try {
          if (!owned.ended) {
            try { owned.bot.quit('Multiplexor session ended') } catch {}
            try { await bounded(end, cleanupTimeoutMs, 'Session logout') } catch {
              try { owned.bot.end('Multiplexor session cleanup') } catch {}
              try { owned.bot._client?.end?.('Multiplexor session cleanup') } catch {}
              try { owned.bot._client?.socket?.destroy?.() } catch {}
              await bounded(end, cleanupTimeoutMs, 'Session forced logout')
            }
          }
          owned.disposed = true
          disconnected += 1
          connections.delete(owned.username)
        } finally {
          owned.bot.removeListener('end', ended)
          owned.detachSignal?.()
          if (owned.ended) {
            owned.readiness.dispose()
            owned.removeProtocolBarrier?.()
            for (const [event, listener] of owned.listeners) owned.bot.removeListener(event, listener)
          }
        }
      })()
      return owned.disconnecting
    },
    async close() {
      const results = await Promise.allSettled([...connections.values()].map((owned) => this.disconnect(owned)))
      const errors = results.filter((result) => result.status === 'rejected').map((result) => result.reason)
      if (errors.length) throw new AggregateError(errors, 'Some session clients did not disconnect')
      if (connections.size) throw sessionError(`${connections.size} session identities remain registered after disconnect`, 'invariant')
      return { connections: totalConnections, disconnected, remaining: connections.size }
    }
  }
}

async function ready(owned, timeoutMs) {
  const { bot, signal } = owned
  if (bot.waitForChunksToLoad) await bounded(bot.waitForChunksToLoad(), timeoutMs, `${bot.username} chunks`, signal)
  if (!bot.entity?.position || !Number.isFinite(bot.entity.position.x)) throw sessionError(`${bot.username} has no usable world position`, 'world-readiness')
  signal?.throwIfAborted()
  owned.readiness.acknowledge()
}

export function backendFromMessage(message, position = 'system') {
  if (position !== 'system') return undefined
  const json = message?.json ?? message
  if (json?.translate === 'velocity.command.server-current-server' && Array.isArray(json.with) && json.with.length === 1) {
    const value = typeof json.with[0] === 'string' ? json.with[0] : json.with[0]?.text
    if (typeof value === 'string' && /^[A-Za-z0-9_.-]{1,64}$/.test(value)) return value
  }
  const plain = typeof message === 'string' ? message : typeof message?.toString === 'function' ? message.toString() : ''
  return /^You are currently connected to ([A-Za-z0-9_.-]{1,64})\.$/.exec(plain.replaceAll(/§[0-9a-fk-or]/gi, ''))?.[1]
}

export async function confirmBackend(bot, target, { expected, timeoutMs = 45000, signal, now = Date.now } = {}) {
  const started = now()
  const deadline = started + timeoutMs
  let observed
  let nextQuery = -Infinity
  const message = (value, position) => { const alias = backendFromMessage(value, position); if (alias) observed = alias }
  bot.on('message', message)
  try {
    while (now() < deadline) {
      signal?.throwIfAborted()
      const observer = await backendFromObserver(target.observerPath, bot.username, started, now())
      if (observer) observed = observer
      if (observed && (!expected || observed === expected)) {
        if (!target.backends.some((backend) => backend.alias === observed)) throw sessionError(`Velocity reported unmanaged backend ${observed}`, 'route')
        return observed
      }
      if (now() >= nextQuery && (!bot._client || bot._client.state === 'play')) { bot.chat('/server'); nextQuery = now() + 2000 }
      await delay(Math.min(200, Math.max(1, deadline - now())), signal)
    }
    throw sessionError(expected ? `Velocity destination ${expected} was not confirmed${observed ? ` (observed ${observed})` : ''}` : 'Velocity did not provide a verifiable backend through its observer or /server response', 'route')
  } finally { bot.removeListener('message', message) }
}

async function backendFromObserver(file, username, since, now) {
  if (!file) return undefined
  try {
    const source = await readFile(file, 'utf8')
    if (source.length > 4 * 1024 * 1024) return undefined
    const snapshot = JSON.parse(source)
    const observedAt = Date.parse(snapshot.observedAt)
    if (snapshot.schemaVersion !== 1 || snapshot.kind !== 'velocity' || snapshot.status !== 'running' || !Number.isFinite(observedAt) || observedAt < since || observedAt > now + 1000 || now - observedAt > 15000) return undefined
    const player = snapshot.players?.find((entry) => entry.username === username)
    return typeof player?.backend === 'string' ? player.backend : undefined
  } catch { return undefined }
}
