import minecraftData from 'minecraft-data'

export function particleProtocol(version) {
  if (version === undefined || version === false) return undefined
  const data = minecraftData(version)
  if (!data || !['1.21.11', '26.1'].includes(data.version.minecraftVersion)) return undefined
  const particle = data.protocol.types.Particle
  const dust = particle?.[1]?.find(field => field.name === 'data')?.type?.[1]?.fields?.dust
  if (dust?.[0] !== 'container' || dust[1]?.length !== 4
    || !['red', 'green', 'blue', 'scale'].every((name, index) => dust[1][index]?.name === name && dust[1][index]?.type === 'f32')) return undefined
  const corrected = structuredClone(particle)
  corrected[1].find(field => field.name === 'data').type[1].fields.dust = 'packedDustParticle'
  return {
    [data.version.majorVersion]: {
      types: {
        Particle: corrected,
        packedDustParticle: ['container', [{ name: 'color', type: 'i32' }, { name: 'scale', type: 'f32' }]]
      }
    }
  }
}
