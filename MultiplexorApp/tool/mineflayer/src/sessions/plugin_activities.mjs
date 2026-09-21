import { createScenarioContext } from '../scenario_context.mjs'
import { circleRoute } from '../scenario_actions.mjs'

function fields(value, keys, label) {
  if (!value || typeof value !== 'object' || Array.isArray(value) || Object.keys(value).some((key) => !keys.includes(key))) throw new Error(`Invalid ${label} fields`)
}

function text(value, label, maximum = 256) {
  if (typeof value !== 'string' || !value.trim() || value.length > maximum || /[\x00-\x1f\x7f]/.test(value)) throw new Error(`Invalid ${label}`)
  return value
}

export function validatePluginActivities(raw = [], { aliases, roles } = {}) {
  if (!Array.isArray(raw) || raw.length > 32) throw new Error('pluginActivities must contain at most 32 activities')
  const ids = new Set()
  return raw.map((value) => {
    fields(value, ['id', 'backend', 'roles', 'everySeconds', 'command', 'expect', 'menu', 'timeoutSeconds', 'steps'], 'plugin activity')
    if (typeof value.id !== 'string' || !/^[A-Za-z][A-Za-z0-9_-]{0,47}$/.test(value.id) || ids.has(value.id)) throw new Error('Plugin activity IDs must be unique identifiers')
    ids.add(value.id)
    if (typeof value.backend !== 'string' || !/^[A-Za-z0-9_.-]{1,64}$/.test(value.backend) || (aliases && !aliases.includes(value.backend))) throw new Error(`Unknown plugin activity backend: ${value.backend}`)
    const selectedRoles = value.roles ?? []
    if (!Array.isArray(selectedRoles) || selectedRoles.length > 32 || new Set(selectedRoles).size !== selectedRoles.length || selectedRoles.some((role) => typeof role !== 'string' || (roles && !roles.includes(role)))) throw new Error('Invalid plugin activity roles')
    const everySeconds = value.everySeconds ?? [60, 120]
    if (!Array.isArray(everySeconds) || everySeconds.length !== 2 || everySeconds.some((n) => !Number.isFinite(n) || n < 1 || n > 604800) || everySeconds[0] > everySeconds[1]) throw new Error('Invalid plugin activity everySeconds range')
    const timeoutSeconds = value.timeoutSeconds ?? 15
    if (!Number.isFinite(timeoutSeconds) || timeoutSeconds < 1 || timeoutSeconds > 120) throw new Error('Invalid plugin activity timeoutSeconds')
    const base = { id: value.id, backend: value.backend, roles: [...selectedRoles], everySeconds: [...everySeconds], timeoutSeconds }
    if (value.steps !== undefined) {
      if (value.command !== undefined || value.expect !== undefined || value.menu !== undefined) throw new Error('Use steps or a single command, not both')
      if (!Array.isArray(value.steps) || value.steps.length < 1 || value.steps.length > 32) throw new Error('Plugin workflow requires 1–32 steps')
      return { ...base, steps: value.steps.map(validateStep) }
    }
    return { ...base, ...validateCommand(value) }
  })
}

function validateCommand(value) {
    const command = text(value.command, 'plugin command', 200)
    if (!command.startsWith('/')) throw new Error('Plugin activities require an explicit slash command')
    const expect = value.expect === undefined ? undefined : text(value.expect, 'plugin expected response', 160)
    let menu
    if (value.menu !== undefined) {
      fields(value.menu, ['title', 'clicks', 'expect'], 'plugin menu')
      const title = text(value.menu.title, 'menu title', 120)
      if (!Array.isArray(value.menu.clicks) || value.menu.clicks.length > 16) throw new Error('Menu clicks must contain at most 16 steps')
      const clicks = value.menu.clicks.map((click) => {
        fields(click, ['slot', 'item', 'nextTitle'], 'menu click')
        if (!Number.isSafeInteger(click.slot) || click.slot < 0 || click.slot > 255 || typeof click.item !== 'string' || !/^[a-z0-9_]{1,64}$/.test(click.item)) throw new Error('Menu click requires a slot and expected item name')
        return { slot: click.slot, item: click.item, ...(click.nextTitle === undefined ? {} : { nextTitle: text(click.nextTitle, 'next menu title', 120) }) }
      })
      const reply = value.menu.expect === undefined ? undefined : text(value.menu.expect, 'menu expected response', 160)
      if (clicks.length && !reply && !expect) throw new Error('Menu mutations require an expected response')
      menu = { title, clicks, ...(reply ? { expect: reply } : {}) }
    }
    if (!menu && !expect) throw new Error('Command activities require an expected response')
    return { command, ...(expect ? { expect } : {}), ...(menu ? { menu } : {}) }
}

function point(value) {
  fields(value, ['x', 'y', 'z'], 'waypoint')
  if (!['x', 'y', 'z'].every((axis) => Number.isFinite(value[axis]) && Math.abs(value[axis]) <= 30000000)) throw new Error('Waypoint requires bounded coordinates')
  return { ...value }
}

function validateStep(value) {
  fields(value, ['command', 'expect', 'menu', 'circle', 'route', 'transition'], 'workflow step')
  const kinds = ['command', 'circle', 'route'].filter((key) => value[key] !== undefined)
  if (kinds.length !== 1) throw new Error('Each workflow step requires exactly one command, circle, or route')
  let result
  if (value.command !== undefined) result = validateCommand(value)
  else {
    if (value.expect !== undefined || value.menu !== undefined) throw new Error('Only command steps accept replies and menus')
    if (value.circle) {
      fields(value.circle, ['center', 'radius', 'laps', 'clockwise'], 'circle')
      const circle = { ...value.circle, center: point(value.circle.center) }
      circleRoute(circle)
      result = { circle }
    } else {
      if (!Array.isArray(value.route) || value.route.length < 1 || value.route.length > 256) throw new Error('Workflow route requires 1–256 waypoints')
      result = { route: value.route.map(point) }
    }
  }
  if (value.transition !== undefined) {
    fields(value.transition, ['worldName', 'worldId', 'position', 'radius'], 'transition')
    const { worldName, worldId, radius = 2 } = value.transition
    if (worldName === undefined && worldId === undefined) throw new Error('Transition requires a destination world name or UUID')
    if (worldName !== undefined) text(worldName, 'world name', 128)
    if (worldId !== undefined && !/^[0-9a-f]{8}-(?:[0-9a-f]{4}-){3}[0-9a-f]{12}$/i.test(worldId)) throw new Error('Invalid world UUID')
    if (!Number.isFinite(radius) || radius <= 0 || radius > 128) throw new Error('Invalid arrival radius')
    result.transition = { ...value.transition, radius, ...(value.transition.position ? { position: point(value.transition.position) } : {}) }
  }
  return result
}

export function duePluginActivity(activities, player, backend, elapsedMs, random) {
  player.intent.plugins ??= {}
  for (const activity of activities) {
    if (activity.backend !== backend || (activity.roles.length && !activity.roles.includes(player.role))) continue
    const delay = () => (activity.everySeconds[0] + random() * (activity.everySeconds[1] - activity.everySeconds[0])) * 1000
    const state = player.intent.plugins[activity.id] ??= { nextDueAtMs: elapsedMs + delay() }
    if (state.nextDueAtMs > elapsedMs) continue
    state.nextDueAtMs = elapsedMs + delay()
    return activity
  }
  return undefined
}

function renderedText(value) {
  if (typeof value === 'string') {
    try { return renderedText(JSON.parse(value)) } catch { return value }
  }
  if (Array.isArray(value)) return value.map(renderedText).join('')
  if (value && typeof value === 'object') {
    if (typeof value.type === 'string' && Object.hasOwn(value, 'value')) return renderedText(value.value)
    return `${renderedText(value.text ?? '')}${renderedText(value.extra ?? [])}`
  }
  return String(value ?? '')
}

async function executeCommand(bot, activity, { signal, assertCurrent, record = () => {} }) {
  signal.throwIfAborted()
  assertCurrent()
  const cancellation = new AbortController()
  const actionSignal = AbortSignal.any([signal, cancellation.signal])
  const timer = setTimeout(() => cancellation.abort(new Error(`Plugin activity ${activity.id} timed out`)), activity.timeoutSeconds * 1000)
  const listeners = []
  let ownedWindow
  const expand = (value) => value.replaceAll('{player}', bot.username).replaceAll('{id}', activity.id)
  function wait(event, predicate) {
    return new Promise((resolve, reject) => {
      const clean = () => { bot.removeListener(event, received); actionSignal.removeEventListener('abort', abort) }
      const received = (...args) => { if (predicate(...args)) { clean(); resolve(args[0]) } }
      const abort = () => { clean(); reject(actionSignal.reason) }
      if (actionSignal.aborted) return abort()
      bot.on(event, received)
      actionSignal.addEventListener('abort', abort, { once: true })
      listeners.push(clean)
    })
  }
  const match = activity.menu?.expect ?? activity.expect
  const response = match ? wait('messagestr', (message) => String(message).slice(0, 4096).toLowerCase().includes(expand(match).toLowerCase())) : undefined
  response?.catch(() => {})
  const opened = activity.menu ? wait('windowOpen', () => true) : undefined
  opened?.catch(() => {})
  const close = () => { if (ownedWindow && bot.currentWindow === ownedWindow) bot.closeWindow(ownedWindow) }
  actionSignal.addEventListener('abort', close, { once: true })
  try {
    const aborted = new Promise((_, reject) => {
      const listener = () => reject(actionSignal.reason)
      actionSignal.addEventListener('abort', listener, { once: true })
      listeners.push(() => actionSignal.removeEventListener('abort', listener))
    })
    await Promise.race([(async () => {
      bot.chat(expand(activity.command))
      if (opened) {
        ownedWindow = await opened
        if (!renderedText(ownedWindow.title).toLowerCase().includes(expand(activity.menu.title).toLowerCase())) throw new Error('Plugin opened an unexpected menu')
        for (const click of activity.menu.clicks) {
          actionSignal.throwIfAborted(); assertCurrent()
          if (bot.currentWindow !== ownedWindow) throw new Error('Plugin menu changed before the next click')
          if (!Number.isSafeInteger(ownedWindow.inventoryStart) || click.slot >= ownedWindow.inventoryStart || ownedWindow.slots[click.slot]?.name !== click.item) throw new Error(`Plugin menu slot ${click.slot} does not contain ${click.item}`)
          const next = click.nextTitle ? wait('windowOpen', (window) => { ownedWindow = window; return true }) : undefined
          next?.catch(() => {})
          await bot.clickWindow(click.slot, 0, 0)
          actionSignal.throwIfAborted(); assertCurrent()
          if (next) {
            ownedWindow = await next
            if (!renderedText(ownedWindow.title).toLowerCase().includes(expand(click.nextTitle).toLowerCase())) throw new Error('Plugin opened an unexpected next menu')
          }
        }
      }
      if (response) await response
      actionSignal.throwIfAborted(); assertCurrent()
    })(), aborted])
    record({ type: 'plugin-activity', id: activity.id, player: bot.username, status: 'completed' })
    return { status: 'completed', kind: `plugin:${activity.id}`, metrics: { pluginActions: 1 } }
  } finally {
    clearTimeout(timer)
    cancellation.abort(new Error('Plugin activity finished'))
    actionSignal.removeEventListener('abort', close)
    close()
    for (const clean of listeners) clean()
  }
}

export async function executePluginActivity(bot, activity, context) {
  if (!activity.steps) return executeCommand(bot, activity, context)
  const { signal, assertCurrent, record = () => {}, observerPath, worldTransition } = context
  const abort = new AbortController()
  const current = AbortSignal.any([signal, abort.signal])
  const timer = setTimeout(() => abort.abort(new Error(`Plugin activity ${activity.id} timed out`)), activity.timeoutSeconds * 1000)
  const report = { server: { observerPath }, steps: [] }
  const scenario = createScenarioContext({ bot, report, signal: current })
  const transitions = activity.steps.some((step) => step.transition)
  try {
    const initial = transitions ? await scenario.observe() : undefined
    const home = initial?.players.find((player) => player.username === bot.username)?.world
    if (transitions && (!home || !worldTransition)) throw new Error('Workflow transitions require an observed player and managed transport')
    for (const [index, step] of activity.steps.entries()) {
      current.throwIfAborted(); assertCurrent()
      const run = async (movement = scenario) => {
        if (step.command) return executeCommand(bot, { ...step, id: activity.id, timeoutSeconds: activity.timeoutSeconds }, { ...context, signal: current, record: () => {} })
        if (step.circle) return movement.actions.walkCircle({ ...step.circle, timeoutMs: activity.timeoutSeconds * 1000 })
        return movement.actions.walkRoute(step.route, { timeoutMs: activity.timeoutSeconds * 1000 })
      }
      let result
      if (!step.transition) result = await run()
      else result = await worldTransition(async () => {
        const destination = { ...step.transition, timeoutMs: activity.timeoutSeconds * 1000 }
        if (step.command) return scenario.transition(run, destination)
        const motionAbort = new AbortController()
        const motionContext = createScenarioContext({ bot, report, signal: AbortSignal.any([current, motionAbort.signal]) })
        let motion
        let failed
        const failure = new Promise((_, reject) => { failed = reject })
        try {
          const arrival = scenario.transition(() => {
            motion = run(motionContext)
            motion.catch(failed)
          }, destination)
          return await Promise.race([arrival, failure])
        } finally {
          motionAbort.abort(new Error('Declared destination reached or transition ended'))
          await motion?.catch(() => {})
        }
      })
      record({ type: 'plugin-step', id: activity.id, player: bot.username, step: index + 1, result })
    }
    if (transitions) {
      const snapshot = await scenario.observe()
      if (snapshot.players.find((player) => player.username === bot.username)?.world !== home) throw new Error('Persistent workflow must return to its starting world')
    }
    current.throwIfAborted(); assertCurrent()
    return { status: 'completed', kind: `plugin:${activity.id}`, metrics: { pluginActions: 1, pluginSteps: activity.steps.length } }
  } catch (error) {
    if (transitions) context.failTransition?.(error)
    throw error
  } finally {
    clearTimeout(timer)
    abort.abort(new Error('Plugin workflow finished'))
    bot.pathfinder?.setGoal(null)
    bot.clearControlStates?.()
  }
}
