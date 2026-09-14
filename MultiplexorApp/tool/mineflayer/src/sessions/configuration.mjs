import { createHash } from 'node:crypto'
import { readFile } from 'node:fs/promises'
import path from 'node:path'
import { defaultSettlementWorld, validateWorld } from './world.mjs'
import { validatePluginActivities } from './plugin_activities.mjs'
import { shelterBlueprint } from './projects.mjs'

export const SESSION_ROLES = ['miner', 'lumberjack', 'builder', 'farmer', 'crafter', 'courier', 'explorer', 'social', 'mechanic']
export const SESSION_GOALS = ['projectsCompleted', 'blocksVerified', 'resourceTransfers', 'foodCrafted', 'sessionsCompleted', 'joins', 'switches', 'exploredChunks', 'gatherings', 'cropsHarvested', 'pluginActions']

export function object(value, allowed, label) {
  if (!value || typeof value !== 'object' || Array.isArray(value)) throw new Error(`${label} must be an object`)
  for (const key of Object.keys(value)) if (!allowed.includes(key)) throw new Error(`Unknown ${label}.${key}`)
  return value
}

export function number(value, fallback, min, max, label, integer = false) {
  value ??= fallback
  if (typeof value !== 'number' || !Number.isFinite(value) || value < min || value > max || (integer && !Number.isInteger(value))) {
    throw new Error(`${label} must be ${integer ? 'an integer' : 'a number'} between ${min} and ${max}`)
  }
  return value
}

function range(value, fallback, min, max, label) {
  value ??= fallback
  if (!Array.isArray(value) || value.length !== 2) throw new Error(`${label} requires [minimum, maximum]`)
  const result = value.map((item) => number(item, undefined, min, max, label))
  if (result[0] > result[1]) throw new Error(`${label} minimum exceeds maximum`)
  return result
}

function text(value, fallback, expression, label) {
  value ??= fallback
  if (typeof value !== 'string' || !expression.test(value)) throw new Error(`${label} is invalid`)
  return value
}

function choice(value, fallback, allowed, label) {
  value ??= fallback
  if (!allowed.includes(value)) throw new Error(`${label} must be ${allowed.join(' or ')}`)
  return value
}

export function validateSessionProfile(raw, target) {
  object(raw, ['schemaVersion', 'name', 'seed', 'durationSeconds', 'completion', 'goals', 'population', 'playerRoles', 'playerWorlds', 'pluginActivities', 'pacing', 'recovery', 'timeouts', 'checkpointSeconds', 'worlds', 'network', 'telemetry'], 'profile')
  if (raw.schemaVersion !== 1) throw new Error('profile.schemaVersion must be 1')
  const population = object(raw.population ?? {}, ['identities', 'concurrent', 'usernamePrefix', 'arrivalIntervalSeconds', 'sessionSeconds', 'offlineSeconds', 'stages', 'groupSize', 'minimumAchievedFraction'], 'population')
  const identities = number(population.identities, 8, 1, 256, 'population.identities', true)
  const concurrent = number(population.concurrent, Math.min(4, identities), 1, identities, 'population.concurrent', true)
  const durationSeconds = number(raw.durationSeconds, 3600, 1, 604800, 'durationSeconds')
  const stages = population.stages ?? []
  if (!Array.isArray(stages) || stages.length > 128) throw new Error('population.stages must contain at most 128 stages')
  let previous = -1
  const normalizedStages = stages.map((stage) => {
    object(stage, ['atSeconds', 'concurrent'], 'population.stages[]')
    const atSeconds = number(stage.atSeconds, undefined, 0, durationSeconds, 'stage.atSeconds')
    if (atSeconds <= previous) throw new Error('Population stages must have increasing atSeconds')
    previous = atSeconds
    return { atSeconds, concurrent: number(stage.concurrent, undefined, 0, identities, 'stage.concurrent', true) }
  })
  const roles = raw.playerRoles ?? ['lumberjack', 'builder', 'farmer', 'miner', 'crafter', 'courier', 'explorer', 'social']
  if (!Array.isArray(roles) || !roles.length || roles.length > identities || roles.some((role) => !SESSION_ROLES.includes(role))) {
    if (raw.playerRoles === undefined) return validateSessionProfile({ ...raw, playerRoles: roles.slice(0, identities) }, target)
    throw new Error(`playerRoles must contain 1..${identities} roles from ${SESSION_ROLES.join(', ')}`)
  }
  const pacing = object(raw.pacing ?? {}, ['minSeconds', 'maxSeconds'], 'pacing')
  const minSeconds = number(pacing.minSeconds, 0.5, 0.01, 3600, 'pacing.minSeconds')
  const maxSeconds = number(pacing.maxSeconds, 3, minSeconds, 3600, 'pacing.maxSeconds')
  const recovery = object(raw.recovery ?? {}, ['maxConsecutiveFailures', 'maxTotalFailures', 'retrySeconds', 'death'], 'recovery')
  const timeouts = object(raw.timeouts ?? {}, ['connectSeconds', 'actionSeconds', 'settleSeconds'], 'timeouts')
  const goals = object(raw.goals ?? {}, SESSION_GOALS, 'goals')
  const normalizedGoals = Object.fromEntries(Object.entries(goals).map(([key, value]) => [key, number(value, undefined, 1, 1e9, `goals.${key}`, true)]))
  const rawWorlds = raw.worlds ?? [{ ...defaultSettlementWorld(), id: 'settlement' }]
  if (!Array.isArray(rawWorlds) || !rawWorlds.length || rawWorlds.length > 32) throw new Error('worlds must contain 1..32 world regions')
  const worlds = rawWorlds.map(({ id, ...rawWorld }) => {
    const world = validateWorld({ ...rawWorld, id: text(id, undefined, /^[A-Za-z0-9_.-]{1,64}$/, 'world.id') })
    if (target) {
      const aliases = target.backends.map((backend) => backend.alias)
      if (world.backend === 'standalone') world.backend = target.defaultBackend ?? aliases[0] ?? target.name
      if (!aliases.includes(world.backend)) throw new Error(`World backend ${world.backend} is not a target backend`)
    }
    return world
  })
  if (new Set(worlds.map((world) => world.id)).size !== worlds.length) throw new Error('World IDs must be distinct')
  const playerWorlds = raw.playerWorlds ?? [worlds[0].id]
  if (!Array.isArray(playerWorlds) || !playerWorlds.length || playerWorlds.length > identities || playerWorlds.some((id) => !worlds.some((world) => world.id === id))) throw new Error('playerWorlds must contain valid world IDs')
  for (const world of worlds) {
    const assignedRoles = Array.from({ length: identities }, (_, index) => playerWorlds[index % playerWorlds.length] === world.id ? roles[index % roles.length] : undefined)
    if (world.buildPlots.length && (!assignedRoles.includes('lumberjack') || !assignedRoles.includes('builder') || !assignedRoles.includes('miner'))) throw new Error(`World ${world.id} requires assigned miner, lumberjack, and builder roles`)
  }
  const network = object(raw.network ?? {}, ['routes', 'switchEverySeconds'], 'network')
  const routes = network.routes ?? []
  if (!Array.isArray(routes) || routes.length > 32 || new Set(routes).size !== routes.length || routes.some((alias) => typeof alias !== 'string' || !/^[A-Za-z0-9_.-]{1,64}$/.test(alias))) {
    throw new Error('network.routes must be distinct backend aliases (at most 32)')
  }
  if (target && routes.length && target.kind !== 'network') throw new Error('Network routes require a Velocity network target')
  if (target && routes.some((alias) => !target.backends.some((backend) => backend.alias === alias))) throw new Error('Network route contains an unknown backend')
  const telemetry = object(raw.telemetry ?? {}, ['required', 'maxAgeSeconds', 'maxP95TickMs', 'maxP99TickMs', 'warmupSeconds'], 'telemetry')
  if (telemetry.required !== undefined && typeof telemetry.required !== 'boolean') throw new Error('telemetry.required must be boolean')
  const normalizedTelemetry = { required: telemetry.required ?? false, maxAgeSeconds: number(telemetry.maxAgeSeconds, 15, 1, 3600, 'telemetry.maxAgeSeconds'), warmupSeconds: number(telemetry.warmupSeconds, 60, 0, 3600, 'telemetry.warmupSeconds') }
  for (const key of ['maxP95TickMs', 'maxP99TickMs']) if (telemetry[key] !== undefined) normalizedTelemetry[key] = number(telemetry[key], undefined, 0.01, 60000, `telemetry.${key}`)
  const completion = choice(raw.completion, 'duration', ['duration', 'goals'], 'completion')
  if (completion === 'goals' && !Object.keys(normalizedGoals).length && !worlds.some((world) => world.buildPlots.length)) throw new Error('Goal completion requires goals or build plots')
  const projectCount = worlds.reduce((sum, world) => sum + world.buildPlots.length, 0)
  const blockCount = worlds.reduce((sum, world) => sum + world.buildPlots.reduce((total, plot) => total + shelterBlueprint(plot).length, 0), 0)
  if ((normalizedGoals.projectsCompleted ?? 0) > projectCount) throw new Error('Project goal exceeds the configured build plots')
  if ((normalizedGoals.blocksVerified ?? 0) > blockCount) throw new Error('Block verification goal exceeds the configured blueprints')
  if (normalizedGoals.exploredChunks) {
    const explorers = Array.from({ length: identities }, (_, index) => roles[index % roles.length]).filter((role) => role === 'explorer').length
    if (normalizedGoals.exploredChunks > explorers * worlds.length * 2048 || !worlds.some((world) => world.frontiers.length)) throw new Error('Exploration goal exceeds assigned explorers, configured frontiers, or durable visit tracking capacity')
  }
  if (normalizedGoals.switches && routes.length < 2) throw new Error('Switch goals require at least two configured network routes')
  if (normalizedGoals.pluginActions && !raw.pluginActivities?.length) throw new Error('Plugin action goals require pluginActivities')
  return {
    schemaVersion: 1, name: text(raw.name, 'Persistent settlement', /^[^\r\n\x00-\x1f]{1,100}$/, 'name'),
    seed: number(raw.seed, 42, 1, 0xffffffff, 'seed', true), durationSeconds, completion, goals: normalizedGoals,
    population: { identities, concurrent, usernamePrefix: text(population.usernamePrefix, 'Sess', /^[A-Za-z0-9_]{1,12}$/, 'population.usernamePrefix'),
      arrivalIntervalSeconds: number(population.arrivalIntervalSeconds, 2, 0.05, 3600, 'population.arrivalIntervalSeconds'),
      sessionSeconds: range(population.sessionSeconds, [300, 900], 1, 604800, 'population.sessionSeconds'),
      offlineSeconds: range(population.offlineSeconds, [30, 180], 0.1, 604800, 'population.offlineSeconds'), stages: normalizedStages,
      groupSize: number(population.groupSize, Math.min(4, identities), 1, identities, 'population.groupSize', true),
      ...(population.minimumAchievedFraction !== undefined ? { minimumAchievedFraction: number(population.minimumAchievedFraction, undefined, 0, 1, 'population.minimumAchievedFraction') } : {}) },
    playerRoles: [...roles], playerWorlds: [...playerWorlds],
    pluginActivities: validatePluginActivities(raw.pluginActivities, { aliases: target?.backends.map((backend) => backend.alias), roles: SESSION_ROLES }),
    pacing: { minSeconds, maxSeconds },
    recovery: { maxConsecutiveFailures: number(recovery.maxConsecutiveFailures, 5, 1, 1000, 'recovery.maxConsecutiveFailures', true),
      maxTotalFailures: number(recovery.maxTotalFailures, 100, 1, 1000000, 'recovery.maxTotalFailures', true),
      retrySeconds: number(recovery.retrySeconds, 5, 0.1, 3600, 'recovery.retrySeconds'), death: choice(recovery.death, 'respawn', ['respawn', 'retire'], 'recovery.death') },
    timeouts: { connectSeconds: number(timeouts.connectSeconds, 45, 1, 300, 'timeouts.connectSeconds'),
      actionSeconds: number(timeouts.actionSeconds, 45, 1, 300, 'timeouts.actionSeconds'), settleSeconds: number(timeouts.settleSeconds, 5, 0.1, 30, 'timeouts.settleSeconds') },
    checkpointSeconds: number(raw.checkpointSeconds, 10, 0.1, 300, 'checkpointSeconds'), worlds,
    network: { routes: [...routes], switchEverySeconds: range(network.switchEverySeconds, [120, 300], 1, 604800, 'network.switchEverySeconds') }, telemetry: normalizedTelemetry
  }
}

export function playerNames(profile) {
  return Array.from({ length: profile.population.identities }, (_, index) => `${profile.population.usernamePrefix}${String(index + 1).padStart(3, '0')}`)
}

export function validateSessionConfiguration(raw) {
  object(raw, ['schemaVersion', 'runId', 'artifactsDirectory', 'profilePath', 'resume', 'parentPid', 'target', 'controller', 'viewerEnabled', 'viewerPort'], 'configuration')
  if (raw.schemaVersion !== 1) throw new Error('configuration.schemaVersion must be 1')
  const target = object(raw.target, ['kind', 'name', 'host', 'port', 'version', 'backends', 'defaultBackend', 'proxy', 'proxyLogPath', 'observerPath'], 'target')
  choice(target.kind, undefined, ['instance', 'network'], 'target.kind')
  text(target.name, undefined, /^[^\r\n\x00-\x1f]{1,128}$/, 'target.name')
  if (!['127.0.0.1', 'localhost', '::1'].includes(target.host)) throw new Error('Session targets must use loopback offline QA endpoints')
  number(target.port, undefined, 1, 65535, 'target.port', true)
  if (!Array.isArray(target.backends) || !target.backends.length || target.backends.length > 128) throw new Error('target.backends must contain 1..128 backends')
  const aliases = new Set()
  for (const backend of target.backends) {
    object(backend, ['alias', 'instance', 'port', 'logPath', 'observerPath'], 'backend')
    text(backend.alias, undefined, /^[A-Za-z0-9_.-]{1,64}$/, 'backend.alias')
    if (aliases.has(backend.alias)) throw new Error('Duplicate backend alias')
    aliases.add(backend.alias)
    text(backend.instance, undefined, /^[^\r\n\x00-\x1f]{1,128}$/, 'backend.instance')
    number(backend.port, undefined, 1, 65535, 'backend.port', true)
    for (const key of ['logPath', 'observerPath']) if (backend[key] !== undefined && (typeof backend[key] !== 'string' || !path.isAbsolute(backend[key]))) throw new Error(`backend.${key} must be an absolute path`)
  }
  if (target.defaultBackend !== undefined && !aliases.has(target.defaultBackend)) throw new Error('target.defaultBackend is unknown')
  if (target.version !== undefined && (typeof target.version !== 'string' || !/^[A-Za-z0-9_.-]{1,40}$/.test(target.version))) throw new Error('target.version is invalid')
  for (const key of ['proxyLogPath', 'observerPath']) if (target[key] !== undefined && (typeof target[key] !== 'string' || !path.isAbsolute(target[key]))) throw new Error(`target.${key} must be an absolute path`)
  const controller = object(raw.controller ?? {}, ['username'], 'controller')
  if (controller.username !== undefined) text(controller.username, undefined, /^[A-Za-z0-9_]{1,16}$/, 'controller.username')
  text(raw.runId, undefined, /^[A-Za-z0-9_.-]{1,100}$/, 'runId')
  for (const key of ['artifactsDirectory', 'profilePath']) if (typeof raw[key] !== 'string' || !path.isAbsolute(raw[key])) throw new Error(`${key} must be an absolute path`)
  for (const key of ['resume', 'viewerEnabled']) if (raw[key] !== undefined && typeof raw[key] !== 'boolean') throw new Error(`${key} must be boolean`)
  if (raw.viewerPort !== undefined) number(raw.viewerPort, undefined, 1, 65535, 'viewerPort', true)
  if (raw.parentPid !== undefined) number(raw.parentPid, undefined, 1, 2147483647, 'parentPid', true)
  return { ...raw, resume: raw.resume ?? false, viewerEnabled: raw.viewerEnabled ?? true, target: structuredClone(target), controller: { ...controller } }
}

export async function loadSessionProfile(profilePath, target) {
  const source = await readFile(profilePath, 'utf8')
  if (source.length > 1024 * 1024) throw new Error('Session profile exceeds 1 MiB')
  return validateSessionProfile(JSON.parse(source), target)
}

export function profileFingerprint(profile, target) {
  const stable = (value) => Array.isArray(value) ? value.map(stable) : value && typeof value === 'object'
    ? Object.fromEntries(Object.keys(value).sort().map((key) => [key, stable(value[key])])) : value
  return createHash('sha256').update(JSON.stringify(stable({ profile, target }))).digest('hex')
}

export function validationResult(profile) {
  return { status: 'passed', profile, playerNames: playerNames(profile),
    maximumPopulation: Math.max(profile.population.concurrent, ...profile.population.stages.map((stage) => stage.concurrent)),
    requiresController: profile.worlds.some((world) => world.setup.kind === 'settlement') }
}
