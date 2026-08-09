export class ScenarioAssertionError extends Error {
  constructor(message, details) {
    super(message)
    this.name = 'ScenarioAssertionError'
    this.details = details
  }
}

export function createScenarioContext({ bot, report, options, output }) {
  const expect = (condition, message, details = undefined) => {
    if (!condition) {
      throw new ScenarioAssertionError(message, details)
    }
  }

  const step = async (name, action) => {
    const entry = {
      name,
      status: 'running',
      startedAt: new Date().toISOString()
    }
    report.steps.push(entry)
    output(`[STEP] ${name}`)
    const started = performance.now()
    try {
      const value = await action()
      entry.status = 'passed'
      entry.durationMs = Math.round(performance.now() - started)
      return value
    } catch (error) {
      entry.status = 'failed'
      entry.durationMs = Math.round(performance.now() - started)
      entry.error = errorMessage(error)
      throw error
    }
  }

  const waitForEvent = (event, predicate = () => true, timeoutMs = 5000) =>
    new Promise((resolve, reject) => {
      let timer
      const listener = (...args) => {
        let matches = false
        try {
          matches = predicate(...args)
        } catch (error) {
          cleanup()
          reject(error)
          return
        }
        if (!matches) {
          return
        }
        cleanup()
        resolve(args)
      }
      const cleanup = () => {
        clearTimeout(timer)
        bot.removeListener(event, listener)
      }
      timer = setTimeout(() => {
        cleanup()
        reject(new Error(`Timed out waiting for ${event} after ${timeoutMs}ms`))
      }, timeoutMs)
      bot.on(event, listener)
    })

  const waitForMessage = (pattern, timeoutMs = 5000) => {
    const matcher = pattern instanceof RegExp
      ? (message) => pattern.test(message)
      : (message) => message.includes(String(pattern))
    return waitForEvent('messagestr', matcher, timeoutMs).then(([message]) => message)
  }

  const command = async (text, expected, timeoutMs = 5000) => {
    const response = expected === undefined
      ? undefined
      : waitForMessage(expected, timeoutMs)
    bot.chat(text)
    return response === undefined ? undefined : response
  }

  return {
    bot,
    command,
    expect,
    options,
    report,
    server: report.server,
    sleep: (milliseconds) => new Promise((resolve) => setTimeout(resolve, milliseconds)),
    step,
    waitForEvent,
    waitForMessage
  }
}

export function withTimeout(promise, timeoutMs, label) {
  return new Promise((resolve, reject) => {
    const timer = setTimeout(
      () => reject(new Error(`${label} timed out after ${timeoutMs}ms`)),
      timeoutMs
    )
    promise.then(
      (value) => {
        clearTimeout(timer)
        resolve(value)
      },
      (error) => {
        clearTimeout(timer)
        reject(error)
      }
    )
  })
}

export function errorMessage(error) {
  if (error instanceof Error) {
    return error.message
  }
  return String(error)
}
