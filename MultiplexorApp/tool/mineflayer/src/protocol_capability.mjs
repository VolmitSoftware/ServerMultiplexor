import { createRequire } from 'node:module'

const require = createRequire(import.meta.url)

export async function protocolCapability(version, dependencies) {
  if (typeof version !== 'string' || !/^[0-9][0-9A-Za-z._-]{0,63}$/.test(version)) {
    throw new Error('--version requires one Minecraft version, such as 26.1.2')
  }
  const result = {
    requestedVersion: version,
    status: 'unsupported',
    scope: 'Offline data and codec checks only; joining and gameplay remain unverified.',
    packages: {},
    dependencyFailure: false,
    dataAvailable: false,
    resolvedVersion: null,
    protocolVersion: null,
    mineflayerTested: false,
    codecs: [],
    errors: []
  }
  let phase = 'dependency loading'
  try {
    const layers = dependencies ?? {
      data: require('minecraft-data'),
      mineflayer: require('mineflayer'),
      protocol: require('minecraft-protocol'),
      packets: (await import('./particle_protocol.mjs')).particleProtocol,
      packages: Object.fromEntries(['mineflayer', 'minecraft-data', 'minecraft-protocol'].map(name => [name, require(`${name}/package.json`).version]))
    }
    result.packages = layers.packages ?? {}
    if (typeof layers.data !== 'function' || typeof layers.packets !== 'function'
      || !Array.isArray(layers.mineflayer?.testedVersions)
      || typeof layers.protocol?.createSerializer !== 'function' || typeof layers.protocol?.createDeserializer !== 'function') {
      throw new Error('Minecraft data, Mineflayer or protocol dependency API is unavailable')
    }
    phase = 'minecraft-data lookup'
    const data = layers.data(version)
    if (!data) {
      result.errors.push(`minecraft-data has no usable data for ${version}`)
      return result
    }
    phase = 'protocol override loading'
    const customPackets = layers.packets(version)
    phase = 'protocol capability inspection'
    return inspectCapability(result, data, layers, customPackets)
  } catch (error) {
    result.dependencyFailure = true
    result.errors.push(`${phase}: ${error.message}`)
    return result
  }
}

function inspectCapability(result, data, layers, customPackets) {
  result.dataAvailable = Boolean(data.protocol && data.blocks && data.items && data.entities)
  result.resolvedVersion = data.version.minecraftVersion
  result.protocolVersion = data.version.version
  result.mineflayerTested = layers.mineflayer.testedVersions.includes(result.resolvedVersion)
  if (!result.dataAvailable) result.errors.push('Minecraft protocol, block, item or entity data is missing')
  if (!result.mineflayerTested) result.errors.push(`Mineflayer does not list ${result.resolvedVersion} as a tested version`)
  const states = ['handshaking', 'status', 'login', 'play']
  if (data.protocol?.configuration) states.splice(3, 0, 'configuration')
  for (const state of states) {
    for (const direction of ['toServer', 'toClient']) {
      try {
        if (!data.protocol?.[state]?.[direction]) throw new Error('Protocol state or direction is missing')
        const options = { state, version: result.requestedVersion, isServer: false, customPackets }
        const codec = direction === 'toServer' ? layers.protocol.createSerializer(options) : layers.protocol.createDeserializer(options)
        codec.destroy()
        result.codecs.push({ state, direction, status: 'passed' })
      } catch (error) {
        result.codecs.push({ state, direction, status: 'failed', error: error.message })
        result.errors.push(`${state}.${direction}: ${error.message}`)
      }
    }
  }
  if (result.errors.length === 0) result.status = 'supported'
  return result
}
