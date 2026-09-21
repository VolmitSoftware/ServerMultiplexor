import { readFile, readdir, stat } from 'node:fs/promises'
import path from 'node:path'
import { fileURLToPath } from 'node:url'

export function coverageMatrix(manifest, reports) {
  if (manifest.schemaVersion !== 1 || !Array.isArray(manifest.features)) throw new Error('Invalid coverage manifest')
  const ids = new Set()
  return manifest.features.map((feature) => {
    if (typeof feature.id !== 'string' || ids.has(feature.id)) throw new Error('Coverage IDs must be unique strings')
    ids.add(feature.id)
    if (feature.unsupported) return { id: feature.id, status: 'unsupported', reason: feature.unsupported, runs: [] }
    const matching = reports.filter((report) => report.scenario?.name === feature.scenario &&
      Object.entries(feature.match ?? {}).every(([key, value]) => key.split('.').reduce((parent, part) => parent?.[part], report) === value) &&
      ['passed', 'failed'].includes(report.status) && Number.isFinite(Date.parse(report.finishedAt)))
    const versions = new Map()
    for (const report of matching.sort((a, b) => Date.parse(a.finishedAt) - Date.parse(b.finishedAt))) {
      const build = { minecraft: report.server?.minecraftVersion ?? report.bot?.version ?? 'unknown', server: report.bot?.serverBrand ?? 'unknown', plugins: report.plugins ?? null }
      const key = JSON.stringify(build)
      versions.set(key, { ...build, status: report.status, finishedAt: report.finishedAt, artifact: report.artifact, errors: report.errors ?? [] })
    }
    const runs = [...versions.values()]
    return { id: feature.id, scenario: feature.scenario, status: runs.length ? (runs.some((run) => run.status === 'failed') ? 'failed' : 'passed') : 'untested', runs }
  })
}

export async function readGameplayReports(directory) {
  const reports = []
  let files = 0
  async function visit(folder) {
    for (const entry of await readdir(folder, { withFileTypes: true })) {
      const filename = path.join(folder, entry.name)
      if (entry.isDirectory()) await visit(filename)
      else if (entry.isFile() && entry.name.endsWith('.json')) {
        if (++files > 10000) throw new Error('Report folder exceeds 10000 JSON files; select a narrower folder')
        if ((await stat(filename)).size > 16 * 1024 * 1024) continue
        let value
        try { value = JSON.parse(await readFile(filename, 'utf8')) }
        catch (error) { if (error instanceof SyntaxError) continue; throw error }
        if (value.schemaVersion === 1 && value.scenario?.name) reports.push({ ...value, artifact: filename })
      }
    }
  }
  await visit(directory)
  return reports
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  try {
    const [directory, manifestFile] = process.argv.slice(2)
    if (!directory) throw new Error('Usage: node src/coverage.mjs <report-directory> [manifest.json]')
    const manifest = JSON.parse(await readFile(manifestFile ?? new URL('../suites/volmit.json', import.meta.url), 'utf8'))
    const features = coverageMatrix(manifest, await readGameplayReports(directory))
    process.stdout.write(`${JSON.stringify({ schemaVersion: 1, generatedAt: new Date().toISOString(), features }, null, 2)}\n`)
  } catch (error) { process.stderr.write(`${error.message}\n`); process.exitCode = 1 }
}
