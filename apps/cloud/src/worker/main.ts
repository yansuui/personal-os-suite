import { setTimeout as delay } from 'node:timers/promises'
import { ChatWorker, WorkerError } from './index.ts'
import { configFromEnvironment } from './config.ts'

async function main(): Promise<void> {
  const config = configFromEnvironment()
  const worker = new ChatWorker(config)
  const stopped = new AbortController()
  const shutdown = () => {
    stopped.abort()
    worker.shutdown()
  }
  process.once('SIGINT', shutdown)
  process.once('SIGTERM', shutdown)
  let backoff = config.pollIntervalMs
  console.log(JSON.stringify({ event: 'worker_started' }))
  try {
    while (!stopped.signal.aborted) {
      let wait = config.pollIntervalMs
      try {
        const result = await worker.processNextRun(stopped.signal)
        backoff = config.pollIntervalMs
        if (result.status === 'stopped') break
        if (result.status !== 'idle') {
          console.log(JSON.stringify({ event: 'run_processed', ...result }))
          if (result.status === 'completed' || result.status === 'failed') wait = 0
        }
      } catch (error) {
        if (stopped.signal.aborted) break
        const code = error instanceof WorkerError ? error.code : 'worker_failed'
        console.error(JSON.stringify({ event: 'worker_error', code }))
        if (error instanceof WorkerError && (error.status === 401 || error.status === 403 ||
            ['incompatible_server', 'agent_required', 'invalid_config', 'invalid_lease_budget'].includes(code))) {
          process.exitCode = 1
          break
        }
        wait = backoff
        backoff = Math.min(30_000, backoff * 2)
      }
      if (wait > 0) {
        try { await delay(wait, undefined, { signal: stopped.signal }) }
        catch { break }
      }
    }
  } finally {
    worker.shutdown()
    process.off('SIGINT', shutdown)
    process.off('SIGTERM', shutdown)
    console.log(JSON.stringify({ event: 'worker_stopped' }))
  }
}

void main().catch((error: unknown) => {
  console.error(JSON.stringify({ event: 'worker_start_failed', code: error instanceof WorkerError ? error.code : 'worker_failed' }))
  process.exitCode = 1
})
