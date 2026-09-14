import { Vec3 } from 'vec3'

function point(value) { return new Vec3(value.x ?? value[0], value.y ?? value[1], value.z ?? value[2]) }

const workerBounds = new WeakMap()

export function containsBlock(bounds, value) {
  const position = point(value)
  return [position.x, position.y, position.z].every((coordinate, axis) =>
    Number.isFinite(coordinate) && coordinate >= bounds.min[axis] && coordinate <= bounds.max[axis])
}

export function containsWorker(bounds, value) {
  if (!value) return false
  const position = point(value)
  return Number.isFinite(position.x) && Number.isFinite(position.y) && Number.isFinite(position.z) &&
    position.x - 0.3 >= bounds.min[0] && position.x + 0.3 <= bounds.max[0] + 1 &&
    position.z - 0.3 >= bounds.min[2] && position.z + 0.3 <= bounds.max[2] + 1 &&
    position.y >= bounds.min[1] - 0.01 && position.y + 1.8 <= bounds.max[1] + 1
}

export function assertWorkerBounds(bot) {
  const bounds = workerBounds.get(bot)
  if (bounds && !containsWorker(bounds, bot.entity?.position)) {
    const error = new Error(`${bot.username} left workload bounds at ${bot.entity?.position}`)
    error.fatal = true
    throw error
  }
}

export function assertTargetBounds(bot, position, { walking = false } = {}) {
  const bounds = workerBounds.get(bot)
  if (!bounds) return
  const target = point(position)
  if (!containsBlock(bounds, target) || (walking && !containsWorker(bounds, target.offset(0.5, 0, 0.5)))) {
    const error = new Error(`Target ${target} is outside workload bounds`)
    error.fatal = true
    throw error
  }
}

export function constrainWorker(bot, bounds) {
  workerBounds.set(bot, bounds)
  const movements = bot.pathfinder.movements
  if (!movements) throw new Error('Pathfinder movements are unavailable')
  const canStep = (block) => containsWorker(bounds, block.position.offset(0.5, 0, 0.5)) ? 0 : 100
  const canEdit = (block) => containsBlock(bounds, block.position) ? 0 : 100
  movements.exclusionAreasStep.push(canStep)
  movements.exclusionAreasBreak.push(canEdit)
  movements.exclusionAreasPlace.push(canEdit)
  movements.canDig = false
  movements.allow1by1towers = false
  movements.allowParkour = false
  movements.maxDropDown = 1
  movements.infiniteLiquidDropdownDistance = false
  bot.pathfinder.setMovements(movements)
  assertWorkerBounds(bot)
}
