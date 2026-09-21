import test from 'node:test'
import assert from 'node:assert/strict'
import { coverageMatrix } from '../src/coverage.mjs'

test('coverage preserves failures by build and never treats missing phases as passed', () => {
  const manifest = { schemaVersion: 1, features: [
    { id: 'studio', scenario: 'iris', match: { 'iris.phase': 'studio' } },
    { id: 'world', scenario: 'iris', match: { 'iris.phase': 'world' } },
    { id: 'pixels', unsupported: 'Needs a real client' }
  ] }
  const report = { scenario: { name: 'iris' }, iris: { phase: 'studio' }, server: { minecraftVersion: '26.1.2' }, bot: { serverBrand: 'Paper' } }
  const results = coverageMatrix(manifest, [
    { ...report, status: 'failed', finishedAt: '2026-09-20T10:00:00Z', plugins: [{ sha256: 'broken' }] },
    { ...report, status: 'failed', finishedAt: '2026-09-20T11:00:00Z', plugins: [{ sha256: 'fixed' }] },
    { ...report, status: 'passed', finishedAt: '2026-09-20T12:00:00Z', plugins: [{ sha256: 'fixed' }] }
  ])
  assert.equal(results[0].status, 'failed')
  assert.equal(results[0].runs.length, 2)
  assert.equal(results[0].runs[1].status, 'passed')
  assert.equal(results[1].status, 'untested')
  assert.equal(results[2].status, 'unsupported')
})
