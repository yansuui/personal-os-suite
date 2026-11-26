import assert from 'node:assert/strict'
import { test } from 'node:test'
import { configFromEnvironment } from '../src/worker/config.ts'
import {
  ChatWorker,
  WorkerError,
  validateAgentIdentity,
  validateHealthResponse,
  validateWorkerConfig,
} from '../src/worker/index.ts'
import type { FetchLike, WorkerConfig } from '../src/worker/index.ts'

const baseConfig: WorkerConfig = {
  apiBaseUrl: 'http://127.0.0.1:43129',
  agentToken: 'paired-agent-token',
  modelEndpoint: 'http://localhost:43130/v1/chat/completions',
  model: 'test-model',
  apiKey: 'model-only-key',
  leaseMs: 15_000,
  requestTimeoutMs: 1_000,
  modelTimeoutMs: 2_000,
  cancelPollMs: 25,
  pollIntervalMs: 25,
  maxContextMessages: 50,
  maxContextChars: 12_000,
  maxOutputTokens: 128,
}

function workerError(action: () => unknown, code: string): void {
  assert.throws(action, (error: unknown) => error instanceof WorkerError && error.code === code)
}

function response(value: unknown, status = 200): Response {
  return new Response(JSON.stringify(value), {
    status,
    headers: { 'content-type': 'application/json' },
  })
}

function mockFetch(handler: (url: URL, init: RequestInit) => Response | Promise<Response>): FetchLike {
  return async (input, init = {}) => {
    const requestUrl = input instanceof Request ? input.url : String(input)
    return await handler(new URL(requestUrl), init)
  }
}

test('environment selects the model protocol explicitly and rejects unknown values', () => {
  const env = { POS_API_BASE_URL: baseConfig.apiBaseUrl, POS_AGENT_TOKEN: baseConfig.agentToken,
    POS_MODEL_ENDPOINT: baseConfig.modelEndpoint, POS_MODEL: baseConfig.model }
  assert.equal(configFromEnvironment(env).modelApi, 'chat-completions')
  assert.equal(configFromEnvironment({ ...env, POS_MODEL_API: 'responses' }).modelApi, 'responses')
  workerError(() => configFromEnvironment({ ...env, POS_MODEL_API: 'unknown' }), 'invalid_config')
})

test('completion can use its reserved lease budget after context and model generation', async (t) => {
  let clock = 0
  t.mock.method(performance, 'now', () => clock)
  t.mock.timers.enable({ apis: ['setTimeout'] })
  const advance = (milliseconds: number) => { clock += milliseconds; t.mock.timers.tick(milliseconds) }
  const fallback = leasedFixture({ choices: [{ message: { content: 'done' } }] })
  const fetchImpl = mockFetch(async (url, init) => {
    if (url.pathname.endsWith('/messages')) {
      advance(450)
      const target = url.searchParams.get('after') === '1'
      return response({ messages: [{
        id: target ? 'message_1' : 'previous', conversationId: 'conv_1', role: 'user',
        text: target ? 'hello' : 'earlier question', seq: target ? 2 : 1,
      }], nextCursor: target ? 2 : 1 })
    }
    if (url.pathname === '/v1/chat/completions') advance(100)
    if (url.pathname.endsWith('/complete')) {
      advance(400)
      init.signal!.throwIfAborted()
    }
    return await fallback(url, init)
  })
  const worker = new ChatWorker({ ...baseConfig, leaseMs: 2_000, requestTimeoutMs: 500,
    modelTimeoutMs: 200, cancelPollMs: 30_000 }, { fetchImpl })
  assert.equal((await worker.processNextRun()).status, 'completed')
  assert.equal(clock, 1_400)
})

function leasedFixture(modelResponse: unknown): FetchLike {
  return mockFetch((url) => {
    if (url.pathname === '/v2/health') return response({ ok: true, service: 'personal-os-cloud', protocolVersion: 2 })
    if (url.pathname === '/v2/me') return response({ device: { id: 'agent_1', name: 'test agent', role: 'agent' } })
    if (url.pathname === '/v2/runs/lease') {
      const leasedUntil = new Date(Date.now() + baseConfig.leaseMs).toISOString()
      return response({
        run: {
          id: 'run_1', conversationId: 'conv_1', messageId: 'message_1', status: 'running',
          leaseToken: 'lease_token', leasedUntil,
        },
        leaseToken: 'lease_token',
      })
    }
    if (url.pathname === '/v2/conversations/conv_1/messages') {
      return response({
        messages: [{ id: 'message_1', conversationId: 'conv_1', role: 'user', text: 'hello', seq: 1 }],
        nextCursor: 1,
      })
    }
    if (url.pathname === '/v2/runs/run_1') {
      return response({ run: {
        id: 'run_1', conversationId: 'conv_1', messageId: 'message_1', status: 'running',
        leaseToken: 'lease_token', leasedUntil: new Date(Date.now() + baseConfig.leaseMs).toISOString(),
      } })
    }
    if (url.pathname === '/v1/chat/completions') return response(modelResponse)
    if (url.pathname === '/v2/runs/run_1/complete') return response({ run: { status: 'completed' } })
    throw new Error(`Unexpected test path: ${url.pathname}`)
  })
}

test('validates the complete config and accepts secure or loopback HTTP endpoints', () => {
  assert.doesNotThrow(() => validateWorkerConfig(baseConfig))
  assert.doesNotThrow(() => validateWorkerConfig({
    ...baseConfig,
    apiBaseUrl: 'https://cloud.example.test/api',
    modelEndpoint: 'https://model.example.test/v1/chat/completions',
  }))
  assert.doesNotThrow(() => validateWorkerConfig({
    ...baseConfig,
    apiBaseUrl: 'http://[::1]:43129',
    modelEndpoint: 'http://127.0.0.1:43130/v1/chat/completions',
  }))
})

test('requires agentToken separately and rejects missing or malformed worker configuration', () => {
  workerError(() => validateWorkerConfig({ ...baseConfig, agentToken: '' }), 'invalid_config')
  workerError(() => validateWorkerConfig({ ...baseConfig, agentToken: 'has whitespace' }), 'invalid_config')
  workerError(() => validateWorkerConfig({ ...baseConfig, model: '  ' }), 'invalid_config')
  workerError(() => validateWorkerConfig({ ...baseConfig, apiKey: 'bad\nheader' }), 'invalid_config')
  workerError(() => validateWorkerConfig({ ...baseConfig, maxContextChars: 0 }), 'invalid_config')
  workerError(() => validateWorkerConfig({ ...baseConfig, maxOutputTokens: 32_769 }), 'invalid_config')
})

test('rejects non-HTTPS remote URLs, URL credentials, query strings, and fragments', () => {
  workerError(() => validateWorkerConfig({ ...baseConfig, apiBaseUrl: 'http://cloud.example.test' }), 'invalid_url')
  workerError(() => validateWorkerConfig({ ...baseConfig, modelEndpoint: 'http://model.example.test/v1/chat/completions' }), 'invalid_url')
  workerError(() => validateWorkerConfig({ ...baseConfig, apiBaseUrl: 'https://user:secret@cloud.example.test' }), 'invalid_url')
  workerError(() => validateWorkerConfig({ ...baseConfig, modelEndpoint: 'https://model.example.test/v1/chat/completions?key=x' }), 'invalid_url')
  workerError(() => validateWorkerConfig({ ...baseConfig, apiBaseUrl: 'https://cloud.example.test/#fragment' }), 'invalid_url')
})

test('enforces the lease budget for model work plus API completion reserve', () => {
  assert.throws(
    () => validateWorkerConfig({ ...baseConfig, leaseMs: 4_250, modelTimeoutMs: 2_000, requestTimeoutMs: 1_000 }),
    (error: unknown) => error instanceof WorkerError && error.code === 'invalid_lease_budget',
  )
  assert.doesNotThrow(() => validateWorkerConfig({ ...baseConfig, leaseMs: 4_251 }))
})

test('validates v2 health protocol and rejects non-agent identities', () => {
  assert.doesNotThrow(() => validateHealthResponse({ ok: true, service: 'personal-os-cloud', protocolVersion: 2 }))
  workerError(() => validateHealthResponse({ ok: true, service: 'personal-os-cloud', protocolVersion: 1 }), 'incompatible_server')
  workerError(() => validateHealthResponse({ ok: true, service: 'other', protocolVersion: 2 }), 'incompatible_server')
  assert.doesNotThrow(() => validateAgentIdentity({ device: { id: 'agent_1', name: 'worker', role: 'agent' } }))
  workerError(() => validateAgentIdentity({ device: { id: 'client_1', name: 'client', role: 'client' } }), 'agent_required')
  workerError(() => validateAgentIdentity({ device: { id: 'invalid id', role: 'agent' } }), 'agent_required')
})

test('rejects cloud redirects before leasing and never follows them', async () => {
  let calls = 0
  const fetchImpl = mockFetch((_url, init) => {
    calls += 1
    assert.equal(init.redirect, 'error')
    return new Response(null, { status: 302, headers: { location: 'https://redirect.example.test' } })
  })
  const worker = new ChatWorker(baseConfig, { fetchImpl })
  await assert.rejects(() => worker.processNextRun(), (error: unknown) => error instanceof WorkerError && error.code === 'cloud_http_error')
  assert.equal(calls, 1)
})

test('only one processNextRun may run concurrently', async () => {
  let release!: (value: Response) => void
  const blocked = new Promise<Response>((resolve) => { release = resolve })
  const fetchImpl = mockFetch(async (url) => {
    if (url.pathname === '/v2/health') return await blocked
    throw new Error('the first call should stop on health failure')
  })
  const worker = new ChatWorker(baseConfig, { fetchImpl })
  const first = worker.processNextRun()
  await assert.rejects(() => worker.processNextRun(), (error: unknown) => error instanceof WorkerError && error.code === 'worker_busy')
  release(response({ ok: true, service: 'personal-os-cloud', protocolVersion: 2 }))
  await assert.rejects(first, (error: unknown) => error instanceof WorkerError && error.code === 'cloud_request_failed')
})

test('caps model response bodies and records a safe failed run', async () => {
  let completeBody: Record<string, unknown> | undefined
  const fetchImpl = mockFetch(async (url, init) => {
    if (url.pathname === '/v2/health') return response({ ok: true, service: 'personal-os-cloud', protocolVersion: 2 })
    if (url.pathname === '/v2/me') return response({ device: { id: 'agent_1', name: 'agent', role: 'agent' } })
    if (url.pathname === '/v2/runs/lease') {
      return response({ run: {
        id: 'run_1', conversationId: 'conv_1', messageId: 'message_1', status: 'running',
        leaseToken: 'lease_token', leasedUntil: new Date(Date.now() + baseConfig.leaseMs).toISOString(),
      }, leaseToken: 'lease_token' })
    }
    if (url.pathname.endsWith('/messages')) return response({
      messages: [{ id: 'message_1', conversationId: 'conv_1', role: 'user', text: 'hello', seq: 1 }], nextCursor: 1,
    })
    if (url.pathname === '/v1/chat/completions') {
      const huge = 'x'.repeat(1024 * 1024 + 1)
      return new Response(JSON.stringify({ choices: [{ message: { role: 'assistant', content: huge } }] }), {
        headers: { 'content-type': 'application/json' },
      })
    }
    if (url.pathname === '/v2/runs/run_1/complete') {
      completeBody = JSON.parse(String(init.body)) as Record<string, unknown>
      return response({ run: { status: 'failed' } })
    }
    if (url.pathname === '/v2/runs/run_1') return response({ run: {
      id: 'run_1', conversationId: 'conv_1', messageId: 'message_1', status: 'running', leaseToken: 'lease_token',
    } })
    throw new Error(`Unexpected test path: ${url.pathname}`)
  })
  const worker = new ChatWorker(baseConfig, { fetchImpl })
  const result = await worker.processNextRun()
  assert.equal(result.status, 'failed')
  assert.equal(completeBody?.status, 'failed')
  assert.equal(JSON.stringify(completeBody).includes('x'.repeat(128)), false)
})

test('rejects a model response without text content and completes with a safe failure', async () => {
  let completion: Record<string, unknown> | undefined
  const fetchImpl = mockFetch(async (url, init) => {
    if (url.pathname === '/v2/health') return response({ ok: true, service: 'personal-os-cloud', protocolVersion: 2 })
    if (url.pathname === '/v2/me') return response({ device: { id: 'agent_1', role: 'agent' } })
    if (url.pathname === '/v2/runs/lease') return response({ run: {
      id: 'run_1', conversationId: 'conv_1', messageId: 'message_1', status: 'running',
      leaseToken: 'lease_token', leasedUntil: new Date(Date.now() + baseConfig.leaseMs).toISOString(),
    }, leaseToken: 'lease_token' })
    if (url.pathname.endsWith('/messages')) return response({
      messages: [{ id: 'message_1', conversationId: 'conv_1', role: 'user', text: 'hello', seq: 1 }], nextCursor: 1,
    })
    if (url.pathname === '/v1/chat/completions') return response({ choices: [{ message: { role: 'assistant', content: null } }] })
    if (url.pathname === '/v2/runs/run_1/complete') {
      completion = JSON.parse(String(init.body)) as Record<string, unknown>
      return response({ run: { status: 'failed' } })
    }
    if (url.pathname === '/v2/runs/run_1') return response({ run: {
      id: 'run_1', conversationId: 'conv_1', messageId: 'message_1', status: 'running', leaseToken: 'lease_token',
    } })
    throw new Error(`Unexpected test path: ${url.pathname}`)
  })
  const worker = new ChatWorker(baseConfig, { fetchImpl })
  const result = await worker.processNextRun()
  assert.equal(result.status, 'failed')
  assert.equal(completion?.status, 'failed')
  assert.equal(typeof completion?.error, 'string')
  assert.equal(JSON.stringify(completion).includes('hello'), false)
})

test('a marked goal run fails closed when its fixed context is unavailable', async () => {
  let modelCalls = 0
  let completion: Record<string, unknown> | undefined
  const fetchImpl = mockFetch(async (url, init) => {
    if (url.pathname === '/v2/health') return response({ ok: true, service: 'personal-os-cloud', protocolVersion: 2 })
    if (url.pathname === '/v2/me') return response({ device: { id: 'agent_1', role: 'agent' } })
    if (url.pathname === '/v2/runs/lease') return response({ run: {
      id: 'run_1', conversationId: 'conv_1', messageId: 'message_1', status: 'running',
      goalId: 'goal_1', leaseToken: 'lease_token', leasedUntil: new Date(Date.now() + baseConfig.leaseMs).toISOString(),
    }, leaseToken: 'lease_token' })
    if (url.pathname === '/v2/conversations/conv_1/messages') return response({ messages: [{
      id: 'message_1', conversationId: 'conv_1', role: 'user', text: 'goal question', seq: 1,
    }], nextCursor: 1 })
    if (url.pathname === '/v2/runs/run_1/goal-context') return response({ error: { code: 'not_found' } }, 404)
    if (url.pathname === '/v2/runs/run_1') return response({ run: {
      id: 'run_1', conversationId: 'conv_1', messageId: 'message_1', status: 'running',
      goalId: 'goal_1', leaseToken: 'lease_token', leasedUntil: new Date(Date.now() + baseConfig.leaseMs).toISOString(),
    } })
    if (url.pathname === '/v2/runs/run_1/complete') {
      completion = JSON.parse(String(init.body)) as Record<string, unknown>
      return response({ run: { status: 'failed' } })
    }
    if (url.pathname === '/v1/chat/completions') {
      modelCalls += 1
      return response({ choices: [{ message: { content: 'must not answer without facts' } }] })
    }
    throw new Error(`Unexpected test path: ${url.pathname}`)
  })
  const worker = new ChatWorker(baseConfig, { fetchImpl })
  const result = await worker.processNextRun()
  assert.equal(result.status, 'failed')
  assert.equal(modelCalls, 0)
  assert.equal(completion?.status, 'failed')
})

test('does not send the agent credential to the model endpoint', async () => {
  let modelAuthorization: string | null | undefined
  const fetchImpl = mockFetch(async (url, init) => {
    if (url.pathname === '/v2/health') return response({ ok: true, service: 'personal-os-cloud', protocolVersion: 2 })
    if (url.pathname === '/v2/me') return response({ device: { id: 'agent_1', role: 'agent' } })
    if (url.pathname === '/v2/runs/lease') return response({ run: {
      id: 'run_1', conversationId: 'conv_1', messageId: 'message_1', status: 'running',
      leaseToken: 'lease_token', leasedUntil: new Date(Date.now() + baseConfig.leaseMs).toISOString(),
    }, leaseToken: 'lease_token' })
    if (url.pathname.endsWith('/messages')) return response({
      messages: [{ id: 'message_1', conversationId: 'conv_1', role: 'user', text: 'hello', seq: 1 }], nextCursor: 1,
    })
    if (url.pathname === '/v1/chat/completions') {
      modelAuthorization = new Headers(init.headers).get('authorization')
      assert.equal(modelAuthorization, `Bearer ${baseConfig.apiKey}`)
      return response({ choices: [{ message: { role: 'assistant', content: 'done' } }] })
    }
    if (url.pathname === '/v2/runs/run_1/complete') return response({ run: { status: 'completed' } })
    if (url.pathname === '/v2/runs/run_1') return response({ run: {
      id: 'run_1', conversationId: 'conv_1', messageId: 'message_1', status: 'running', leaseToken: 'lease_token',
    } })
    throw new Error(`Unexpected test path: ${url.pathname}`)
  })
  const worker = new ChatWorker(baseConfig, { fetchImpl })
  assert.equal((await worker.processNextRun()).status, 'completed')
  assert.equal(modelAuthorization, `Bearer ${baseConfig.apiKey}`)
  assert.notEqual(modelAuthorization, `Bearer ${baseConfig.agentToken}`)
})
