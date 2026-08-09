export function parseArguments(tokens) {
  const options = new Map()
  const flags = new Set()
  const positionals = []

  for (let index = 0; index < tokens.length; index += 1) {
    const token = tokens[index]
    if (!token.startsWith('--')) {
      positionals.push(token)
      continue
    }

    const separator = token.indexOf('=')
    if (separator >= 0) {
      options.set(token.slice(2, separator), token.slice(separator + 1))
      continue
    }

    const name = token.slice(2)
    const next = tokens[index + 1]
    if (next !== undefined && !next.startsWith('--')) {
      options.set(name, next)
      index += 1
    } else {
      flags.add(name)
    }
  }

  return {
    flag: (name) => flags.has(name),
    option: (name) => options.get(name),
    positionals
  }
}

export function positiveInteger(value, fallback, name) {
  if (value === undefined) {
    return fallback
  }
  const parsed = Number.parseInt(value, 10)
  if (!Number.isInteger(parsed) || parsed < 1) {
    throw new Error(`${name} must be a positive integer`)
  }
  return parsed
}
