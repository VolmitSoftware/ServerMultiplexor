export default {
  name: 'connect',
  description: 'Connect, spawn, validate basic player state, and disconnect cleanly.',
  async run(context) {
    await context.step('validate spawned player state', async () => {
      const position = context.bot.entity?.position
      context.expect(position !== undefined, 'Bot has no spawned entity position')
      context.expect(Number.isFinite(position.x), 'Bot X position is not finite', position)
      context.expect(Number.isFinite(position.y), 'Bot Y position is not finite', position)
      context.expect(Number.isFinite(position.z), 'Bot Z position is not finite', position)
      context.expect(Number.isFinite(context.bot.health), 'Bot health is not finite')
      context.expect(context.bot.health > 0, 'Bot spawned without positive health')
      context.expect(context.bot.username.length > 0, 'Bot username is empty')
    })
    await context.step('observe stable connection', async () => {
      await context.sleep(500)
      context.expect(context.bot.player !== undefined, 'Bot player record disappeared')
    })
  }
}
