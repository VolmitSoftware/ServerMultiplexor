import assert from 'node:assert/strict'
import test from 'node:test'

import { parseArguments, positiveInteger } from '../src/arguments.mjs'

test('parses options, flags, and positionals', () => {
  const parsed = parseArguments([
    'run',
    'connect',
    '--port',
    '25565',
    '--json',
    '--username=VolmitQA'
  ])

  assert.deepEqual(parsed.positionals, ['run', 'connect'])
  assert.equal(parsed.option('port'), '25565')
  assert.equal(parsed.option('username'), 'VolmitQA')
  assert.equal(parsed.flag('json'), true)
})

test('positiveInteger rejects invalid values', () => {
  assert.equal(positiveInteger(undefined, 30, '--timeout'), 30)
  assert.equal(positiveInteger('12', 30, '--timeout'), 12)
  assert.throws(() => positiveInteger('0', 30, '--timeout'), /positive integer/)
  assert.throws(() => positiveInteger('nope', 30, '--timeout'), /positive integer/)
})
