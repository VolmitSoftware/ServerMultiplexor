import { mkdir, writeFile } from 'node:fs/promises'
import path from 'node:path'

import { createScenarioContext, errorMessage, withTimeout } from './scenario_context.mjs'
import { loadScenario } from './scenario_loader.mjs'
import { startWebFeed, stopWebFeed } from './web_feed.mjs'

export async function runScenario(configuration) {
  const mineflayerModule = await import('mineflayer')
  const pathfinderModule = await import('mineflayer-pathfinder')
  const mineflayer = mineflayerModule.default ?? mineflayerModule
  const { Movements, pathfinder } = pathfinderModule
  const loaded = await loadScenario(configuration.scenario)
  const startedAt = new Date()
  const report = {
    schemaVersion: 1,
    status: 'running',
    scenario: {
      name: loaded.scenario.name,
      description: loaded.scenario.description,
      source: loaded.path
    },
    server: {
      instance: configuration.instance,
      host: configuration.host,
      port: configuration.port,
      minecraftVersion: configuration.version,
      logPath: configuration.logPath
    },
    bot: {
      requestedUsername: configuration.username,
      auth: configuration.auth
    },
    viewer: {
      enabled: configuration.viewerEnabled
    },
    startedAt: startedAt.toISOString(),
    steps: [],
    messages: [],
    errors: []
  }
  const output = configuration.json ? () => {} : configuration.output
  const notice = configuration.notice ?? configuration.output
  let quitting = false
  let viewerState
  let fatalReject
  const fatal = new Promise((resolve, reject) => {
    fatalReject = reject
  })

  const botOptions = {
    host: configuration.host,
    port: configuration.port,
    username: configuration.username,
    auth: configuration.auth,
    hideErrors: true,
    logErrors: false
  }
  if (configuration.version !== undefined) {
    botOptions.version = configuration.version
  }
  if (configuration.profilesFolder !== undefined) {
    botOptions.profilesFolder = configuration.profilesFolder
  }

  const bot = mineflayer.createBot(botOptions)
  bot.loadPlugin(pathfinder)
  bot.on('messagestr', (message) => {
    report.messages.push({ at: new Date().toISOString(), message })
  })
  bot.on('kicked', (reason) => {
    if (!quitting) {
      fatalReject(new Error(`Kicked: ${stringifyReason(reason)}`))
    }
  })
  bot.on('error', (error) => {
    if (!quitting) {
      fatalReject(error)
    }
  })
  bot.on('end', (reason) => {
    if (!quitting) {
      fatalReject(new Error(`Disconnected: ${stringifyReason(reason)}`))
    }
  })

  try {
    output(`[INFO] Connecting ${configuration.username} to ${configuration.host}:${configuration.port}`)
    await Promise.race([
      withTimeout(waitForSpawn(bot), configuration.connectTimeoutMs, 'Mineflayer spawn'),
      fatal
    ])
    report.bot.username = bot.username
    report.bot.version = bot.version
    report.bot.uuid = bot.player?.uuid
    report.bot.position = bot.entity?.position
    report.bot.serverBrand = bot.game?.serverBrand

    const movements = new Movements(bot)
    movements.canDig = false
    movements.allow1by1towers = false
    movements.scafoldingBlocks = []
    movements.allowParkour = false
    bot.pathfinder.setMovements(movements)

    if (configuration.viewerEnabled) {
      viewerState = await startWebFeed({
        artifactsDirectory: configuration.artifactsDirectory,
        bot,
        instance: configuration.instance,
        notice,
        port: configuration.viewerPort,
        scenario: loaded.scenario.name
      })
      report.viewer = viewerState
    }

    const context = createScenarioContext({
      bot,
      report,
      options: configuration.options,
      output
    })
    await Promise.race([
      withTimeout(
        Promise.resolve(loaded.scenario.run(context)),
        configuration.scenarioTimeoutMs,
        `Scenario ${loaded.scenario.name}`
      ),
      fatal
    ])
    report.status = 'passed'
  } catch (error) {
    report.status = 'failed'
    report.errors.push({
      message: errorMessage(error),
      name: error instanceof Error ? error.name : 'Error',
      details: error?.details
    })
  } finally {
    quitting = true
    try {
      await stopWebFeed(bot, viewerState, {
        instance: configuration.instance,
        scenario: loaded.scenario.name
      })
      bot.pathfinder?.stop()
      bot.quit('Multiplexor gameplay test complete')
    } catch (error) {
      report.errors.push({
        message: `Cleanup failed: ${errorMessage(error)}`,
        name: error instanceof Error ? error.name : 'Error'
      })
      report.status = 'failed'
      bot.end('Multiplexor gameplay test complete')
    }
  }

  report.finishedAt = new Date().toISOString()
  report.durationMs = new Date(report.finishedAt).getTime() - startedAt.getTime()
  report.artifact = await writeReport(report, configuration.artifactsDirectory)
  return report
}

function waitForSpawn(bot) {
  return new Promise((resolve) => bot.once('spawn', resolve))
}

async function writeReport(report, directory) {
  if (directory === undefined) {
    return undefined
  }
  await mkdir(directory, { recursive: true })
  const timestamp = report.startedAt.replaceAll(':', '').replaceAll('.', '-')
  const instance = sanitize(report.server.instance)
  const scenario = sanitize(report.scenario.name)
  const reportPath = path.join(directory, `${timestamp}-${instance}-${scenario}.json`)
  report.artifact = reportPath
  await writeFile(reportPath, `${JSON.stringify(report, null, 2)}\n`)
  return reportPath
}

function sanitize(value) {
  return String(value ?? 'unknown').replaceAll(/[^A-Za-z0-9_.-]/g, '-')
}

function stringifyReason(reason) {
  if (typeof reason === 'string') {
    return reason
  }
  try {
    return JSON.stringify(reason)
  } catch {
    return String(reason)
  }
}
