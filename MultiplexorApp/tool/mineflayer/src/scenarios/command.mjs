export default {
  name: 'command',
  description: 'Issue a command and require a matching protocol-visible response.',
  async run(context) {
    const command = context.options.command
    const expected = context.options.expect
    context.expect(command !== undefined && command.trim() !== '', '--command is required')
    context.expect(expected !== undefined && expected.trim() !== '', '--expect is required')

    await context.step(`run ${command}`, async () => {
      const response = await context.command(
        command,
        new RegExp(expected, 'i'),
        context.options.assertionTimeoutMs
      )
      context.expect(response !== undefined, `No response matched /${expected}/i`)
    })
  }
}
