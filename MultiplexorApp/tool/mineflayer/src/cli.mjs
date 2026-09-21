#!/usr/bin/env node
import { createRequire } from 'node:module'

import { parseArguments, positiveInteger } from './arguments.mjs'
import { runScenario } from './runner.mjs'
import { listScenarios } from './scenario_loader.mjs'
import { parseSwarmConfiguration, parseSwarmOptions } from './swarm_config.mjs'
import { runSwarm } from './swarm_runner.mjs'

const parsed = parseArguments(process.argv.slice(2))
const command = parsed.positionals[0] ?? 'doctor'

try {
  const exitCode = await dispatch(command, parsed)
  process.exitCode = exitCode
} catch (error) {
  if (parsed.flag('json')) {
    process.stdout.write(`${JSON.stringify({ status: 'failed', error: error.message })}\n`)
  } else {
    process.stderr.write(`[ERROR] ${error.message}\n`)
  }
  process.exitCode = 2
}

async function dispatch(command, args) {
  switch (command) {
    case 'doctor':
      return doctor(args.flag('json'))
    case 'list':
      return list(args.flag('json'))
    case 'run':
      return run(args)
    case 'swarm':
      return swarm(process.argv.slice(3))
    case 'swarm-profiles':
      return swarmProfiles(args.flag('json'))
    case 'swarm-validate':
      return swarmValidate(process.argv.slice(3))
    case 'swarm-workload-validate':
      return swarmWorkloadValidate(process.argv.slice(3))
    case 'sessions-validate':
      return sessionsValidate(process.argv.slice(3))
    case 'sessions-run':
      return sessionsRun(process.argv.slice(3))
    default:
      throw new Error('Usage: cli.mjs <doctor|list|run|swarm|swarm-profiles|swarm-validate|swarm-workload-validate|sessions-validate|sessions-run>')
  }
}

async function sessionsValidate(tokens) {
  const { values, positionals } = parseSwarmOptions(tokens, new Set(['json']), new Set(['profile', 'configuration']))
  if (positionals.length || !values.has('profile')) throw new Error('Usage: sessions-validate --profile <profile.json> [--configuration <configuration.json>] [--json]')
  const { readFile } = await import('node:fs/promises')
  const { loadSessionProfile, validateSessionConfiguration, validationResult } = await import('./sessions/configuration.mjs')
  const configuration = values.has('configuration') ? validateSessionConfiguration(JSON.parse(await readFile(values.get('configuration'), 'utf8'))) : undefined
  const profile = await loadSessionProfile(values.get('profile'), configuration?.target)
  const result = validationResult(profile)
  if (values.has('json')) process.stdout.write(`${JSON.stringify(result)}\n`)
  else process.stdout.write(`[PASS] ${profile.name}: ${result.playerNames.length} persistent players, ${result.maximumPopulation} peak concurrent\n`)
  return 0
}

async function sessionsRun(tokens) {
  const { values, positionals } = parseSwarmOptions(tokens, new Set(['json']), new Set(['configuration']))
  if (positionals.length || !values.has('configuration')) throw new Error('Usage: sessions-run --configuration <configuration.json> [--json]')
  const { readFile } = await import('node:fs/promises')
  const { runSessions } = await import('./sessions/runner.mjs')
  const configuration = JSON.parse(await readFile(values.get('configuration'), 'utf8'))
  const report = await runSessions(configuration, { notice: (line) => (values.has('json') ? process.stderr : process.stdout).write(`${line}\n`) })
  if (values.has('json')) process.stdout.write(`${JSON.stringify(report)}\n`)
  else process.stdout.write(`[${report.status === 'failed' ? 'FAIL' : 'INFO'}] ${report.profileName}: ${report.status}; report ${report.artifact}\n`)
  return report.status === 'failed' ? 1 : 0
}

async function swarmProfiles(json) {
  const { SWARM_PROFILES } = await import('./swarm_behaviors.mjs')
  if (json) process.stdout.write(`${JSON.stringify({ profiles: SWARM_PROFILES })}\n`)
  else for (const profile of SWARM_PROFILES) process.stdout.write(`${profile.name}\t${profile.description}\n`)
  return 0
}

async function swarmValidate(tokens) {
  const { values, positionals } = parseSwarmOptions(tokens, new Set(['json']), new Set(['bots', 'origin']))
  if (positionals.length !== 1) throw new Error('Usage: swarm-validate <plan.json> [--bots <count>] [--origin x,y,z] [--json]')
  const { SWARM_PROFILES } = await import('./swarm_behaviors.mjs')
  const configuration = await parseSwarmConfiguration([
    positionals[0], '--port', '1', '--controller', 'Validation',
    '--bots', values.get('bots') ?? '256', '--origin', values.get('origin') ?? '0,80,0'
  ], SWARM_PROFILES)
  if (configuration.profile !== 'custom') throw new Error('swarm-validate requires a .json plan path')
  const plan = configuration.plan
  if (values.has('json')) process.stdout.write(`${JSON.stringify({ status: 'passed', plan })}\n`)
  else process.stdout.write(`[PASS] ${plan.name}: ${plan.phases.length} phases\n`)
  return 0
}

async function swarmWorkloadValidate(tokens) {
  const { values, positionals } = parseSwarmOptions(tokens,
    new Set(['json', 'build-arena', 'chat']),
    new Set(['bots', 'duration', 'origin', 'radius', 'bounds', 'goals', 'completion']))
  if (positionals.length > 1) throw new Error('Usage: swarm-workload-validate [workload.json] [options]')
  const arguments_ = ['stress', '--port', '1', '--controller', 'Validation']
  if (positionals.length === 1) arguments_.push('--workload', positionals[0])
  for (const [name, value] of values) {
    arguments_.push(`--${name}`)
    if (value !== true) arguments_.push(value)
  }
  const { SWARM_PROFILES } = await import('./swarm_behaviors.mjs')
  const configuration = await parseSwarmConfiguration(arguments_, SWARM_PROFILES)
  if (values.has('json')) process.stdout.write(`${JSON.stringify({ status: 'passed', workload: configuration.workload })}\n`)
  else process.stdout.write(`[PASS] ${configuration.workload.name}\n`)
  return 0
}

async function swarm(tokens) {
  const { SWARM_PROFILES } = await import('./swarm_behaviors.mjs')
  const configuration = await parseSwarmConfiguration(tokens, SWARM_PROFILES)
  configuration.notice = (line) => (configuration.json ? process.stderr : process.stdout).write(`${line}\n`)
  const report = await runSwarm(configuration)
  if (configuration.json) process.stdout.write(`${JSON.stringify(report)}\n`)
  else {
    const stream = report.status === 'passed' ? process.stdout : process.stderr
    stream.write(`[${report.status === 'passed' ? 'PASS' : 'FAIL'}] Swarm ${report.profile}: ${report.bots.length} workers; ${report.status}\n`)
    for (const error of report.errors) stream.write(`[FAIL] ${error.message}\n`)
    stream.write(`[INFO] Report: ${report.artifact}\n`)
  }
  return report.status === 'passed' ? 0 : 1
}

async function doctor(json) {
  const checks = []
  const nodeMajor = Number.parseInt(process.versions.node.split('.')[0], 10)
  checks.push({
    name: 'node',
    status: nodeMajor >= 22 ? 'PASS' : 'FAIL',
    detail: process.version
  })

  try {
    const mineflayerModule = await import('mineflayer')
    const mineflayer = mineflayerModule.default ?? mineflayerModule
    const require = createRequire(import.meta.url)
    const packageMetadata = require('mineflayer/package.json')
    const supportsRequiredVersion = mineflayer.testedVersions.includes('26.1')
    checks.push({
      name: 'mineflayer',
      status: packageMetadata.version === '4.38.0' && supportsRequiredVersion ? 'PASS' : 'FAIL',
      detail: `${packageMetadata.version}; ${mineflayer.testedVersions.length} tested versions; latest ${mineflayer.latestSupportedVersion}`
    })
  } catch (error) {
    checks.push({ name: 'mineflayer', status: 'FAIL', detail: error.message })
  }

  try {
    const require = createRequire(import.meta.url)
    const packageMetadata = require('mineflayer-pathfinder/package.json')
    checks.push({
      name: 'mineflayer-pathfinder',
      status: packageMetadata.version === '2.4.5' ? 'PASS' : 'FAIL',
      detail: packageMetadata.version
    })
  } catch (error) {
    checks.push({ name: 'mineflayer-pathfinder', status: 'FAIL', detail: error.message })
  }

  try {
    const require = createRequire(import.meta.url)
    const packageMetadata = require('prismarine-viewer/package.json')
    checks.push({
      name: 'prismarine-viewer',
      status: packageMetadata.version === '1.33.0' ? 'PASS' : 'FAIL',
      detail: packageMetadata.version
    })
  } catch (error) {
    checks.push({ name: 'prismarine-viewer', status: 'FAIL', detail: error.message })
  }

  const result = {
    status: checks.some((check) => check.status === 'FAIL') ? 'failed' : 'passed',
    checks
  }
  if (json) {
    process.stdout.write(`${JSON.stringify(result)}\n`)
  } else {
    process.stdout.write('Multiplexor Mineflayer doctor\n')
    for (const check of checks) {
      process.stdout.write(`[${check.status}] ${check.name}: ${check.detail}\n`)
    }
  }
  return result.status === 'passed' ? 0 : 1
}

async function list(json) {
  const scenarios = await listScenarios()
  if (json) {
    process.stdout.write(`${JSON.stringify({ scenarios })}\n`)
  } else {
    for (const scenario of scenarios) {
      process.stdout.write(`${scenario.name}\t${scenario.description}\n`)
    }
  }
  return 0
}

async function run(args) {
  const scenario = args.option('scenario') ?? args.positionals[1]
  if (scenario === undefined) {
    throw new Error('--scenario is required')
  }
  const port = positiveInteger(args.option('port'), undefined, '--port')
  if (port === undefined || port > 65535) {
    throw new Error('--port must be between 1 and 65535')
  }
  const timeoutSeconds = positiveInteger(args.option('timeout'), 30, '--timeout')
  const connectTimeoutSeconds = positiveInteger(
    args.option('connect-timeout'),
    30,
    '--connect-timeout'
  )
  const assertionTimeoutSeconds = positiveInteger(
    args.option('assertion-timeout'),
    10,
    '--assertion-timeout'
  )
  const viewerPort = positiveInteger(args.option('viewer-port'), undefined, '--viewer-port')
  if (viewerPort !== undefined && viewerPort > 65535) {
    throw new Error('--viewer-port must be between 1 and 65535')
  }
  const json = args.flag('json')
  const report = await runScenario({
    artifactsDirectory: args.option('artifacts'),
    auth: args.option('auth') ?? 'offline',
    connectTimeoutMs: connectTimeoutSeconds * 1000,
    host: args.option('host') ?? '127.0.0.1',
    instance: args.option('instance') ?? 'unknown',
    instanceDirectory: args.option('instance-directory'),
    json,
    logPath: args.option('log-path'),
    notice: (line) => {
      const stream = json ? process.stderr : process.stdout
      stream.write(`${line}\n`)
    },
    options: {
      assertionTimeoutMs: assertionTimeoutSeconds * 1000,
      command: args.option('command'),
      effect: args.option('effect'),
      expect: args.option('expect')
    },
    output: (line) => process.stdout.write(`${line}\n`),
    port,
    profilesFolder: args.option('profiles-folder'),
    scenario,
    scenarioTimeoutMs: timeoutSeconds * 1000,
    username: args.option('username') ?? 'VolmitQA',
    version: args.option('version'),
    viewerEnabled: !args.flag('no-viewer'),
    viewerPort
  })

  if (json) {
    process.stdout.write(`${JSON.stringify(report)}\n`)
  } else if (report.status === 'passed') {
    process.stdout.write(`[PASS] ${report.scenario.name} on ${report.server.instance} (${report.durationMs}ms)\n`)
    if (report.artifact !== undefined) {
      process.stdout.write(`[INFO] Report: ${report.artifact}\n`)
    }
  } else {
    for (const error of report.errors) {
      process.stderr.write(`[FAIL] ${error.message}\n`)
    }
    if (report.artifact !== undefined) {
      process.stderr.write(`[INFO] Report: ${report.artifact}\n`)
    }
  }
  return report.status === 'passed' ? 0 : 1
}
