import { access, readdir } from 'node:fs/promises'
import path from 'node:path'
import { fileURLToPath, pathToFileURL } from 'node:url'

const scenariosDirectory = path.join(
  path.dirname(fileURLToPath(import.meta.url)),
  'scenarios'
)

export async function listScenarios() {
  const entries = await readdir(scenariosDirectory, { withFileTypes: true })
  const scenarios = []
  for (const entry of entries) {
    if (!entry.isFile() || !entry.name.endsWith('.mjs')) {
      continue
    }
    const loaded = await import(pathToFileURL(path.join(scenariosDirectory, entry.name)))
    validateScenario(loaded.default, entry.name)
    scenarios.push({
      name: loaded.default.name,
      description: loaded.default.description
    })
  }
  return scenarios.sort((left, right) => left.name.localeCompare(right.name))
}

export async function loadScenario(reference) {
  const builtInPath = path.join(scenariosDirectory, `${reference}.mjs`)
  let scenarioPath = builtInPath
  try {
    await access(builtInPath)
  } catch {
    scenarioPath = path.resolve(reference)
    await access(scenarioPath)
  }

  const loaded = await import(`${pathToFileURL(scenarioPath).href}?run=${Date.now()}`)
  validateScenario(loaded.default, reference)
  return { scenario: loaded.default, path: scenarioPath }
}

function validateScenario(scenario, reference) {
  if (scenario === null || typeof scenario !== 'object') {
    throw new Error(`Scenario ${reference} must default-export an object`)
  }
  if (typeof scenario.name !== 'string' || scenario.name.trim() === '') {
    throw new Error(`Scenario ${reference} must declare a name`)
  }
  if (typeof scenario.description !== 'string' || scenario.description.trim() === '') {
    throw new Error(`Scenario ${reference} must declare a description`)
  }
  if (typeof scenario.run !== 'function') {
    throw new Error(`Scenario ${reference} must declare an async run(context) function`)
  }
}
