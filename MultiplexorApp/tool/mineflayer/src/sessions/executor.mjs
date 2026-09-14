import { bounded, cancelBot, sessionError } from './transport.mjs'

export async function executeBounded(operation, { bot, signal, timeoutMs, settleMs = 5000, assertCurrent = () => {} }) {
  const abort = new AbortController()
  const current = signal ? AbortSignal.any([signal, abort.signal]) : abort.signal
  let settled = false
  const pending = Promise.resolve().then(() => operation(current)).finally(() => { settled = true })
  pending.catch(() => {})
  try {
    const result = await bounded(pending, timeoutMs, 'Session operation', current)
    current.throwIfAborted()
    assertCurrent()
    return result
  } catch (error) {
    abort.abort(error)
    cancelBot(bot)
    if (!settled) {
      try { await bounded(pending.catch(() => {}), settleMs, 'Session operation cancellation') } catch {
        const failure = sessionError('An action did not settle after cancellation; run stopped before reassigning its work', 'invariant')
        failure.cause = error
        throw failure
      }
    }
    throw error
  } finally {
    if (!abort.signal.aborted) abort.abort(sessionError('Operation finished', 'fenced'))
  }
}
