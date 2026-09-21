export default {
  name: 'circle',
  description: 'Walk an eight-block-radius circuit beside spawn and verify the observed full lap.',
  async run(context) {
    const start = context.bot.entity.position
    await context.step('walk and verify one complete circle', () => context.actions.walkCircle({
      center: { x: start.x - 8, y: start.y, z: start.z }, radius: 8, laps: 1
    }))
  }
}
