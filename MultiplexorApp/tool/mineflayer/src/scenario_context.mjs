import { readFile } from 'node:fs/promises'
import path from 'node:path'
import { createScenarioActions } from './scenario_actions.mjs'

export class ScenarioAssertionError extends Error {
  constructor(message, details) {
    super(message)
    this.name = 'ScenarioAssertionError'
    this.details = details
  }
}

export function createScenarioContext({ bot, report, options = {}, output = () => {}, signal = new AbortController().signal, connectActor, reconnectAfter }) {
  const expect = (condition, message, details = undefined) => {
    if (!condition) {
      throw new ScenarioAssertionError(message, details)
    }
  }

  const step = async (name, action) => {
    signal.throwIfAborted()
    const entry = {
      name,
      status: 'running',
      startedAt: new Date().toISOString()
    }
    report.steps.push(entry)
    output(`[STEP] ${name}`)
    const started = performance.now()
    try {
      const value = await action()
      signal.throwIfAborted()
      entry.status = 'passed'
      entry.durationMs = Math.round(performance.now() - started)
      return value
    } catch (error) {
      entry.status = 'failed'
      entry.durationMs = Math.round(performance.now() - started)
      entry.error = errorMessage(error)
      throw error
    }
  }

  const waitForEvent = (event, predicate = () => true, timeoutMs = 5000) => {
    signal.throwIfAborted()
    const pending = new Promise((resolve, reject) => {
      let timer
      const listener = (...args) => {
        let matches = false
        try {
          matches = predicate(...args)
        } catch (error) {
          cleanup()
          reject(error)
          return
        }
        if (!matches) {
          return
        }
        cleanup()
        resolve(args)
      }
      const cleanup = () => {
        clearTimeout(timer)
        bot.removeListener(event, listener)
        signal.removeEventListener('abort', cancelled)
      }
      const cancelled = () => { cleanup(); reject(signal.reason) }
      timer = setTimeout(() => {
        cleanup()
        reject(new Error(`Timed out waiting for ${event} after ${timeoutMs}ms`))
      }, timeoutMs)
      bot.on(event, listener)
      signal.addEventListener('abort', cancelled, { once: true })
    })
    pending.catch(() => {})
    return pending
  }

  const waitForMessage = (pattern, timeoutMs = 5000) => {
    const matcher = pattern instanceof RegExp
      ? (message) => { pattern.lastIndex = 0; return pattern.test(message) }
      : (message) => message.includes(String(pattern))
    return waitForEvent('messagestr', matcher, timeoutMs).then(([message]) => message)
  }

  const command = async (text, expected, timeoutMs = 5000) => {
    signal.throwIfAborted()
    const response = expected === undefined
      ? undefined
      : waitForMessage(expected, timeoutMs)
    bot.chat(text)
    return response === undefined ? undefined : response
  }

  const sleep = (milliseconds, current = signal) => {
    current.throwIfAborted()
    return new Promise((resolve, reject) => {
      const cancel = () => { clearTimeout(timer); reject(current.reason) }
      const timer = setTimeout(() => { current.removeEventListener('abort', cancel); resolve() }, milliseconds)
      current.addEventListener('abort', cancel, { once: true })
    })
  }
  const waitUntil = async (predicate, { timeoutMs = 10_000, label = 'condition', intervalMs = 50, signal: current = signal } = {}) => {
    if (!Number.isFinite(timeoutMs) || timeoutMs <= 0 || !Number.isFinite(intervalMs) || intervalMs <= 0) throw new Error('Wait requires positive timeout and interval')
    const deadline = performance.now() + timeoutMs
    while (true) {
      current.throwIfAborted()
      const remaining = deadline - performance.now()
      if (remaining <= 0) throw new Error(`Timed out waiting for ${label} after ${timeoutMs}ms`)
      const value = await withTimeout(Promise.resolve().then(predicate), remaining, label, current)
      current.throwIfAborted()
      if (value) return value
      await sleep(Math.min(intervalMs, Math.max(1, deadline - performance.now())), current)
    }
  }
  const observe = async () => {
    signal.throwIfAborted()
    expect(report.server.directory || report.server.observerPath, 'Server observation requires a managed instance directory or observer path')
    const filename = report.server.observerPath ?? path.join(report.server.directory, 'plugins', 'MultiplexorObserver', 'metrics.json')
    const snapshot = JSON.parse(await readFile(filename, 'utf8'))
    const age = Date.now() - Date.parse(snapshot.observedAt)
    expect(snapshot.schemaVersion === 1 && snapshot.kind === 'paper' && snapshot.status === 'running' && Number.isFinite(age) && age >= -1000 && age <= 15_000 && Array.isArray(snapshot.worlds) && Array.isArray(snapshot.players), 'Server observer is unavailable, invalid, or stale')
    return snapshot
  }
  const transition = async (trigger, { worldName, worldId, timeoutMs = 30_000, position, radius = 2 } = {}) => {
    expect(typeof worldName === 'string' || typeof worldId === 'string', 'Transition requires a destination world name or UUID')
    const before = await observe()
    const startedAt = Date.now()
    await withTimeout(Promise.resolve().then(trigger), timeoutMs, 'World transition trigger', signal)
    const remaining = timeoutMs - (Date.now() - startedAt)
    expect(remaining > 0, 'World transition trigger exceeded its deadline')
    return waitUntil(async () => {
      const snapshot = await observe()
      if (snapshot.processId !== before.processId) throw new Error('Server restarted during a world transition')
      if (Date.parse(snapshot.observedAt) <= startedAt) return false
      const player = snapshot.players.find((entry) => entry.username === bot.username)
      if (player?.observedAt !== undefined && (!Number.isFinite(Date.parse(player.observedAt)) || Date.parse(player.observedAt) <= startedAt)) return false
      const world = snapshot.worlds.find((entry) => entry.id === player?.world)
      if (!world || (worldName && world.name !== worldName) || (worldId && world.id !== worldId)) return false
      if (!bot.entity?.position || !bot.blockAt(bot.entity.position.floored())) return false
      if (position && Math.hypot(bot.entity.position.x - position.x, bot.entity.position.y - position.y, bot.entity.position.z - position.z) > radius) return false
      report.observations ??= []
      const result = { actor: bot.username, world, position: { ...bot.entity.position }, observedAt: snapshot.observedAt }
      report.observations.push(result)
      return result
    }, { timeoutMs: remaining, label: `arrival in ${worldName ?? worldId}` })
  }
  const context = {
    bot,
    command,
    expect,
    options,
    report,
    server: report.server,
    signal,
    sleep,
    step,
    observe,
    transition,
    waitUntil,
    waitForEvent,
    waitForMessage
  }
  context.actions = createScenarioActions({ bot, signal, waitUntil, record: (event) => { report.actions ??= []; report.actions.push({ actor: bot.username, ...event }) } })
  context.connectActor = async (name) => {
    expect(connectActor, 'Additional actors require a managed offline instance')
    return connectActor(name)
  }
  context.reconnectAfter = async (trigger, settings) => {
    expect(reconnectAfter, 'Planned reconnect requires a managed scenario actor')
    return reconnectAfter(trigger, settings)
  }
  return context
}

export function withTimeout(promise, timeoutMs, label, signal) {
  return new Promise((resolve, reject) => {
    const cancel = () => { clearTimeout(timer); signal?.removeEventListener('abort', cancel); reject(signal.reason) }
    const timer = setTimeout(
      () => { signal?.removeEventListener('abort', cancel); reject(new Error(`${label} timed out after ${timeoutMs}ms`)) },
      timeoutMs
    )
    signal?.addEventListener('abort', cancel, { once: true })
    if (signal?.aborted) cancel()
    promise.then(
      (value) => {
        clearTimeout(timer)
        signal?.removeEventListener('abort', cancel)
        resolve(value)
      },
      (error) => {
        clearTimeout(timer)
        signal?.removeEventListener('abort', cancel)
        reject(error)
      }
    )
  })
}

export function errorMessage(error) {
  if (error instanceof Error) {
    return error.message
  }
  return String(error)
}
