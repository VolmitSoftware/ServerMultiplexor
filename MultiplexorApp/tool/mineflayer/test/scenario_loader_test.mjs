import assert from 'node:assert/strict'
import test from 'node:test'

import { listScenarios, loadScenario } from '../src/scenario_loader.mjs'

test('lists the built-in scenarios', async () => {
  const scenarios = await listScenarios()
  assert.deepEqual(
    scenarios.map((scenario) => scenario.name),
    ['command', 'connect', 'effect']
  )
})

test('loads a built-in scenario contract', async () => {
  const loaded = await loadScenario('connect')
  assert.equal(loaded.scenario.name, 'connect')
  assert.equal(typeof loaded.scenario.run, 'function')
})
