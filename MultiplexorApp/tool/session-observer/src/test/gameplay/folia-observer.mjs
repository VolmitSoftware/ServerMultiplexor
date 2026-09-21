import { readFile } from 'node:fs/promises'
import path from 'node:path'

export default {
  name: 'folia-observer',
  description: 'Verify region-owned player sampling, world changes, and unavailable global tick metrics.',
  async run(context) {
    const logPath = path.join(context.server.directory, 'logs', 'latest.log')
    const before = await readFile(logPath, 'utf8')
    const primary = context.bot.username
    const observer = await context.connectActor('FoliaObserver2')
    const player = (snapshot, username) => snapshot.players.find((entry) => entry.username === username)
    let initial
    await context.step('two entity schedulers publish player membership', async () => {
      await context.waitUntil(async () => {
        initial = await context.observe()
        return player(initial, primary) && player(initial, observer.bot.username)
      }, { timeoutMs: 20000, intervalMs: 250, label: 'both Folia player observations' })
      context.expect(initial.platform === 'folia', 'Expected Folia runtime')
      context.expect(initial.tick === null && initial.capabilities.globalTickTimings === false &&
        initial.capabilities.regionTickTimings === false, 'Folia must not publish fabricated tick metrics')
      context.expect(initial.worlds.every((world) => world.loadedChunks === null && world.entities === null),
        'Folia must not scan region-owned chunks/entities globally')
      context.expect(initial.process.heapUsedBytes > 0, 'Missing JVM measurements')
    })
    await context.step('separate regions retain independent player samples', async () => {
      await context.command(`/gamemode creative ${observer.bot.username}`, /game mode|gamemode/, 10000)
      await context.command(`/gamemode creative ${primary}`, /game mode|gamemode/, 10000)
      await context.command(`/tp ${observer.bot.username} 4096 200 4096`, /Teleported/, 10000)
      await context.waitUntil(async () => {
        const sample = player(await context.observe(), observer.bot.username)
        return sample?.chunkX === 256 && sample?.chunkZ === 256
      }, { timeoutMs: 25000, intervalMs: 250, label: 'remote entity scheduler sample' })
    })
    await context.step('world change updates authoritative UUID and event stream', async () => {
      const source = player(initial, primary).world
      const destination = initial.worlds.find((world) => world.id !== source && ['NORMAL', 'NETHER'].includes(world.dimension))
      context.expect(destination, 'Missing Nether world')
      await context.transition(() => context.bot.chat(`/execute in minecraft:${destination.dimension === 'NETHER' ? 'the_nether' : 'overworld'} run tp @s 0 90 0`),
        { worldId: destination.id, timeoutMs: 30000 })
      const snapshot = await context.observe()
      context.expect(player(snapshot, primary)?.world === destination.id, 'Wrong observed destination world')
      context.expect(snapshot.events.some((event) => event.type === 'world-change' &&
        event.username === primary && event.world === destination.id), 'Missing world-change event')
      context.expect(snapshot.worlds.some((world) => world.chunkLoads > 0), 'Missing chunk event counters')
      context.report.observer = snapshot
    })
    await context.step('runtime reports no scheduler ownership errors', async () => {
      const after = await readFile(logPath, 'utf8')
      context.expect(after.startsWith(before), 'Runtime log rotated during observer scenario')
      const errors = after.slice(before.length).split('\n').filter((line) =>
        /\bERROR\b|Exception:|thread check failed|not owned by|Cannot read world asynchronously/.test(line))
      context.expect(errors.length === 0, 'Folia observer runtime errors', { errors })
    })
  }
}
