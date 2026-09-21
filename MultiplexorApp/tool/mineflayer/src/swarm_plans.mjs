import { readFile } from 'node:fs/promises'
import { bounded, buildBlock, controllerCommand, interact, mineBlock, pause, point, sendChat, until, walkTo } from './swarm_actions.mjs'
import { scatterSwarm } from './swarm_behaviors.mjs'
import { circleRoute, createScenarioActions } from './scenario_actions.mjs'

const actions = new Set(['chat', 'teleport', 'scatter', 'walk', 'circle', 'mine', 'build', 'interact', 'wait'])
const fields = {
  chat: ['messages'], teleport: ['positions'], scatter: ['radius'], walk: ['positions'],
  circle: ['positions', 'radius', 'laps', 'clockwise'],
  mine: ['positions'], build: ['positions', 'block'], interact: ['positions'], wait: ['seconds']
}

function object(value, label) {
  if (!value || typeof value !== 'object' || Array.isArray(value)) throw new Error(`${label} must be an object`)
}

function coordinate(value) {
  return Array.isArray(value) && value.length === 3 && value.every(Number.isInteger) &&
    Math.abs(value[0]) <= 29999000 && Math.abs(value[2]) <= 29999000 && value[1] >= -48 && value[1] <= 256
}

export function validateSwarmPlan(value, { bots = 256 } = {}) {
  object(value, 'Plan')
  if (Object.keys(value).some((key) => !['name', 'phases'].includes(key))) throw new Error('Plan supports only name and phases')
  if (typeof value.name !== 'string' || !/^[A-Za-z0-9][A-Za-z0-9 _.-]{0,63}$/.test(value.name)) throw new Error('Plan name must be 1-64 plain characters')
  if (!Array.isArray(value.phases) || value.phases.length < 1 || value.phases.length > 128) throw new Error('Plan needs 1-128 phases')
  for (const [index, phase] of value.phases.entries()) {
    object(phase, `Phase ${index + 1}`)
    if (!actions.has(phase.action)) throw new Error(`Unknown phase action: ${phase.action}`)
    if (Object.keys(phase).some((key) => !['action', 'actors', ...fields[phase.action]].includes(key))) throw new Error(`Unknown field in ${phase.action} phase ${index + 1}`)
    if (phase.actors !== undefined && (!Array.isArray(phase.actors) || phase.actors.length === 0 ||
      phase.actors.some((actor) => !Number.isInteger(actor) || actor < 1 || actor > bots) || new Set(phase.actors).size !== phase.actors.length)) {
      throw new Error(`Phase ${index + 1} actors must be distinct worker numbers from 1 through ${bots}`)
    }
    if (fields[phase.action].includes('positions')) {
      if (!Array.isArray(phase.positions) || phase.positions.length < 1 || phase.positions.length > 1024 || !phase.positions.every(coordinate)) throw new Error(`Phase ${index + 1} needs 1-1024 integer [x,y,z] positions`)
      if (new Set(phase.positions.map((position) => position.join(','))).size !== phase.positions.length) throw new Error(`Phase ${index + 1} repeats a target position`)
    }
    if (phase.action === 'chat' && (!Array.isArray(phase.messages) || phase.messages.length < 1 || phase.messages.length > 64 ||
      phase.messages.some((message) => typeof message !== 'string' || message.length < 1 || message.length > 200 || /[\r\n\x00-\x1f\x7f]/.test(message) || message.trimStart().startsWith('/')))) {
      throw new Error('Chat messages must be 1-200 characters of plain chat, never commands')
    }
    if (phase.action === 'scatter' && (!Number.isInteger(phase.radius) || phase.radius < 8 || phase.radius > 4096)) throw new Error('Scatter radius must be 8-4096 blocks')
    if (phase.action === 'circle') {
      for (const center of phase.positions) circleRoute({ center: { x: center[0], y: center[1], z: center[2] }, radius: phase.radius, laps: phase.laps, clockwise: phase.clockwise })
    }
    if (phase.action === 'wait' && (!Number.isFinite(phase.seconds) || phase.seconds < 0.1 || phase.seconds > 300)) throw new Error('Wait must be 0.1-300 seconds')
    if (phase.action === 'build' && (typeof phase.block !== 'string' || !/^[a-z][a-z0-9_]{0,63}$/.test(phase.block))) throw new Error('Build block must be a Minecraft block identifier')
  }
  return structuredClone(value)
}

export async function loadSwarmPlan(filename, options) {
  const source = await readFile(filename, 'utf8')
  if (source.length > 1024 * 1024) throw new Error('Swarm plan must be at most 1 MiB')
  return validateSwarmPlan(JSON.parse(source), options)
}

/** Each phase is a barrier; positions are jobs distributed round-robin across its actors. */
export async function runSwarmPlan({ bots, controller, plan, origin, deadline, signal, record, actionTimeoutMs, chat = false }) {
  plan = validateSwarmPlan(plan, { bots: bots.length })
  const duration = Math.max(1, deadline - performance.now())
  await bounded(`Plan ${plan.name}`, duration, signal, async (current) => {
    await controllerCommand(controller, '/gamemode spectator @s', current, actionTimeoutMs)
    for (const bot of bots) {
      if (bot.game?.gameMode && bot.game.gameMode !== 'survival') {
        await controllerCommand(controller, `/gamemode survival ${bot.username}`, current, actionTimeoutMs)
      }
    }
    let lastProgressChat = -Infinity
    for (const [phaseIndex, phase] of plan.phases.entries()) {
      current.throwIfAborted()
      const actors = (phase.actors ?? bots.map((_, index) => index + 1)).map((number) => ({ bot: bots[number - 1], index: number - 1 }))
      record({ action: 'phase', phase: phaseIndex + 1, status: 'started', task: phase.action })
      if (phase.action === 'scatter') {
        await scatterSwarm({ controller, bots: actors.map(({ bot }) => bot), origin, radius: phase.radius, signal: current, actionTimeoutMs,
          record: (event) => record({ ...event, index: bots.findIndex((bot) => bot.username === event.bot), phase: phaseIndex + 1 }) })
      } else if (phase.action === 'wait') {
        await pause(phase.seconds * 1000, current)
      } else {
        if (phase.action === 'build') {
          for (const { bot } of actors) {
            if (!bot.registry.blocksByName[phase.block]) throw new Error(`Unknown block: ${phase.block}`)
            await controllerCommand(controller, `/give ${bot.username} ${phase.block} ${Math.ceil(phase.positions.length / actors.length)}`, current, actionTimeoutMs)
          }
        }
        if (phase.action === 'mine') {
          for (const { bot } of actors) await controllerCommand(controller, `/give ${bot.username} iron_pickaxe`, current, actionTimeoutMs)
        }
        await Promise.all(actors.map(async ({ bot, index }, actorIndex) => {
          const jobs = phase.action === 'chat'
            ? [phase.messages[actorIndex % phase.messages.length]]
            : phase.positions.filter((_, jobIndex) => jobIndex % actors.length === actorIndex)
          for (const job of jobs) {
            await bounded(`${bot.username} ${phase.action}`, actionTimeoutMs, current, async (jobSignal) => {
              let details = {}
              if (phase.action === 'chat') {
                const message = job.replaceAll('{bot}', bot.username).replaceAll('{index}', String(index + 1)).replaceAll('{phase}', String(phaseIndex + 1))
                await pause(actorIndex * 250, jobSignal)
                await sendChat(bot, controller, message, jobSignal)
                details = { message }
              } else {
                const position = point(job)
                details = { position }
                switch (phase.action) {
                  case 'teleport':
                    await controllerCommand(controller, `/tp ${bot.username} ${position.x + 0.5} ${position.y} ${position.z + 0.5}`, jobSignal, actionTimeoutMs)
                    await until(() => bot.entity.position.distanceTo(position.offset(0.5, 0, 0.5)) < 1, jobSignal, 'teleport arrival')
                    break
                  case 'walk': await walkTo(bot, position, jobSignal); break
                  case 'circle': {
                    const movement = createScenarioActions({ bot, signal: jobSignal })
                    details = { ...details, ...await movement.walkCircle({ center: position, radius: phase.radius, laps: phase.laps, clockwise: phase.clockwise, timeoutMs: actionTimeoutMs }) }
                    break
                  }
                  case 'interact': details = { ...details, ...await interact(bot, position, jobSignal) }; break
                  case 'mine': await mineBlock({ bot, observer: controller, position, signal: jobSignal, timeoutMs: actionTimeoutMs }); break
                  case 'build': await buildBlock({ bot, observer: controller, position, blockName: phase.block, signal: jobSignal, timeoutMs: actionTimeoutMs }); break
                }
              }
              record({ bot: bot.username, index, action: phase.action, phase: phaseIndex + 1, status: 'passed', ...details })
            })
          }
        }))
      }
      record({ action: 'phase', phase: phaseIndex + 1, status: 'passed', task: phase.action })
      if (chat && phase.action !== 'chat' && performance.now() - lastProgressChat >= 5000) {
        const { bot, index } = actors[0]
        const message = `${bot.username}: phase ${phaseIndex + 1} complete; all assigned workers are ready.`
        await bounded('Phase progress chat', actionTimeoutMs, current, (chatSignal) => sendChat(bot, controller, message, chatSignal))
        record({ bot: bot.username, index, action: 'chat', phase: phaseIndex + 1, status: 'passed', message })
        lastProgressChat = performance.now()
      }
    }
  })
}
