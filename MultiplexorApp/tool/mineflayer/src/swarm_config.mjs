import { randomBytes } from 'node:crypto'
import path from 'node:path'

const FLAGS = new Set(['build-arena', 'no-viewer', 'json', 'chat'])
const OPTIONS = new Set([
  'host', 'port', 'instance', 'bots', 'duration', 'seed', 'join-interval',
  'radius', 'prefix', 'controller', 'origin', 'connect-timeout', 'action-timeout',
  'artifacts', 'log-path', 'version', 'viewer-port', 'scatter',
  'workload', 'bounds', 'goals', 'completion'
])

export function parseSwarmOptions(tokens, flags = FLAGS, options = OPTIONS) {
  const values = new Map()
  const positionals = []
  for (let index = 0; index < tokens.length; index += 1) {
    const token = tokens[index]
    if (!token.startsWith('--')) {
      positionals.push(token)
      continue
    }
    const equals = token.indexOf('=')
    const name = token.slice(2, equals < 0 ? undefined : equals)
    if (!flags.has(name) && !options.has(name)) throw new Error(`Unknown swarm option: --${name}`)
    if (values.has(name)) throw new Error(`Duplicate swarm option: --${name}`)
    if (flags.has(name)) {
      if (equals >= 0) throw new Error(`--${name} does not take a value`)
      values.set(name, true)
      continue
    }
    const value = equals < 0 ? tokens[++index] : token.slice(equals + 1)
    if (value === undefined || value.startsWith('--') || value === '') {
      throw new Error(`--${name} requires a value`)
    }
    values.set(name, value)
  }
  return { values, positionals }
}

export async function parseSwarmConfiguration(tokens, profiles, { loadPlan, workloads } = {}) {
  const { values, positionals } = parseSwarmOptions(tokens)
  if (positionals.length !== 1) throw new Error('Usage: swarm <profile> [options]')
  const number = (name, fallback, minimum, maximum) => {
    const value = values.get(name)
    if (value === undefined) return fallback
    if (!/^\d+$/.test(value)) throw new Error(`--${name} must be an integer`)
    const parsed = Number(value)
    if (!Number.isSafeInteger(parsed) || parsed < minimum || parsed > maximum) {
      throw new Error(`--${name} must be between ${minimum} and ${maximum}`)
    }
    return parsed
  }
  const originText = values.get('origin') ?? '0,80,0'
  if (!/^-?\d+,-?\d+,-?\d+$/.test(originText)) {
    throw new Error('--origin requires three comma-separated integer coordinates: x,y,z')
  }
  const [x, y, z] = originText.split(',').map(Number)
  const configuration = {
    profile: positionals[0],
    host: values.get('host') ?? '127.0.0.1',
    port: number('port', undefined, 1, 65535),
    instance: values.get('instance') ?? 'unknown',
    bots: number('bots', 4, 1, 256),
    durationMs: number('duration', 60, 1, 604800) * 1000,
    seed: number('seed', 1, 0, 0xffffffff),
    joinIntervalMs: number('join-interval', 1000, 100, 10000),
    radius: number('radius', 16, 4, 64),
    prefix: values.get('prefix') ?? `Sw${randomBytes(4).toString('hex')}`,
    controller: values.get('controller'),
    buildArena: values.get('build-arena') === true,
    scatter: number('scatter', undefined, 8, 4096),
    chat: values.get('chat') === true,
    origin: { x, y, z },
    connectTimeoutMs: number('connect-timeout', 30, 1, 300) * 1000,
    actionTimeoutMs: number('action-timeout', 15, 1, 120) * 1000,
    artifactsDirectory: path.resolve(values.get('artifacts') ?? '.multiplexor/swarm-reports'),
    logPath: values.get('log-path'),
    version: values.get('version'),
    viewerPort: number('viewer-port', undefined, 1, 65535),
    viewerEnabled: values.get('no-viewer') !== true,
    json: values.get('json') === true,
    auth: 'offline'
  }
  if (!profiles.some((profile) => profile.name === configuration.profile)) {
    if (!configuration.profile.toLowerCase().endsWith('.json')) {
      throw new Error(`Unknown swarm profile: ${configuration.profile}; custom plans must use a .json path`)
    }
    const loader = loadPlan ?? (await import('./swarm_plans.mjs')).loadSwarmPlan
    configuration.sourcePath = path.resolve(configuration.profile)
    configuration.plan = await loader(configuration.sourcePath, { bots: configuration.bots })
    configuration.profile = 'custom'
  }
  if (configuration.profile === 'stress') {
    const module = workloads ?? await import('./swarm_workload.mjs')
    const options = {
      ...configuration, bounds: values.get('bounds'), goals: parseGoals(values.get('goals')), completion: values.get('completion')
    }
    configuration.workloadSource = values.has('workload') ? path.resolve(values.get('workload')) : undefined
    configuration.workload = configuration.workloadSource === undefined
      ? module.defaultWorkload(options)
      : await module.loadWorkload(configuration.workloadSource, options)
    configuration.bounds = configuration.workload.bounds
  } else if (['workload', 'bounds', 'goals', 'completion'].some((name) => values.has(name))) {
    throw new Error('--workload, --bounds, --goals, and --completion are available only with the stress profile')
  }
  validateSwarmConfiguration(configuration, profiles)
  return configuration
}

export function swarmWorkerNames(configuration) {
  return Array.from({ length: configuration.bots }, (_, index) =>
    `${configuration.prefix}${String(index + 1).padStart(2, '0')}`)
}

export function validateSwarmConfiguration(configuration, profiles) {
  const profile = configuration.profile === 'custom' && configuration.plan !== undefined
    ? { name: 'custom', requiresArena: false }
    : profiles.find((item) => item.name === configuration.profile)
  if (profile === undefined) throw new Error(`Unknown swarm profile: ${configuration.profile}`)
  if (!['127.0.0.1', '::1'].includes(configuration.host) || configuration.auth !== 'offline') {
    throw new Error('Swarms require a literal loopback address and offline authentication')
  }
  for (const [key, minimum, maximum] of [
    ['port', 1, 65535], ['bots', 1, 256], ['durationMs', 1000, 604800000],
    ['seed', 0, 0xffffffff], ['joinIntervalMs', 100, 10000], ['radius', 4, 64],
    ['connectTimeoutMs', 1000, 300000], ['actionTimeoutMs', 1000, 120000]
  ]) {
    if (!Number.isSafeInteger(configuration[key]) || configuration[key] < minimum || configuration[key] > maximum) {
      throw new Error(`Invalid swarm ${key}: expected ${minimum}..${maximum}`)
    }
  }
  if (configuration.viewerPort !== undefined &&
      (!Number.isInteger(configuration.viewerPort) || configuration.viewerPort < 1 || configuration.viewerPort > 65535)) {
    throw new Error('Invalid swarm viewer port')
  }
  if (configuration.viewerEnabled === false && configuration.viewerPort !== undefined) {
    throw new Error('--viewer-port cannot be combined with --no-viewer')
  }
  if (!/^[A-Za-z0-9_]{1,12}$/.test(configuration.prefix)) {
    throw new Error('--prefix must contain 1..12 letters, digits, or underscores')
  }
  if (profile.requiresArena && !configuration.buildArena) {
    throw new Error(`Swarm profile ${profile.name} requires --build-arena`)
  }
  if (configuration.scatter !== undefined &&
      (!Number.isInteger(configuration.scatter) || configuration.scatter < 8 || configuration.scatter > 4096)) {
    throw new Error('--scatter must be between 8 and 4096 blocks')
  }
  if (configuration.buildArena && configuration.scatter !== undefined) {
    throw new Error('--scatter cannot be combined with --build-arena')
  }
  if (configuration.profile === 'custom' && configuration.buildArena) {
    throw new Error('Custom swarm plans cannot be combined with --build-arena')
  }
  if (configuration.profile === 'stress' && configuration.scatter !== undefined) {
    throw new Error('--scatter cannot be combined with the stress profile; use workload bounds')
  }
  if (configuration.profile !== 'stress' && (configuration.workload !== undefined || configuration.bounds !== undefined)) {
    throw new Error('Workloads and bounds are available only with the stress profile')
  }
  if (swarmNeedsController(configuration)) {
    if (typeof configuration.controller !== 'string' || !/^[A-Za-z0-9_]{1,16}$/.test(configuration.controller)) {
      throw new Error('Arena, scatter, custom plans, and stress require a reserved --controller username (1..16 letters, digits, or underscores)')
    }
    if (swarmWorkerNames(configuration).some((name) => name.toLowerCase() === configuration.controller.toLowerCase())) {
      throw new Error('The swarm controller must have a different username from every worker')
    }
  }
  const { x, y, z } = configuration.origin ?? {}
  if (![x, y, z].every(Number.isSafeInteger) || Math.abs(x) > 29999000 || Math.abs(z) > 29999000 || y < -48 || y > 256) {
    throw new Error('--origin requires x/z within +/-29999000 and y within -48..256')
  }
  const scatterRadius = Math.max(configuration.scatter ?? 0,
    ...(configuration.plan?.phases ?? []).filter((phase) => phase.action === 'scatter').map((phase) => phase.radius))
  if (Math.abs(x) + scatterRadius > 29999000 || Math.abs(z) + scatterRadius > 29999000) {
    throw new Error('Scatter area exceeds safe world coordinates; move --origin farther from the world border')
  }
  if (typeof configuration.artifactsDirectory !== 'string' || configuration.artifactsDirectory.length === 0) {
    throw new Error('A swarm artifacts directory is required')
  }
  return profile
}

export function swarmNeedsController(configuration) {
  return configuration.buildArena || configuration.scatter !== undefined || ['custom', 'stress'].includes(configuration.profile)
}

function parseGoals(value) {
  if (value === undefined) return undefined
  const goals = {}
  for (const entry of value.split(',')) {
    const match = /^([a-z]+)=(\d+)$/.exec(entry)
    if (match === null || Object.hasOwn(goals, match[1])) throw new Error('--goals requires distinct activity=count pairs')
    const count = Number(match[2])
    if (!Number.isSafeInteger(count) || count < 1 || count > 1000000000) throw new Error('Goal counts must be between 1 and 1000000000')
    goals[match[1]] = count
  }
  return goals
}
