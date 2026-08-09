export default {
  name: 'effect',
  description: 'Optionally issue a command, then require a named status effect on the bot.',
  async run(context) {
    const effectName = context.options.effect?.toLowerCase()
    context.expect(effectName !== undefined && effectName !== '', '--effect is required')
    const effect = resolveEffect(context.bot.registry.effectsByName, effectName)
    context.expect(effect !== undefined, `Unknown effect for this Minecraft version: ${effectName}`)

    await context.step(`observe ${effectName} effect`, async () => {
      const current = context.bot.entity.effects?.[effect.id]
      if (current !== undefined) {
        return
      }
      const pending = context.waitForEvent(
        'entityEffect',
        (entity, applied) => entity === context.bot.entity && applied.id === effect.id,
        context.options.assertionTimeoutMs
      )
      if (context.options.command !== undefined) {
        context.bot.chat(context.options.command)
      }
      await pending
      context.expect(
        context.bot.entity.effects?.[effect.id] !== undefined,
        `${effectName} event fired but the effect is absent from player state`
      )
    })
  }
}

export function resolveEffect(effectsByName, requestedName) {
  const normalized = requestedName.toLowerCase().replaceAll(/[^a-z0-9]/g, '')
  return Object.entries(effectsByName)
    .find(([name]) => name.toLowerCase().replaceAll(/[^a-z0-9]/g, '') === normalized)?.[1]
}
