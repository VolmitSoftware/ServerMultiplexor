import EventEmitter from 'node:events'
import { mkdir, rename, writeFile } from 'node:fs/promises'
import { createServer } from 'node:http'
import { createRequire } from 'node:module'
import path from 'node:path'

const LOOPBACK_ADDRESS = '127.0.0.1'

export async function startWebFeed({
  artifactsDirectory,
  bot,
  instance,
  notice,
  port,
  scenario
}) {
  const viewerPort = await startLoopbackViewer(bot, port)
  const url = `http://${LOOPBACK_ADDRESS}:${viewerPort}/`
  const stateFile = artifactsDirectory === undefined
    ? undefined
    : path.join(artifactsDirectory, `viewer-${viewerPort}.json`)
  const state = {
    enabled: true,
    status: 'active',
    url,
    port: viewerPort,
    bindAddress: LOOPBACK_ADDRESS,
    firstPerson: true,
    startedAt: new Date().toISOString(),
    stateFile
  }

  try {
    await writeState(stateFile, { ...state, instance, scenario })
  } catch (error) {
    await bot.viewer.close()
    throw error
  }
  notice(`[INFO] Web feed: ${url}`)
  return state
}

export async function stopWebFeed(bot, state, { instance, scenario }) {
  if (state?.enabled !== true) {
    return
  }
  await bot.viewer?.close?.()
  state.status = 'closed'
  state.closedAt = new Date().toISOString()
  await writeState(state.stateFile, { ...state, instance, scenario })
}

async function startLoopbackViewer(bot, requestedPort) {
  const require = createRequire(import.meta.url)
  const compression = require('compression')
  const express = require('express')
  const { Server: SocketServer } = require('socket.io')
  const { WorldView } = require('prismarine-viewer/viewer/lib/worldView')
  const packageDirectory = path.dirname(require.resolve('prismarine-viewer/package.json'))
  const app = express()
  app.use(compression())
  app.use('/', express.static(path.join(packageDirectory, 'public')))

  const httpServer = createServer(app)
  const io = new SocketServer(httpServer, { path: '/socket.io' })
  const sockets = new Set()
  const primitives = new Map()
  const viewer = new EventEmitter()
  bot.viewer = viewer

  viewer.erase = (id) => {
    primitives.delete(id)
    for (const socket of sockets) {
      socket.emit('primitive', { id })
    }
  }
  viewer.drawBoxGrid = (id, start, end, color = 'aqua') => {
    emitPrimitive({ type: 'boxgrid', id, start, end, color })
  }
  viewer.drawLine = (id, points, color = 0xff0000) => {
    emitPrimitive({ type: 'line', id, points, color })
  }
  viewer.drawPoints = (id, points, color = 0xff0000, size = 5) => {
    emitPrimitive({ type: 'points', id, points, color, size })
  }

  function emitPrimitive(primitive) {
    primitives.set(primitive.id, primitive)
    for (const socket of sockets) {
      socket.emit('primitive', primitive)
    }
  }

  io.on('connection', (socket) => {
    socket.emit('version', bot.version)
    sockets.add(socket)
    const worldView = new WorldView(bot.world, 6, bot.entity.position, socket)
    worldView.init(bot.entity.position)
    worldView.on('blockClicked', (block, face, button) => {
      viewer.emit('blockClicked', block, face, button)
    })
    for (const primitive of primitives.values()) {
      socket.emit('primitive', primitive)
    }

    const updatePosition = () => {
      socket.emit('position', {
        pos: bot.entity.position,
        yaw: bot.entity.yaw,
        pitch: bot.entity.pitch,
        addMesh: true
      })
      worldView.updatePosition(bot.entity.position)
    }
    bot.on('move', updatePosition)
    worldView.listenToBot(bot)
    socket.on('disconnect', () => {
      bot.removeListener('move', updatePosition)
      worldView.removeListenersFromBot(bot)
      sockets.delete(socket)
    })
  })

  const viewerPort = await listen(httpServer, requestedPort ?? 0)
  let closePromise
  viewer.close = () => {
    closePromise ??= new Promise((resolve) => {
      for (const socket of sockets) {
        socket.disconnect(true)
      }
      io.close(() => {
        if (!httpServer.listening) {
          resolve()
          return
        }
        httpServer.close(() => resolve())
      })
    })
    return closePromise
  }
  return viewerPort
}

function listen(server, port) {
  return new Promise((resolve, reject) => {
    const handleError = (error) => {
      server.removeListener('listening', handleListening)
      reject(error)
    }
    const handleListening = () => {
      server.removeListener('error', handleError)
      const address = server.address()
      if (typeof address !== 'object' || address === null) {
        reject(new Error('Unable to determine the web feed port'))
        return
      }
      resolve(address.port)
    }
    server.once('error', handleError)
    server.once('listening', handleListening)
    server.listen(port, LOOPBACK_ADDRESS)
  })
}

async function writeState(stateFile, state) {
  if (stateFile === undefined) {
    return
  }
  await mkdir(path.dirname(stateFile), { recursive: true })
  const temporaryFile = `${stateFile}.tmp`
  await writeFile(temporaryFile, `${JSON.stringify(state, null, 2)}\n`)
  await rename(temporaryFile, stateFile)
}
