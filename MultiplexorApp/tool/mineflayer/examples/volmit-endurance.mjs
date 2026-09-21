import { readFile, stat, open } from 'node:fs/promises'
import path from 'node:path'
import { monitorEventLoopDelay, performance } from 'node:perf_hooks'
import { Vec3 } from 'vec3'
import { withTimeout } from '../src/scenario_context.mjs'

const warmupMs = 30_000
const measuredMs = 300_000
const recoveryMs = 20_000

async function logTail(filename, offset) {
  const handle = await open(filename, 'r')
  try {
    const size = (await handle.stat()).size
    if (size < offset || size - offset > 4 * 1024 * 1024) throw new Error('Server log rotated or exceeded the bounded soak log window')
    const bytes = Buffer.alloc(size - offset)
    await handle.read(bytes, 0, bytes.length, offset)
    return bytes.toString('utf8')
  } finally { await handle.close() }
}

function latency(values) {
  const sorted = [...values].sort((a, b) => a - b)
  const percentile = p => sorted[Math.min(sorted.length - 1, Math.floor(sorted.length * p))] ?? null
  return { count: sorted.length, p50Ms: percentile(.5), p95Ms: percentile(.95), maxMs: sorted.at(-1) ?? null }
}

export default {
  name: 'volmit-endurance',
  description: 'Five-minute four-player combined plugin soak with real movement, block work, attributed combat, and recovery telemetry.',
  async run(context) {
    const root = context.server.directory
    context.expect(typeof root === 'string' && /^isolated=true\s*$/m.test(await readFile(path.join(root, '.server-source'), 'utf8')), 'Combined soak requires an isolated managed instance')
    context.expect(/^server-ip=127\.0\.0\.1\s*$/m.test(await readFile(path.join(root, 'server.properties'), 'utf8')), 'Combined soak requires loopback')
    for (const plugin of ['Wormholes', 'Adapt', 'Gloss', 'React', 'HiddenOre']) {
      context.expect(context.report.plugins?.some(entry => entry.filename.startsWith(plugin)), `Missing required ${plugin} jar`)
      await context.command(`/version ${plugin}`, new RegExp(`${plugin} version`, 'i'), 10000)
    }
    const actors = []
    for (let index = 0; index < 4; index++) actors.push(await context.connectActor(`Soak${context.server.port}_${index}`))
    const setup = command => context.command(command, /filled|no blocks|teleported|game mode|effect|gave|removed|nothing changed|difficulty|gamerule|now set/i, 10000)
    await context.step('Provision one bounded arena before workload measurement', async () => {
      if (context.bot.game.gameMode !== 'spectator') await setup(`/gamemode spectator ${context.bot.username}`)
      await setup(`/tp ${context.bot.username} 0.5 183 0.5`)
      await context.waitUntil(() => context.bot.blockAt(new Vec3(-24, 180, -12)) && context.bot.blockAt(new Vec3(24, 185, 12)), { label: 'arena chunks', timeoutMs: 30000 })
      await setup('/fill -24 180 -12 24 180 12 stone')
      await setup('/fill -24 181 -12 24 185 12 air')
      await setup('/difficulty peaceful')
      const starts = [[-7.5, 0.5], [16.5, 0.5], [-2.5, 8.5], [-.5, 8.5]]
      for (let index = 0; index < actors.length; index++) {
        const actor = actors[index]
        await context.command(`/gamemode survival ${actor.bot.username}`)
        await context.command(`/clear ${actor.bot.username}`)
        await setup(`/tp ${actor.bot.username} ${starts[index][0]} 181 ${starts[index][1]}`)
        await setup(`/effect give ${actor.bot.username} regeneration 600 2 true`)
        await setup(`/effect give ${actor.bot.username} saturation 600 0 true`)
      }
      await setup(`/give ${actors[2].bot.username} cobblestone 64`)
      await setup(`/give ${actors[2].bot.username} iron_pickaxe 1`)
      for (const actor of actors.slice(2)) await setup(`/give ${actor.bot.username} iron_sword 1`)
      await context.waitUntil(async () => (await context.observe()).players.filter(player => actors.some(actor => actor.bot.username === player.username)).length === 4,
        { label: 'all ordinary workers observed', timeoutMs: 15000 })
    })
    const initial = await context.observe()
    const logFile = path.join(root, 'logs', 'latest.log')
    const logOffset = (await stat(logFile)).size
    const loopDelay = monitorEventLoopDelay({ resolution: 20 })
    loopDelay.enable()
    const evidence = context.report.endurance = {
      workers: actors.map(actor => actor.bot.username), warmupMs, measuredMs, recoveryMs,
      setup: 'One stone arena, survival workers, peaceful difficulty, regeneration III and saturation supplied once before warmup; one stack of cobblestone, one iron pickaxe, and two iron swords',
      limits: 'Short coexistence soak only; no capacity, memory-leak, rendering, or complete feature-coverage conclusion',
      samples: [], phases: {}, errors: []
    }
    let phase = 'warmup'
    let workerFailure
    let active = true
    const operations = { warmup: {}, measured: {}, drain: {} }
    const started = performance.now()
    let previousCpu = process.cpuUsage()
    let previousElu = performance.eventLoopUtilization()
    let previousSample = performance.now()
    const sample = async () => {
      const observed = await context.observe()
      context.expect(observed.processId === initial.processId, 'Server process changed during soak')
      const tail = await logTail(logFile, logOffset)
      const errors = tail.split('\n').filter(line => /\/(?:ERROR|SEVERE)\]|\b(?:Exception|Error)(?::| in thread)|^\s+at (?:art\.arcane|com\.volmit)\./.test(line))
      context.expect(errors.length === 0, 'New server exception during combined soak', { errors: errors.slice(0, 20) })
      const now = performance.now()
      const cpu = process.cpuUsage()
      const utilization = performance.eventLoopUtilization(previousElu)
      evidence.samples.push({ phase, elapsedMs: Math.round(now - started), serverObservedAt: observed.observedAt,
        server: { processId: observed.processId, process: observed.process, tick: observed.tick, worlds: observed.worlds.map(world => ({ id: world.id, name: world.name, loadedChunks: world.loadedChunks, players: world.players })) },
        node: { memory: process.memoryUsage(), resource: process.resourceUsage(), cpuPercentOneCore: 100 * ((cpu.user - previousCpu.user) + (cpu.system - previousCpu.system)) / ((now - previousSample) * 1000), eventLoopUtilization: utilization.utilization,
          eventLoopDelayP95Ms: loopDelay.percentile(95) / 1e6, eventLoopDelayMaxMs: loopDelay.max / 1e6 } })
      previousCpu = cpu
      previousElu = performance.eventLoopUtilization()
      previousSample = now
      loopDelay.reset()
    }
    const operation = async (kind, action) => {
      const ownerPhase = phase
      const before = performance.now()
      await withTimeout(Promise.resolve().then(action), 30000, `Soak ${kind}`, context.signal)
      if (ownerPhase === phase) (operations[phase][kind] ??= []).push(performance.now() - before)
    }
    const worker = action => (async () => {
      try { while (active) { context.signal.throwIfAborted(); await action() } }
      catch (error) { workerFailure ??= error; active = false; throw error }
    })()
    const placeAndMine = async () => {
      const actor = actors[2]
      const target = new Vec3(-3, 181, 9)
      const support = await actor.waitUntil(() => actor.bot.blockAt(target.offset(0, -1, 0)), { label: 'placement support' })
      const item = actor.bot.inventory.items().find(entry => entry.name === 'cobblestone')
      actor.expect(item, 'Builder exhausted its initial fixture stack')
      actor.expect(actor.bot.blockAt(target)?.name === 'air', 'Builder target is occupied')
      await actor.bot.equip(item, 'hand')
      await actor.bot.placeBlock(support, new Vec3(0, 1, 0))
      const placed = await actor.waitUntil(() => { const block = actor.bot.blockAt(target); return block?.name === 'cobblestone' ? block : false }, { label: 'server placement' })
      const pickaxe = actor.bot.inventory.items().find(entry => entry.name === 'iron_pickaxe')
      actor.expect(pickaxe, 'Builder lost its fixture pickaxe')
      await actor.bot.equip(pickaxe, 'hand')
      await actor.bot.dig(placed)
      await actor.waitUntil(() => actor.bot.blockAt(target)?.name === 'air', { label: 'server mining result' })
    }
    const workers = [
      worker(() => operation('circle', () => actors[0].actions.walkCircle({ center: { x: -11.5, y: 181, z: .5 }, radius: 4, timeoutMs: 30000 }))),
      worker(() => operation('circle', () => actors[1].actions.walkCircle({ center: { x: 12.5, y: 181, z: .5 }, radius: 4, timeoutMs: 30000 }))),
      worker(async () => {
        await Promise.all([
          actors[2].actions.walkRoute([{ x: -2.5, y: 181, z: 8.5 }]),
          actors[3].actions.walkRoute([{ x: -.5, y: 181, z: 8.5 }])
        ])
        await operation('placeAndMine', placeAndMine)
        for (const actor of actors.slice(2)) {
          const sword = actor.bot.inventory.items().find(item => item.name === 'iron_sword')
          actor.expect(sword, 'Combat worker lost its fixture sword')
          await actor.bot.equip(sword, 'hand')
        }
        await context.sleep(700)
        await operation('attributedHit', () => actors[2].actions.attackPlayer(actors[3].bot, { minimumHealth: 6, timeoutMs: 10000 }))
        await operation('attributedHit', () => actors[3].actions.attackPlayer(actors[2].bot, { minimumHealth: 6, timeoutMs: 10000 }))
        await context.sleep(2000)
      })
    ]
    workers.forEach(promise => promise.catch(() => {}))
    try {
      await context.step('Cold warmup, five-minute measured workload, and idle recovery', async () => {
        for (const [name, duration] of [['warmup', warmupMs], ['measured', measuredMs]]) {
          phase = name
          const until = performance.now() + duration
          do { if (workerFailure) throw workerFailure; await sample(); await context.sleep(Math.min(5000, Math.max(1, until - performance.now()))) } while (performance.now() < until)
          evidence.phases[name] = Object.fromEntries(Object.entries(operations[name]).map(([kind, values]) => [kind, latency(values)]))
        }
        active = false
        phase = 'drain'
        await withTimeout(Promise.all(workers), 35000, 'Worker drain', context.signal)
        if (workerFailure) throw workerFailure
        phase = 'recovery'
        for (const actor of actors) { actor.bot.pathfinder.setGoal(null); actor.bot.clearControlStates() }
        const until = performance.now() + recoveryMs
        do { await sample(); await context.sleep(Math.min(5000, Math.max(1, until - performance.now()))) } while (performance.now() < until)
        await sample()
        for (const kind of ['circle', 'placeAndMine', 'attributedHit']) context.expect(evidence.phases.measured[kind]?.count > 0, `No measured ${kind} operations`)
      })
    } catch (error) {
      evidence.errors.push({ message: error.message })
      throw error
    } finally {
      active = false
      for (const actor of actors) { actor.bot.pathfinder.setGoal(null); actor.bot.clearControlStates() }
      loopDelay.disable()
    }
  }
}
