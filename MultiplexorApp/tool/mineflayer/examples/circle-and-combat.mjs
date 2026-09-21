export default {
  name: 'circle-and-combat',
  description: 'Construct a disposable arena, verify a walking circuit, and exchange server-confirmed player damage.',
  async run(context) {
    const { bot } = context
    const peer = await context.connectActor(`MxPeer${context.server.port}`)
    const command = (text) => context.command(text, /filled|no blocks|teleported|game mode|effect|gave|removed|nothing changed/i, 10_000)
    await context.step('prepare the isolated arena and survival players', async () => {
      await command(`/gamemode spectator ${bot.username}`)
      await command(`/tp ${bot.username} 8.5 81 0.5`)
      await context.waitUntil(() => bot.blockAt(bot.entity.position.offset(-20, -1, -12)) && bot.blockAt(bot.entity.position.offset(4, -1, 12)), { label: 'arena chunks' })
      await command('/fill -12 80 -12 12 80 12 stone')
      await command('/fill -12 81 -12 12 85 12 air')
      for (const actor of [context, peer]) {
        if (actor.bot.game.gameMode !== 'survival') await command(`/gamemode survival ${actor.bot.username}`)
        await command(`/effect give ${actor.bot.username} instant_health 1 10`)
        await command(`/effect give ${actor.bot.username} saturation 1 10`)
      }
      await command(`/tp ${bot.username} 8.5 81 0.5`)
      await command(`/tp ${peer.bot.username} 11.5 81 0.5`)
      await context.waitUntil(() => bot.entity.position.y === 81 && peer.bot.entity.position.y === 81, { label: 'arena arrival' })
    })
    await context.step('walk an observed complete circle', () => context.actions.walkCircle({ center: { x: 0.5, y: 81, z: 0.5 }, radius: 8, laps: 1 }))
    await context.step('exchange player combat damage', async () => {
      await command(`/tp ${bot.username} 0.5 81 0.5`)
      await command(`/tp ${peer.bot.username} 2.5 81 0.5`)
      await context.waitUntil(() => bot.entity.position.distanceTo(peer.bot.entity.position) < 3, { label: 'combat positions' })
      await bot.unequip('hand')
      await peer.bot.unequip('hand')
      const outgoing = await context.actions.attackPlayer(peer.bot, { hits: 2 })
      const incoming = await peer.actions.attackPlayer(bot, { hits: 2 })
      context.expect([outgoing, incoming].every((result) => result.confirmedHits === 2 && result.damage.every((hit) => hit.amount > 0)), 'Both players must receive actual damage')
    })
  }
}
