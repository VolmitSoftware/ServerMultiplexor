import AStar from 'mineflayer-pathfinder/lib/astar.js'

let installed = false

export function stabilizeCollisionBounds(bot) {
  // Upstream pathfinder PR #364 avoids exact block-edge contact in 1.21.x collision sweeps.
  if (/^1\.21(?:\.|$)/.test(bot.version) && bot.physics?.playerHalfWidth === 0.3) {
    bot.physics.playerHalfWidth = 0.30001
    if (bot.physics.playerHeight === 1.8) bot.physics.playerHeight = 1.80001
  }
}

export function preserveSearchNodes() {
  if (installed) return
  const makeResult = AStar.prototype.makeResult
  // Pinned pathfinder 2.4.5 converts result nodes to block-center coordinates in place.
  // Partial searches reuse those nodes; copy the result before its rendering pass changes them.
  AStar.prototype.makeResult = function (...arguments_) {
    const result = makeResult.apply(this, arguments_)
    result.path = result.path.map((node) => Object.assign(Object.create(Object.getPrototypeOf(node)), node, {
      toBreak: node.toBreak.map((block) => ({ ...block })),
      toPlace: node.toPlace.map((block) => ({ ...block }))
    }))
    return result
  }
  installed = true
}
