#!/usr/bin/env node
import { createRequire } from 'node:module'

import { parseArguments, positiveInteger } from './arguments.mjs'
import { runScenario } from './runner.mjs'
import { listScenarios } from './scenario_loader.mjs'

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
    default:
      throw new Error('Usage: cli.mjs <doctor|list|run>')
  }
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
    checks.push({
      name: 'mineflayer',
      status: packageMetadata.version === '4.37.1' ? 'PASS' : 'FAIL',
      detail: `${packageMetadata.version}; ${mineflayer.testedVersions.length} tested versions`
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
