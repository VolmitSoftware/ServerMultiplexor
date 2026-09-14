import { createHash, randomUUID } from 'node:crypto'
import { mkdir, open, readFile, rename, rm } from 'node:fs/promises'
import path from 'node:path'

export function processAlive(pid) {
  if (!Number.isInteger(pid) || pid < 1) return false
  try { process.kill(pid, 0); return true } catch (error) { return error.code === 'EPERM' }
}

export async function atomicJson(file, value) {
  const temporary = `${file}.${process.pid}.${randomUUID()}.tmp`
  let handle
  try {
    handle = await open(temporary, 'wx', 0o600)
    await handle.writeFile(`${JSON.stringify(value, null, 2)}\n`)
    await handle.sync()
    await handle.close()
    handle = undefined
    await rename(temporary, file)
  } finally {
    await handle?.close()
    await rm(temporary, { force: true })
  }
}

export async function createSessionStore(directory, { runId, fingerprint, resume = false }) {
  await mkdir(directory, { recursive: true })
  const lockPath = path.join(directory, 'node.lock')
  const ownership = { pid: process.pid, nonce: randomUUID(), runId }
  let lock
  try { lock = await open(lockPath, 'wx', 0o600) } catch (error) {
    if (error.code !== 'EEXIST') throw error
    let previous
    try { previous = JSON.parse(await readFile(lockPath, 'utf8')) } catch { throw new Error('Unreadable session lock; inspect node.lock before resuming') }
    if (processAlive(previous.pid)) throw new Error(`Session process ${previous.pid} is still alive`)
    await rm(lockPath)
    lock = await open(lockPath, 'wx', 0o600)
  }
  await lock.writeFile(JSON.stringify(ownership))
  await lock.close()
  let writing = Promise.resolve()
  let failure
  let pendingCheckpoint
  const store = {
    directory,
    async load() {
      const source = await readFile(path.join(directory, 'checkpoint.json'), 'utf8')
      if (source.length > 32 * 1024 * 1024) throw new Error('Session checkpoint exceeds 32 MiB')
      const { checksum, ...body } = JSON.parse(source)
      if (checksum !== digest(body)) throw new Error('Session checkpoint integrity check failed')
      if (body.schemaVersion !== 1 || body.runId !== runId || body.fingerprint !== fingerprint) throw new Error('Session checkpoint does not match this run, profile, and target')
      if (!Array.isArray(body.players) || !body.shared || typeof body.elapsedMs !== 'number' || body.elapsedMs < 0 || !Number.isFinite(body.elapsedMs)) throw new Error('Invalid session checkpoint state')
      return body
    },
    checkpoint(state) {
      if (failure) return Promise.reject(failure)
      if (pendingCheckpoint) { pendingCheckpoint.state = state; return pendingCheckpoint.promise }
      const pending = { state }
      pendingCheckpoint = pending
      pending.promise = writing.then(async () => {
        pendingCheckpoint = undefined
        const body = structuredClone({ ...pending.state, schemaVersion: 1, runId, fingerprint })
        if (Buffer.byteLength(JSON.stringify(body)) > 31 * 1024 * 1024) throw new Error('Session durable state exceeds the 31 MiB checkpoint budget')
        await atomicJson(path.join(directory, 'checkpoint.json'), { ...body, checksum: digest(body) })
      })
      writing = pending.promise
      writing.catch((error) => { failure = error })
      return writing
    },
    report(value) { return enqueue('report.json', structuredClone(value)) },
    status(value) { return enqueue('status.json', structuredClone(value)) },
    async stopRequested() {
      try { await readFile(path.join(directory, 'stop.request')); return true } catch (error) {
        if (error.code === 'ENOENT') return false
        throw error
      }
    },
    async close() {
      try { await writing } finally {
        const current = JSON.parse(await readFile(lockPath, 'utf8'))
        if (current.nonce === ownership.nonce) await rm(lockPath)
      }
      if (failure) throw failure
    }
  }
  function enqueue(name, value) {
    if (failure) return Promise.reject(failure)
    writing = writing.then(() => atomicJson(path.join(directory, name), value))
    writing.catch((error) => { failure = error })
    return writing
  }
  try {
    if (resume) await store.load()
    else {
      try { await readFile(path.join(directory, 'checkpoint.json')); throw new Error('Run already has a checkpoint; use resume or a new run ID') } catch (error) {
        if (error.code !== 'ENOENT') throw error
      }
    }
    return store
  } catch (error) {
    await store.close()
    throw error
  }
}

function digest(value) { return createHash('sha256').update(JSON.stringify(value)).digest('hex') }

export class SessionLeases {
  constructor({ now = Date.now, isOwnerLive = () => false } = {}) {
    this.now = now
    this.isOwnerLive = isOwnerLive
    this.leases = new Map()
    this.sequence = 0
  }

  acquire(key, owner, ttlMs = 60000) {
    if (typeof key !== 'string' || typeof owner !== 'string' || !Number.isFinite(ttlMs) || ttlMs <= 0) throw new Error('Invalid session lease')
    const previous = this.leases.get(key)
    if (previous && previous.owner !== owner && (previous.expiresAt > this.now() || this.isOwnerLive(previous.owner))) return undefined
    if (previous?.owner === owner) {
      previous.expiresAt = this.now() + ttlMs
      return previous
    }
    const lease = { key, owner, token: ++this.sequence, expiresAt: this.now() + ttlMs }
    this.leases.set(key, lease)
    return lease
  }

  assert(lease) {
    if (!lease || this.leases.get(lease.key)?.token !== lease.token || lease.expiresAt <= this.now()) throw new Error('Session lease expired or ownership changed')
  }

  renew(lease, ttlMs = 60000) { this.assert(lease); lease.expiresAt = this.now() + ttlMs }
  release(lease) { if (lease && this.leases.get(lease.key)?.token === lease.token) this.leases.delete(lease.key) }
  releaseOwner(owner) { for (const [key, lease] of this.leases) if (lease.owner === owner) this.leases.delete(key) }
  snapshot() { return [...this.leases.values()].map((lease) => ({ ...lease })) }
}
