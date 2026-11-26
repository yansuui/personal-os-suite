import { CloudStore } from './store.ts'
import { createV2Server } from './server.ts'

const adminSecret = process.env.V2_ADMIN_SECRET
if (!adminSecret) throw new Error('V2_ADMIN_SECRET is required.')

const portValue = process.env.PORT ?? '8787'
const port = Number(portValue)
if (!/^(0|[1-9]\d*)$/.test(portValue) || !Number.isSafeInteger(port) || port > 65_535) {
  throw new Error('PORT must be an integer between 0 and 65535.')
}
const dbPath = process.env.DB_PATH ?? './data/cloud.sqlite'
if (dbPath.trim().length === 0) throw new Error('DB_PATH must not be empty.')

const store = new CloudStore(dbPath)
const server = createV2Server({ store, adminSecret })
let stopping = false
let storeClosed = false

function closeStore(): void {
  if (storeClosed) return
  storeClosed = true
  store.close()
}

function shutdown(): void {
  if (stopping) return
  stopping = true
  const deadline = setTimeout(() => server.closeAllConnections(), 5_000)
  deadline.unref()
  server.close((error) => {
    clearTimeout(deadline)
    closeStore()
    if (error) {
      console.error('Failed to close cloud HTTP server:', error.message)
      process.exitCode = 1
    }
  })
  server.closeIdleConnections()
}

server.once('error', (error) => {
  console.error('Cloud HTTP server error:', error.message)
  if (server.listening) shutdown()
  else closeStore()
  process.exitCode = 1
})
process.once('SIGINT', shutdown)
process.once('SIGTERM', shutdown)

server.listen(port, '0.0.0.0', () => {
  const address = server.address()
  const boundPort = typeof address === 'object' && address ? address.port : port
  console.log(`Cloud v2 listening on port ${boundPort}`)
})
