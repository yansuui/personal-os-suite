import { readFileSync } from 'node:fs'
import { WorkerError, validateWorkerConfig } from './index.ts'
import type { WorkerConfig } from './index.ts'

function number(env: NodeJS.ProcessEnv, name: string, fallback: number): number {
  const raw = env[name]
  if (raw === undefined) return fallback
  if (!/^[1-9]\d*$/.test(raw)) throw new WorkerError('invalid_config')
  return Number(raw)
}
function secret(env: NodeJS.ProcessEnv, name: string): string | undefined {
  const direct = env[name]
  const file = env[`${name}_FILE`]
  if (direct !== undefined && file !== undefined) throw new WorkerError('ambiguous_secret_config')
  if (file !== undefined) {
    try { return readFileSync(file, 'utf8').trim() }
    catch { throw new WorkerError('secret_file_unreadable') }
  }
  return direct
}

/** Configuration errors never echo environment contents or secret file paths. */
export function configFromEnvironment(env: NodeJS.ProcessEnv = process.env): WorkerConfig {
  const config: WorkerConfig = {
    apiBaseUrl: env.POS_API_BASE_URL ?? '',
    agentToken: secret(env, 'POS_AGENT_TOKEN') ?? '',
    modelEndpoint: env.POS_MODEL_ENDPOINT ?? '',
    model: env.POS_MODEL ?? '',
    modelApi: (env.POS_MODEL_API ?? 'chat-completions') as WorkerConfig['modelApi'],
    apiKey: secret(env, 'POS_MODEL_API_KEY'),
    leaseMs: number(env, 'POS_WORKER_LEASE_MS', 120_000),
    requestTimeoutMs: number(env, 'POS_WORKER_REQUEST_TIMEOUT_MS', 10_000),
    modelTimeoutMs: number(env, 'POS_WORKER_MODEL_TIMEOUT_MS', 60_000),
    cancelPollMs: number(env, 'POS_WORKER_CANCEL_POLL_MS', 1_000),
    pollIntervalMs: number(env, 'POS_WORKER_POLL_MS', 1_000),
    maxContextMessages: number(env, 'POS_WORKER_CONTEXT_MESSAGES', 60),
    maxContextChars: number(env, 'POS_WORKER_CONTEXT_CHARS', 60_000),
    maxOutputTokens: number(env, 'POS_WORKER_OUTPUT_TOKENS', 2_048),
  }
  validateWorkerConfig(config)
  return config
}
