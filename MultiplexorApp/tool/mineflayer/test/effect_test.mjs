import assert from 'node:assert/strict'
import test from 'node:test'

import { resolveEffect } from '../src/scenarios/effect.mjs'

test('resolves Minecraft effect names without case or separators', () => {
  const speed = { id: 1 }
  const fireResistance = { id: 12 }
  const effects = { Speed: speed, FireResistance: fireResistance }

  assert.equal(resolveEffect(effects, 'speed'), speed)
  assert.equal(resolveEffect(effects, 'fire_resistance'), fireResistance)
  assert.equal(resolveEffect(effects, 'Fire Resistance'), fireResistance)
  assert.equal(resolveEffect(effects, 'unknown'), undefined)
})
