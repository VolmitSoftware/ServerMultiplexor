import { mkdir, writeFile } from 'node:fs/promises'
import path from 'node:path'

import { createScenarioContext, errorMessage, withTimeout } from './scenario_context.mjs'
import { loadScenario } from './scenario_loader.mjs'
import { startWebFeed, stopWebFeed } from './web_feed.mjs'
import { createActorManager } from './scenario_actors.mjs'
import { hashFile, installedPlugins } from './scenario_builds.mjs'

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
      directory: configuration.instanceDirectory,
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
  const abort = new AbortController()
  let viewerState
  let bot
  const actors = createActorManager({
    configuration, report, signal: abort.signal, fail: (error) => abort.abort(error),
    runtime: {
      createBot: (options) => mineflayer.createBot(options),
      install: (actor) => actor.loadPlugin(pathfinder),
      configure: (actor) => {
        const movements = new Movements(actor)
        movements.canDig = false
        movements.allow1by1towers = false
        movements.scafoldingBlocks = []
        movements.allowParkour = false
        actor.pathfinder.setMovements(movements)
      }
    }
  })
  const cancelled = () => abort.abort(new Error('Gameplay scenario interrupted'))
  process.on('SIGINT', cancelled)
  process.on('SIGTERM', cancelled)
  let scenarioTimer

  try {
    report.scenario.sha256 = await hashFile(loaded.path)
    report.plugins = await installedPlugins(configuration.instanceDirectory)
    output(`[INFO] Connecting ${configuration.username} to ${configuration.host}:${configuration.port}`)
    bot = await actors.connect(configuration.username, { primary: true })
    report.bot.username = bot.username
    report.bot.version = bot.version
    report.bot.uuid = bot.player?.uuid
    report.bot.position = bot.entity?.position && { ...bot.entity.position }
    report.bot.serverBrand = bot.game?.serverBrand

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

    const contextFor = (actor) => createScenarioContext({
      bot: actor,
      report,
      options: configuration.options,
      output,
      signal: abort.signal,
      connectActor: async (name) => contextFor(await actors.connect(name)),
      reconnectAfter: async (trigger, settings) => {
        const primary = actor === bot
        if (primary && viewerState) {
          await stopWebFeed(bot, viewerState, { instance: configuration.instance, scenario: loaded.scenario.name })
          report.viewerHistory ??= []
          report.viewerHistory.push(viewerState)
        }
        const replacement = await actors.reconnectAfter(actor, trigger, settings)
        if (primary) {
          bot = replacement
          if (configuration.viewerEnabled) {
            viewerState = await startWebFeed({ artifactsDirectory: configuration.artifactsDirectory, bot, instance: configuration.instance,
              notice, port: configuration.viewerPort, scenario: loaded.scenario.name })
            report.viewer = viewerState
          }
        }
        return contextFor(replacement)
      }
    })
    const context = contextFor(bot)
    scenarioTimer = setTimeout(() => abort.abort(new Error(`Scenario ${loaded.scenario.name} timed out`)), configuration.scenarioTimeoutMs)
    await withTimeout(Promise.resolve().then(() => loaded.scenario.run(context)), configuration.scenarioTimeoutMs, `Scenario ${loaded.scenario.name}`, abort.signal)
    abort.signal.throwIfAborted()
    report.status = 'passed'
  } catch (error) {
    report.status = 'failed'
    report.errors.push({
      message: errorMessage(error),
      name: error instanceof Error ? error.name : 'Error',
      details: error?.details
    })
  } finally {
    clearTimeout(scenarioTimer)
    abort.abort(new Error('Gameplay scenario finished'))
    try {
      if (bot) await stopWebFeed(bot, viewerState, {
        instance: configuration.instance,
        scenario: loaded.scenario.name
      })
    } catch (error) {
      report.errors.push({
        message: `Cleanup failed: ${errorMessage(error)}`,
        name: error instanceof Error ? error.name : 'Error'
      })
      report.status = 'failed'
    }
    try { await actors.close() }
    catch (error) { report.errors.push({ message: `Actor cleanup failed: ${errorMessage(error)}`, name: error.name }); report.status = 'failed' }
    process.removeListener('SIGINT', cancelled)
    process.removeListener('SIGTERM', cancelled)
  }

  report.finishedAt = new Date().toISOString()
  report.durationMs = new Date(report.finishedAt).getTime() - startedAt.getTime()
  report.artifact = await writeReport(report, configuration.artifactsDirectory)
  return report
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
