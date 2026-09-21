import { createHash } from 'node:crypto'
import { readFile } from 'node:fs/promises'
import path from 'node:path'
import { withTimeout } from './scenario_context.mjs'

export function offlineUuid(username) {
  const hash = createHash('md5').update(`OfflinePlayer:${username}`).digest()
  hash[6] = (hash[6] & 0x0f) | 0x30
  hash[8] = (hash[8] & 0x3f) | 0x80
  const hex = hash.toString('hex')
  return `${hex.slice(0, 8)}-${hex.slice(8, 12)}-${hex.slice(12, 16)}-${hex.slice(16, 20)}-${hex.slice(20)}`
}

export async function assertOrdinaryActor(directory, username) {
  const entries = JSON.parse(await readFile(path.join(directory, 'ops.json'), 'utf8'))
  if (!Array.isArray(entries)) throw new Error('Invalid instance operator list')
  const uuid = offlineUuid(username)
  if (entries.some((entry) => entry.name?.toLowerCase() === username.toLowerCase() || entry.uuid?.toLowerCase() === uuid)) throw new Error(`Additional actor ${username} already has operator access`)
}

export function createActorManager({ configuration, runtime, report, signal, fail }) {
  const actors = new Map()
  let closing = false
  const manager = {
    async connect(username, { primary = false } = {}) {
      signal.throwIfAborted()
      if (closing) throw new Error('Actor manager is closing')
      if (typeof username !== 'string' || !username || ((!primary || configuration.auth === 'offline') && !/^[A-Za-z0-9_]{1,16}$/.test(username))) throw new Error('Offline actor username must be 1–16 letters, digits or underscores')
      if (actors.size >= 32 || actors.has(username.toLowerCase())) throw new Error('Actor is already connected or the 32-actor limit was reached')
      const key = username.toLowerCase()
      const owned = { bot: undefined, username, primary, ended: false, closing: false, reconnecting: false, listeners: [] }
      actors.set(key, owned)
      try {
        if (!primary) {
          if (configuration.auth !== 'offline' || configuration.host !== '127.0.0.1' || !configuration.instanceDirectory) throw new Error('Additional actors require a managed offline loopback instance')
          await assertOrdinaryActor(configuration.instanceDirectory, username)
        }
        signal.throwIfAborted()
        const options = { host: configuration.host, port: configuration.port, username, auth: configuration.auth, hideErrors: true, logErrors: false }
        if (configuration.version !== undefined) options.version = configuration.version
        if (primary && configuration.profilesFolder !== undefined) options.profilesFolder = configuration.profilesFolder
        const bot = runtime.createBot(options)
        owned.bot = bot
        const on = (event, listener) => { bot.on(event, listener); owned.listeners.push([event, listener]) }
        const fatal = (error) => { if (!closing && !owned.closing) fail(error instanceof Error ? error : new Error(`${username}: ${String(error)}`)) }
        on('messagestr', (message) => {
          report.messages.push({ at: new Date().toISOString(), actor: username, message: String(message).slice(0, 4096) })
          if (report.messages.length > 10_000) report.messages.shift()
        })
        on('kicked', (reason) => fatal(new Error(`${username} kicked: ${JSON.stringify(reason)}`)))
        on('error', fatal)
        on('end', (reason) => {
          owned.ended = true
          if (owned.evidence) Object.assign(owned.evidence, { disconnectedAt: new Date().toISOString(), disconnectReason: String(reason), planned: owned.reconnecting || owned.closing || closing })
          if (!owned.reconnecting) fatal(new Error(`${username} disconnected: ${String(reason)}`))
        })
        runtime.install(bot)
        let spawned
        const spawn = new Promise((resolve) => { spawned = resolve; bot.once('spawn', spawned) })
        try { await withTimeout(spawn, configuration.connectTimeoutMs, `${username} spawn`, signal) }
        finally { bot.removeListener('spawn', spawned) }
        signal.throwIfAborted()
        runtime.configure(bot)
        report.actors ??= []
        owned.evidence = { username: bot.username, uuid: bot.player?.uuid, version: bot.version, primary }
        report.actors.push(owned.evidence)
        return bot
      } catch (error) {
        if (!owned.bot) actors.delete(key)
        throw error
      }
    },
    async reconnectAfter(bot, trigger, { timeoutMs = 30000 } = {}) {
      signal.throwIfAborted()
      if (typeof trigger !== 'function' || !Number.isFinite(timeoutMs) || timeoutMs <= 0 || timeoutMs > 120000) throw new Error('Reconnect requires a trigger and a 1–120000 ms deadline')
      const entry = [...actors.entries()].find(([, candidate]) => candidate.bot === bot)
      const [key, owned] = entry ?? []
      if (closing || !owned || owned.bot !== bot || owned.ended || owned.reconnecting) throw new Error('Actor is not available for a planned reconnect')
      owned.reconnecting = true
      let ended
      const disconnected = new Promise((resolve) => { ended = resolve; bot.once('end', ended) })
      try {
        bot.pathfinder?.setGoal(null)
        bot.clearControlStates?.()
        await withTimeout(Promise.all([Promise.resolve().then(trigger), disconnected]), timeoutMs, `${bot.username} planned disconnect`, signal)
        signal.throwIfAborted()
      } finally {
        owned.reconnecting = false
        bot.removeListener('end', ended)
        if (owned.ended) {
          for (const [event, listener] of owned.listeners) bot.removeListener(event, listener)
          actors.delete(key)
        }
      }
      return manager.connect(owned.username, { primary: owned.primary })
    },
    async close() {
      closing = true
      const results = await Promise.allSettled([...actors.values()].map(async (owned) => {
        const bot = owned.bot
        if (!bot) return
        owned.closing = true
        let ended
        const pending = new Promise((resolve) => { ended = resolve; bot.once('end', ended) })
        try {
          bot.pathfinder?.setGoal(null)
          bot.clearControlStates?.()
          if (!owned.ended) {
            bot.quit('Multiplexor gameplay complete')
            try { await withTimeout(pending, 2000, `${bot.username} disconnect`) }
            catch {
              bot.end('Multiplexor gameplay cleanup')
              await withTimeout(pending, 1000, `${bot.username} forced disconnect`)
            }
          }
        } finally {
          bot.removeListener('end', ended)
          for (const [event, listener] of owned.listeners) bot.removeListener(event, listener)
        }
      }))
      const errors = results.filter((result) => result.status === 'rejected').map((result) => result.reason)
      if (errors.length) throw new AggregateError(errors, errors.map((error) => error.message).join('; '))
    }
  }
  return manager
}
