import test from 'node:test'
import assert from 'node:assert/strict'
import minecraftData from 'minecraft-data'
import serializer from 'minecraft-protocol/src/transforms/serializer.js'
import { particleProtocol } from '../src/particle_protocol.mjs'

test('dust override is limited to the proven outdated schema without mutating source data', () => {
  const data = minecraftData('1.21.11')
  const original = structuredClone(data.protocol.types.Particle)
  const override = particleProtocol('1.21.11')
  assert.equal(override['1.21'].types.Particle[1][1].type[1].fields.dust, 'packedDustParticle')
  assert.deepEqual(data.protocol.types.Particle, original)
  assert.equal(particleProtocol('1.20.1'), undefined)
  assert.equal(particleProtocol(undefined), undefined)
  const dust = data.protocol.types.Particle[1][1].type[1].fields
  const before = dust.dust
  try {
    dust.dust = ['container', [{ name: 'color', type: 'i32' }, { name: 'scale', type: 'f32' }]]
    assert.equal(particleProtocol('1.21.11'), undefined)
  } finally { dust.dust = before }
})

for (const version of ['1.21.11', '26.1']) {
  test(`${version} decodes an independently encoded packed-color dust packet completely`, () => {
    const data = minecraftData(version)
    const packetMappings = data.protocol.play.toClient.types.packet[1][0].type[1].mappings
    const id = Number(Object.entries(packetMappings).find(([, name]) => name === 'world_particles')[0])
    const particleMappings = data.protocol.types.Particle[1][0].type[1].mappings
    const dustId = Number(Object.entries(particleMappings).find(([, name]) => name === 'dust')[0])
    assert.ok(id < 128 && dustId < 128)
    const packet = Buffer.alloc(56)
    packet.writeUInt8(id, 0)
    packet.writeUInt8(0, 1)
    packet.writeUInt8(0, 2)
    packet.writeDoubleBE(14000.5, 3)
    packet.writeDoubleBE(120.15, 11)
    packet.writeDoubleBE(-14000.5, 19)
    packet.writeInt32BE(1, 43)
    packet.writeUInt8(dustId, 47)
    packet.writeInt32BE(0xd58a58, 48)
    packet.writeFloatBE(1.1, 52)
    const parser = serializer.createDeserializer({ state: 'play', isServer: false, version, customPackets: particleProtocol(version) })
    const decoded = parser.proto.parsePacketBuffer('packet', packet)
    assert.equal(decoded.metadata.size, packet.length)
    assert.equal(decoded.data.name, 'world_particles')
    assert.equal(decoded.data.params.x, 14000.5)
    assert.equal(decoded.data.params.y, 120.15)
    assert.equal(decoded.data.params.z, -14000.5)
    assert.equal(decoded.data.params.particle.type, 'dust')
    assert.equal(decoded.data.params.particle.data.color, 0xd58a58)
    assert.ok(Math.abs(decoded.data.params.particle.data.scale - 1.1) < 0.00001)
  })
}
