import { readFile, stat } from 'node:fs/promises'

export const STRESS_ACTIVITIES = Object.freeze(['patrol', 'explore', 'mine', 'build', 'redstone', 'farm', 'craft', 'storage', 'chat', 'idle'])
const TARGET_ACTIVITIES = ['mine', 'build', 'redstone', 'farm', 'storage']
const MAX_DURATION_MS = 7 * 24 * 60 * 60 * 1000

function object(value, label, keys) {
  if (!value || typeof value !== 'object' || Array.isArray(value)) throw new Error(`${label} must be an object`)
  for (const key of Object.keys(value)) if (!keys.includes(key)) throw new Error(`Unknown ${label} field: ${key}`)
  return value
}

function integer(value, label, min, max) {
  if (!Number.isSafeInteger(value) || value < min || value > max) throw new Error(`${label} must be an integer between ${min} and ${max}`)
  return value
}

function position(value, label) {
  if (!Array.isArray(value) || value.length !== 3) throw new Error(`${label} requires [x,y,z]`)
  return value.map((coordinate, index) => integer(coordinate, `${label}[${index}]`, index === 1 ? -48 : -29999000, index === 1 ? 256 : 29999000))
}

export function normalizeBounds(value, label = 'bounds') {
  if (typeof value === 'string') {
    if (!/^-?\d+,-?\d+,-?\d+:-?\d+,-?\d+,-?\d+$/.test(value)) throw new Error(`${label} requires x1,y1,z1:x2,y2,z2`)
    const [min, max] = value.split(':').map((part) => part.split(',').map(Number))
    value = { min, max }
  }
  object(value, label, ['min', 'max'])
  const min = position(value.min, `${label}.min`)
  const max = position(value.max, `${label}.max`)
  if (min.some((coordinate, index) => coordinate > max[index])) throw new Error(`${label}.min must not exceed bounds.max on any axis`)
  if (max[1] - min[1] < 1) throw new Error(`${label} must contain at least two blocks of height`)
  return { min, max }
}

// Bounds include whole block cells, including a player's fractional X/Z position.
export function containsPosition(bounds, value) {
  if (!bounds || !value) return false
  const coordinates = Array.isArray(value) ? value : [value.x, value.y, value.z]
  return coordinates.length === 3 && coordinates.every((coordinate, index) => Number.isFinite(coordinate) &&
    Math.floor(coordinate) >= bounds.min[index] && Math.floor(coordinate) <= bounds.max[index])
}

function derivedBounds({ bots, buildArena, origin = { x: 0, y: 80, z: 0 }, radius = 16 }) {
  const [x, y, z] = position(Array.isArray(origin) ? origin : [origin.x, origin.y, origin.z], 'origin')
  if (buildArena) {
    const columns = Math.ceil(Math.sqrt(bots))
    const rows = Math.ceil(bots / columns)
    return { min: [x, y, z], max: [x + columns * 12 - 1, y + 5, z + rows * 12 - 1] }
  }
  integer(radius, 'radius', 4, 4096)
  return { min: [x - radius, -48, z - radius], max: [x + radius, 256, z + radius] }
}

export function assignRoles(roles, count) {
  const counts = roles.map(() => count >= roles.length ? 1 : 0)
  const remaining = count - counts.reduce((sum, value) => sum + value, 0)
  const totalWeight = roles.reduce((sum, role) => sum + role.weight, 0)
  const quotas = roles.map((role) => remaining * role.weight / totalWeight)
  for (let index = 0; index < roles.length; index++) counts[index] += Math.floor(quotas[index])
  const remainders = roles.map((role, index) => ({ index, fraction: quotas[index] - Math.floor(quotas[index]) }))
    .sort((left, right) => right.fraction - left.fraction || left.index - right.index)
  let extra = count - counts.reduce((sum, value) => sum + value, 0)
  for (const { index } of remainders) if (extra-- > 0) counts[index]++
  const assigned = []
  while (assigned.length < count) for (let index = 0; index < roles.length; index++) {
    if (counts[index] > 0) { assigned.push(roles[index]); counts[index]-- }
  }
  return assigned
}

export function defaultWorkload(options = {}) {
  const activities = options.buildArena
    ? { patrol: 4, explore: 2, mine: 3, build: 3, redstone: 3, farm: 2, craft: 1, storage: 2, chat: 1, idle: 1 }
    : { patrol: 6, explore: 3, chat: 1, idle: 1 }
  return validateWorkload({ schemaVersion: 1, name: options.buildArena ? 'Arena endurance' : 'Outdoor endurance', roles: [{ name: 'player', weight: 1, activities }] }, options)
}

export async function loadWorkload(filePath, options = {}) {
  if ((await stat(filePath)).size > 262144) throw new Error('Workload JSON must not exceed 256 KiB')
  const source = await readFile(filePath, 'utf8')
  if (Buffer.byteLength(source) > 262144) throw new Error('Workload JSON must not exceed 256 KiB')
  let raw
  try { raw = JSON.parse(source) } catch (error) { throw new Error(`Invalid workload JSON: ${error.message}`) }
  return validateWorkload(raw, options)
}

export function validateWorkload(raw, options = {}) {
  const { bots = 4, durationMs = 60000, buildArena = false } = options
  integer(bots, 'bots', 1, 256)
  integer(durationMs, 'durationMs', 1000, MAX_DURATION_MS)
  object(raw, 'workload', ['schemaVersion', 'name', 'bounds', 'roles', 'goals', 'completion', 'pacing', 'failurePolicy', 'schedule', 'reportIntervalSeconds', 'stallTimeoutSeconds', 'targets', 'messages'])
  if (raw.schemaVersion !== 1) throw new Error('Workload schemaVersion must be 1')
  if (typeof raw.name !== 'string' || raw.name.trim().length === 0 || raw.name.length > 80 || /[\x00-\x1f\x7f]/.test(raw.name)) throw new Error('Workload name must contain 1..80 printable characters')
  const bounds = normalizeBounds(options.bounds ?? raw.bounds ?? derivedBounds({ ...options, bots, buildArena }))
  if (buildArena) {
    const arenaBounds = derivedBounds({ ...options, bots, buildArena })
    if (!containsPosition(bounds, arenaBounds.min) || !containsPosition(bounds, arenaBounds.max)) throw new Error('Workload bounds must contain the complete arena footprint and height')
  }
  if (!Array.isArray(raw.roles) || raw.roles.length < 1 || raw.roles.length > 32) throw new Error('Workload roles requires 1..32 roles')
  const names = new Set()
  const roles = raw.roles.map((entry, index) => {
    object(entry, `roles[${index}]`, ['name', 'weight', 'activities'])
    if (typeof entry.name !== 'string' || !/^[A-Za-z][A-Za-z0-9_-]{0,31}$/.test(entry.name) || names.has(entry.name)) throw new Error('Role names must be unique identifiers of 1..32 characters')
    names.add(entry.name)
    const weight = integer(entry.weight ?? 1, `roles[${index}].weight`, 1, 10000)
    object(entry.activities, `roles[${index}].activities`, STRESS_ACTIVITIES)
    const activities = Object.fromEntries(Object.entries(entry.activities).map(([name, value]) => [name, integer(value, `activities.${name}`, 0, 10000)]).filter(([, value]) => value > 0))
    if (Object.keys(activities).length === 0) throw new Error(`Role ${entry.name} needs a positive activity weight`)
    return { name: entry.name, weight, activities }
  })
  const enabled = new Set(roles.flatMap((role) => Object.keys(role.activities)))
  if (![...enabled].some((name) => name !== 'idle')) throw new Error('Stress workloads need at least one activity other than idle')
  const goals = object(options.goals ?? raw.goals ?? {}, 'goals', STRESS_ACTIVITIES)
  const normalizedGoals = Object.fromEntries(Object.entries(goals).map(([name, value]) => {
    integer(value, `goals.${name}`, 1, 1000000000)
    if (!enabled.has(name)) throw new Error(`Goal ${name} has no enabled activity in any role`)
    return [name, value]
  }))
  const completion = options.completion ?? raw.completion ?? 'duration'
  if (!['duration', 'goals'].includes(completion)) throw new Error('completion must be duration or goals')
  if (completion === 'goals' && Object.keys(normalizedGoals).length === 0) throw new Error('Goal completion requires at least one goal')
  const pacing = object(raw.pacing ?? {}, 'pacing', ['minMs', 'maxMs'])
  const minMs = integer(pacing.minMs ?? 250, 'pacing.minMs', 0, 60000)
  const maxMs = integer(pacing.maxMs ?? 1750, 'pacing.maxMs', minMs, 60000)
  const failurePolicy = object(raw.failurePolicy ?? {}, 'failurePolicy', ['maxConsecutive', 'maxTotal'])
  const maxConsecutive = integer(failurePolicy.maxConsecutive ?? 5, 'failurePolicy.maxConsecutive', 1, 10000)
  const maxTotal = integer(failurePolicy.maxTotal ?? 100, 'failurePolicy.maxTotal', 1, 1000000)
  const schedule = raw.schedule ?? [{ atSeconds: 0, activeBots: bots }]
  if (!Array.isArray(schedule) || schedule.length < 1 || schedule.length > 256) throw new Error('schedule requires 1..256 stages')
  let previous = -1
  const normalizedSchedule = schedule.map((entry, index) => {
    object(entry, `schedule[${index}]`, ['atSeconds', 'activeBots'])
    const atSeconds = integer(entry.atSeconds, `schedule[${index}].atSeconds`, 0, Math.ceil(durationMs / 1000) - 1)
    if ((index === 0 && atSeconds !== 0) || atSeconds <= previous) throw new Error('schedule must start at zero and increase strictly')
    previous = atSeconds
    return { atSeconds, activeBots: integer(entry.activeBots, `schedule[${index}].activeBots`, 0, bots) }
  })
  if (!normalizedSchedule.some((entry) => entry.activeBots > 0)) throw new Error('schedule must activate at least one worker')
  const maximumActive = Math.max(...normalizedSchedule.map((entry) => entry.activeBots))
  const activeRoles = assignRoles(roles, bots).slice(0, maximumActive)
  for (const goal of Object.keys(normalizedGoals)) {
    if (!activeRoles.some((role) => role.activities[goal] > 0)) throw new Error(`Goal ${goal} has no assigned active worker; add bots, change the schedule, or revise role weights`)
  }
  const targets = object(raw.targets ?? {}, 'targets', TARGET_ACTIVITIES)
  const normalizedTargets = Object.fromEntries(Object.entries(targets).map(([activity, entries]) => {
    if (!Array.isArray(entries) || entries.length < 1 || entries.length > 2048) throw new Error(`targets.${activity} requires 1..2048 positions`)
    const seen = new Set()
    return [activity, entries.map((value, index) => {
      const target = position(value, `targets.${activity}[${index}]`)
      if (!containsPosition(bounds, target)) throw new Error(`targets.${activity}[${index}] lies outside workload bounds`)
      const key = target.join(',')
      if (seen.has(key)) throw new Error(`targets.${activity} contains duplicate positions`)
      seen.add(key)
      return target
    })]
  }))
  if (!buildArena) for (const activity of TARGET_ACTIVITIES) {
    if (enabled.has(activity) && !normalizedTargets[activity]) throw new Error(`${activity} requires explicit targets or --build-arena`)
  }
  const messages = raw.messages ?? ['{bot}: working as {role}.', '{bot}: completed {completed} jobs; next is {activity}.', '{bot}: still here and working.']
  if (!Array.isArray(messages) || messages.length < 1 || messages.length > 128 || messages.some((message) => typeof message !== 'string' || !message.trim() || message.length > 160 || /^[\s]*\//.test(message) || /[\x00-\x1f\x7f]/.test(message) || /\{(?!bot\}|index\}|role\}|activity\}|completed\})[^}]*\}/.test(message))) {
    throw new Error('messages requires 1..128 plain chat messages of 1..160 characters with supported placeholders')
  }
  const maximumRoleLength = Math.max(...roles.map((role) => role.name.length))
  for (const message of messages) {
    const expanded = message.replaceAll('{bot}', 'B'.repeat(16)).replaceAll('{index}', '256')
      .replaceAll('{role}', 'R'.repeat(maximumRoleLength)).replaceAll('{activity}', 'redstone')
      .replaceAll('{completed}', '9'.repeat(16))
    if (expanded.length > 256) throw new Error('Expanded workload chat messages must fit within 256 characters')
  }
  return {
    schemaVersion: 1, name: raw.name.trim(), bounds, roles, goals: normalizedGoals, completion,
    pacing: { minMs, maxMs }, failurePolicy: { maxConsecutive, maxTotal }, schedule: normalizedSchedule,
    reportIntervalSeconds: integer(raw.reportIntervalSeconds ?? 10, 'reportIntervalSeconds', 1, 3600),
    stallTimeoutSeconds: integer(raw.stallTimeoutSeconds ?? 120, 'stallTimeoutSeconds', 5, 3600),
    targets: normalizedTargets, messages: [...messages]
  }
}
