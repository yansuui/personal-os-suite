import assert from 'node:assert/strict'
import { randomUUID } from 'node:crypto'
import { mkdtempSync, rmSync } from 'node:fs'
import { createServer } from 'node:http'
import type { IncomingMessage, Server, ServerResponse } from 'node:http'
import { tmpdir } from 'node:os'
import { basename, dirname, join } from 'node:path'
import { test } from 'node:test'
import type { TestContext } from 'node:test'
import { CloudStore } from '../src/store.ts'
import { createV2Server } from '../src/server.ts'
import { ChatWorker } from '../src/worker/index.ts'
import type { WorkerConfig } from '../src/worker/index.ts'

async function bind(server: Server): Promise<string> {
  await new Promise<void>((resolve, reject) => {
    server.once('error', reject)
    server.listen(0, '127.0.0.1', () => {
      server.off('error', reject)
      resolve()
    })
  })
  const address = server.address()
  assert.ok(address && typeof address !== 'string')
  return `http://127.0.0.1:${address.port}`
}

async function stop(server: Server): Promise<void> {
  if (!server.listening) return
  await new Promise<void>((resolve, reject) => {
    server.close((error) => error ? reject(error) : resolve())
    server.closeAllConnections()
  })
}

function deferred<T>() {
  let resolve!: (value: T) => void
  const promise = new Promise<T>((done) => { resolve = done })
  return { promise, resolve }
}

async function bounded<T>(promise: Promise<T>): Promise<T> {
  let timer: ReturnType<typeof setTimeout> | undefined
  try {
    return await Promise.race([
      promise,
      new Promise<never>((_, reject) => {
        timer = setTimeout(() => reject(new Error('Local integration event did not arrive.')), 5_000)
      }),
    ])
  } finally {
    clearTimeout(timer)
  }
}

type ModelRequest = { model: string; messages: Array<{ role: string; content: string }>; stream?: boolean }
type ModelHandler = (body: ModelRequest, response: ServerResponse, request: IncomingMessage) => void

async function fixture(t: TestContext, modelHandler: ModelHandler, now?: () => Date) {
  const directory = mkdtempSync(join(tmpdir(), 'personal-os-worker-e2e-'))
  const store = new CloudStore(join(directory, 'cloud.sqlite'), now)
  const servers: Server[] = []
  const workers: ChatWorker[] = []
  const active = new Set<Promise<unknown>>()
  const execute = (worker: ChatWorker, signal?: AbortSignal) => {
    const work = worker.processNextRun(signal)
    active.add(work)
    void work.then(() => active.delete(work), () => active.delete(work))
    return work
  }
  t.after(async () => {
    for (const worker of workers) worker.shutdown()
    try {
      await bounded(Promise.allSettled([...active]))
    } finally {
      await Promise.all(servers.map(stop))
      store.close()
      assert.equal(dirname(directory), tmpdir())
      assert.ok(basename(directory).startsWith('personal-os-worker-e2e-'))
      rmSync(directory, { recursive: true, force: true })
    }
  })
  const pairSecret = randomUUID()
  const server = createV2Server({ store, adminSecret: pairSecret, now })
  servers.push(server)
  const apiBaseUrl = await bind(server)
  async function call(path: string, token?: string, body?: unknown) {
    const response = await fetch(`${apiBaseUrl}${path}`, {
      method: body === undefined ? 'GET' : 'POST',
      headers: {
        ...(token ? { authorization: `Bearer ${token}` } : {}),
        ...(body !== undefined ? { 'content-type': 'application/json' } : {}),
        ...(path === '/v2/pair' ? { 'x-pair-secret': pairSecret } : {}),
      },
      body: body === undefined ? undefined : JSON.stringify(body),
      signal: AbortSignal.timeout(5_000),
    })
    return { status: response.status, data: await response.json() as Record<string, any> }
  }
  const client = await call('/v2/pair', undefined, { name: 'test-phone', role: 'client' })
  const agent = await call('/v2/pair', undefined, { name: 'test-worker', role: 'agent' })
  assert.equal(client.status, 201)
  assert.equal(agent.status, 201)
  const modelKey = randomUUID()
  const requests: ModelRequest[] = []
  const modelServer = createServer(async (request, response) => {
    try {
      assert.equal(request.url, '/v1/chat/completions')
      assert.equal(request.method, 'POST')
      assert.equal(request.headers.authorization, `Bearer ${modelKey}`)
      let text = ''
      for await (const chunk of request) text += chunk
      const body = JSON.parse(text) as ModelRequest
      requests.push(body)
      modelHandler(body, response, request)
    } catch {
      response.writeHead(500).end('{}')
    }
  })
  servers.push(modelServer)
  const modelBaseUrl = await bind(modelServer)
  const config = {
    apiBaseUrl,
    agentToken: agent.data.token,
    modelEndpoint: `${modelBaseUrl}/v1/chat/completions`,
    model: 'local-test-model',
    apiKey: modelKey,
    leaseMs: 15_000,
    requestTimeoutMs: 1_000,
    modelTimeoutMs: 2_000,
    cancelPollMs: 25,
    pollIntervalMs: 25,
    maxContextMessages: 300,
    maxContextChars: 200_000,
    maxOutputTokens: 200,
  } as WorkerConfig
  const conversation = await call('/v2/conversations', client.data.token, { title: 'worker integration' })
  assert.equal(conversation.status, 201)
  const conversationId = conversation.data.conversation.id as string
  const messagesPath = `/v2/conversations/${conversationId}/messages`
  const send = (text: string, clientRequestId: string = randomUUID()) => call(messagesPath, client.data.token, { text, clientRequestId })
  const messages = () => call(`${messagesPath}?after=0&wait=0`, client.data.token)
  const run = (id: string) => call(`/v2/runs/${id}`, client.data.token)
  const cancel = (id: string) => call(`/v2/runs/${id}/cancel`, client.data.token, {})
  const worker = (overrides: Partial<WorkerConfig> = {}) => {
    const instance = new ChatWorker({ ...config, ...overrides })
    workers.push(instance)
    return instance
  }
  return { store, server, call, clientToken: client.data.token as string, config, requests,
    conversationId, messagesPath, send, messages, run, cancel, worker, execute }
}

function answer(response: ServerResponse, text: string): void {
  response.writeHead(200, { 'content-type': 'application/json' })
  response.end(JSON.stringify({ choices: [{ message: { role: 'assistant', content: text } }] }))
}

test('worker executes real HTTP/SQLite chat, includes prior turns, and does not rerun idempotent sends', async (t) => {
  const f = await fixture(t, (body, response) => answer(response, `reply:${body.messages.at(-1)?.content}`))
  const first = await f.send('first question', 'same-request')
  assert.equal(first.status, 201)
  const worker = f.worker()
  await f.execute(worker)
  assert.equal((await f.run(first.data.run.id)).data.run.status, 'completed')
  const replay = await f.send('first question', 'same-request')
  assert.equal(replay.status, 200)
  assert.equal(replay.data.run.id, first.data.run.id)
  await f.execute(worker)
  assert.equal(f.requests.length, 1)
  const second = await f.send('second question')
  await f.execute(worker)
  assert.equal((await f.run(second.data.run.id)).data.run.status, 'completed')
  assert.deepEqual(f.requests[1].messages.filter((m) => m.role !== 'system').map((m) => [m.role, m.content]), [
    ['user', 'first question'], ['assistant', 'reply:first question'], ['user', 'second question'],
  ])
  const timeline = (await f.messages()).data.messages
  assert.deepEqual(timeline.map((m: { seq: number }) => m.seq), [1, 2, 3, 4])
  assert.equal(f.requests[0].model, 'local-test-model')
  assert.notEqual(f.requests[0].stream, true)
})

test('worker follows 200-message pages and excludes messages later than its run target', async (t) => {
  const f = await fixture(t, (_body, response) => answer(response, 'paged reply'))
  for (let index = 0; index < 101; index += 1) {
    const sent = f.store.appendUserMessage({ conversationId: f.conversationId, role: 'user', text: `history-${index}`, clientRequestId: `seed-${index}` })
    const lease = f.store.leaseRun({ leaseMs: 15_000 })
    assert.equal(lease?.run.id, sent.run.id)
    assert.ok(f.store.completeRun(sent.run.id, lease!.leaseToken, { status: 'completed', resultText: `history-reply-${index}` }))
  }
  const target = await f.send('target question')
  await f.send('future question must not enter this prompt')
  await f.execute(f.worker())
  assert.equal((await f.run(target.data.run.id)).data.run.status, 'completed')
  assert.equal(f.requests.length, 1)
  const texts = f.requests[0].messages.map((message) => message.content)
  assert.ok(texts.includes('history-0'))
  assert.equal(texts.at(-1), 'target question')
  assert.equal(texts.some((text) => text.includes('future question')), false)
})

test('canceling a running job aborts model HTTP and never adds a late assistant reply', async (t) => {
  const started = deferred<void>()
  const disconnected = deferred<void>()
  const f = await fixture(t, (_body, response) => {
    response.once('close', () => disconnected.resolve())
    started.resolve()
  })
  const sent = await f.send('cancel this generation')
  const work = f.execute(f.worker())
  await bounded(started.promise)
  assert.equal((await f.run(sent.data.run.id)).data.run.status, 'running')
  assert.equal((await f.cancel(sent.data.run.id)).data.run.status, 'canceled')
  await bounded(work)
  await bounded(disconnected.promise)
  assert.equal((await f.run(sent.data.run.id)).data.run.status, 'canceled')
  assert.deepEqual((await f.messages()).data.messages.map((m: { role: string }) => m.role), ['user'])
})

test('a model HTTP failure is a safe failed run with no provider response or credential leakage', async (t) => {
  const privateBody = `upstream-private-${randomUUID()}`
  const f = await fixture(t, (_body, response) => response.writeHead(401).end(privateBody))
  const sent = await f.send('provider fails')
  await f.execute(f.worker())
  const result = (await f.run(sent.data.run.id)).data.run
  assert.equal(result.status, 'failed')
  assert.equal(typeof result.error, 'string')
  assert.equal(JSON.stringify(result).includes(privateBody), false)
  assert.equal(JSON.stringify(result).includes(f.config.apiKey!), false)
  assert.equal((await f.messages()).data.messages.length, 1)
})

test('a model timeout records failure inside the lease and disconnects the upstream', async (t) => {
  const disconnected = deferred<void>()
  const f = await fixture(t, (_body, response) => response.once('close', () => disconnected.resolve()))
  const sent = await f.send('slow model')
  await bounded(f.execute(f.worker({ modelTimeoutMs: 100 })))
  const result = (await f.run(sent.data.run.id)).data.run
  assert.equal(result.status, 'failed')
  assert.equal(typeof result.error, 'string')
  await bounded(disconnected.promise)
  assert.equal((await f.messages()).data.messages.length, 1)
})

test('shutdown leaves unfinished work for lease recovery; a new worker completes it once', async (t) => {
  let timestamp = Date.now()
  const started = deferred<void>()
  let calls = 0
  const f = await fixture(t, (_body, response) => {
    calls += 1
    if (calls === 1) started.resolve()
    else answer(response, 'recovered reply')
  }, () => new Date(timestamp))
  const sent = await f.send('survive worker stop')
  const first = f.worker()
  const work = f.execute(first)
  await bounded(started.promise)
  const original = f.store.getRun(sent.data.run.id)!
  first.shutdown()
  await bounded(work)
  assert.equal(f.store.getRun(original.id)?.status, 'running')
  timestamp += f.config.leaseMs + 1
  await f.execute(f.worker())
  assert.equal((await f.run(original.id)).data.run.status, 'completed')
  assert.equal(f.store.completeRun(original.id, original.leaseToken!, { status: 'completed', resultText: 'stale reply' }), null)
  assert.deepEqual((await f.messages()).data.messages.map((m: { text: string }) => m.text), ['survive worker stop', 'recovered reply'])
  assert.equal(calls, 2)
})

test('a cancellation immediately before complete returns 409 and is never overwritten by the worker', async (t) => {
  const f = await fixture(t, (_body, response) => answer(response, 'must be discarded'))
  const sent = await f.send('cancel at completion boundary')
  let fenced = false
  f.server.prependListener('request', (request) => {
    if (request.url === `/v2/runs/${sent.data.run.id}/complete`) {
      fenced = true
      f.store.cancelRun(sent.data.run.id)
    }
  })
  await f.execute(f.worker())
  assert.equal(fenced, true)
  assert.equal((await f.run(sent.data.run.id)).data.run.status, 'canceled')
  assert.equal((await f.messages()).data.messages.length, 1)
})

test('a client credential is rejected before leasing or invoking the model', async (t) => {
  const f = await fixture(t, (_body, response) => answer(response, 'must not execute'))
  const sent = await f.send('requires an agent')
  await assert.rejects(() => f.execute(f.worker({ agentToken: f.clientToken })))
  assert.equal((await f.run(sent.data.run.id)).data.run.status, 'queued')
  assert.equal(f.requests.length, 0)
})
