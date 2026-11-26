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

type ModelRequest = { model: string; messages: Array<{ role: string; content: string }>; input?: Array<{ role: string; content: string }>; stream?: boolean; store?: boolean; prompt_cache_key?: string; max_output_tokens?: number }
type ModelHandler = (body: ModelRequest, response: ServerResponse, request: IncomingMessage) => void

async function fixture(t: TestContext, modelHandler: ModelHandler, now?: () => Date, modelApi: WorkerConfig['modelApi'] = 'chat-completions', goalQuestionsEnabled = false) {
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
  const server = createV2Server({ store, adminSecret: pairSecret, now, goalQuestionsEnabled })
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
      assert.equal(request.url, modelApi === 'responses' ? '/v1/responses' : '/v1/chat/completions')
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
    modelEndpoint: `${modelBaseUrl}${modelApi === 'responses' ? '/v1/responses' : '/v1/chat/completions'}`,
    modelApi,
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

function responsesAnswer(response: ServerResponse, text: string, status = 'completed'): void {
  response.writeHead(200, { 'content-type': 'application/json' }).end(JSON.stringify({ status, output: [
    { type: 'reasoning', summary: [{ type: 'summary_text', text: 'private reasoning' }] },
    { type: 'message', role: 'assistant', status: 'completed', content: [{ type: 'output_text', text }] },
  ] }))
}

test('Responses generates real HTTP/SQLite replies with stable cache key and prior context', async (t) => {
  const f = await fixture(t, (body, response) => {
    assert.equal(body.stream, false)
    assert.equal(body.store, false)
    assert.equal(body.max_output_tokens, 200)
    assert.equal(body.messages, undefined)
    assert.ok(body.prompt_cache_key)
    responsesAnswer(response, `reply:${body.input!.at(-1)!.content}`)
  }, undefined, 'responses')
  const first = await f.send('first question', 'responses-first')
  assert.equal((await f.execute(f.worker())).status, 'completed')
  const second = await f.send('follow up')
  assert.equal((await f.execute(f.worker())).status, 'completed')
  assert.equal((await f.run(first.data.run.id)).data.run.status, 'completed')
  assert.equal((await f.run(second.data.run.id)).data.run.status, 'completed')
  assert.equal(f.requests[0].prompt_cache_key, f.requests[1].prompt_cache_key)
  assert.deepEqual(f.requests[1].input, [
    { role: 'user', content: 'first question' },
    { role: 'assistant', content: 'reply:first question' },
    { role: 'user', content: 'follow up' },
  ])
  const timeline = (await f.messages()).data.messages
  assert.deepEqual(timeline.map((m: { seq: number }) => m.seq), [1, 2, 3, 4])
  assert.equal(JSON.stringify(timeline).includes('private reasoning'), false)
})

test('Responses rejects incomplete or refused output without adding an assistant message', async (t) => {
  const f = await fixture(t, (_body, response) => responsesAnswer(response, 'partial must not be saved', 'incomplete'), undefined, 'responses')
  const sent = await f.send('unfinished generation')
  assert.equal((await f.execute(f.worker())).status, 'failed')
  assert.equal((await f.run(sent.data.run.id)).data.run.status, 'failed')
  assert.equal((await f.messages()).data.messages.length, 1)
  const g = await fixture(t, (_body, response) => {
    response.writeHead(200, { 'content-type': 'application/json' }).end(JSON.stringify({ status: 'completed', output: [
      { type: 'message', role: 'assistant', status: 'completed', content: [{ type: 'refusal', refusal: 'private refusal' }] },
    ] }))
  }, undefined, 'responses')
  const refused = await g.send('refused generation')
  assert.equal((await g.execute(g.worker())).status, 'failed')
  assert.equal(JSON.stringify((await g.run(refused.data.run.id)).data.run).includes('private refusal'), false)
  assert.equal((await g.messages()).data.messages.length, 1)
})

test('Responses rejects unfinished or missing message status even when the response is completed', async (t) => {
  for (const status of ['incomplete', 'in_progress', undefined]) {
    const f = await fixture(t, (_body, response) => {
      response.writeHead(200, { 'content-type': 'application/json' }).end(JSON.stringify({ status: 'completed', output: [
        { type: 'message', role: 'assistant', status, content: [{ type: 'output_text', text: 'partial must not be saved' }] },
      ] }))
    }, undefined, 'responses')
    await f.send('unfinished message')
    assert.equal((await f.execute(f.worker())).status, 'failed')
    assert.equal((await f.messages()).data.messages.length, 1)
  }
})

for (const modelApi of ['chat-completions', 'responses'] as const) {
  test(`${modelApi} goal questions use their fixed HTTP snapshot and refresh facts only for a new question`, async (t) => {
    const f = await fixture(t, (_body, response) => {
      if (modelApi === 'responses') responsesAnswer(response, 'reply based on the fixed goal snapshot')
      else answer(response, 'reply based on the fixed goal snapshot')
    }, undefined, modelApi, true)
    const goalResponse = await f.call('/v2/goals', f.clientToken, { commandId: randomUUID(), title: 'Launch the personal assistant' })
    assert.equal(goalResponse.status, 201)
    const goalId = goalResponse.data.goal.id as string
    const tasksPath = `/v2/goals/${goalId}/tasks`
    const taskResponse = await f.call(tasksPath, f.clientToken, { commandId: randomUUID(), title: 'Verify goal answers' })
    assert.equal(taskResponse.status, 201)
    const task = taskResponse.data.task
    const questionsPath = `/v2/goals/${goalId}/questions`
    const question = { conversationId: f.conversationId, clientRequestId: randomUUID(), text: 'What remains?' }
    const first = await f.call(questionsPath, f.clientToken, question)
    assert.equal(first.status, 201)
    const contextPath = `/v2/runs/${first.data.run.id}/goal-context`
    const original = (await f.call(contextPath, f.clientToken)).data.goalContext
    assert.equal(original.summary.todoTasks, 1)
    assert.equal(original.summary.blockedTasks, 0)
    const changed = await f.call(`/v2/tasks/${task.id}/commands`, f.clientToken, {
      commandId: randomUUID(), expectedRevision: task.revision,
      action: 'set_status', status: 'blocked', note: 'Waiting for device verification',
    })
    assert.equal(changed.status, 200)
    const unrelated = await f.call('/v2/goals', f.clientToken, { commandId: randomUUID(), title: 'Unrelated private goal' })
    assert.equal(unrelated.status, 201)
    assert.equal((await f.execute(f.worker())).status, 'completed')
    const turns = modelApi === 'responses' ? f.requests[0].input! : f.requests[0].messages
    const facts = turns.filter((turn) => turn.role === 'system')
    assert.equal(facts.length, 1)
    assert.deepEqual(JSON.parse(facts[0].content.slice(facts[0].content.indexOf('{'))), original)
    assert.equal(JSON.stringify(turns).includes('Waiting for device verification'), false)
    assert.equal(JSON.stringify(turns).includes('Unrelated private goal'), false)
    assert.deepEqual((await f.call(contextPath, f.clientToken)).data.goalContext, original)
    const replay = await f.call(questionsPath, f.clientToken, question)
    assert.equal(replay.status, 200)
    assert.equal(replay.data.run.id, first.data.run.id)
    assert.equal((await f.execute(f.worker())).status, 'idle')
    assert.equal(f.requests.length, 1)
    const otherClient = await f.call('/v2/pair', undefined, { name: 'second-phone', role: 'client' })
    const otherMessages = await f.call(`${f.messagesPath}?after=0&wait=0`, otherClient.data.token)
    assert.deepEqual(otherMessages.data.messages, (await f.messages()).data.messages)
    assert.equal(otherMessages.data.messages.filter((message: { role: string }) => message.role === 'assistant').length, 1)

    const second = await f.call(questionsPath, f.clientToken, { ...question, clientRequestId: randomUUID() })
    assert.equal(second.status, 201)
    const fresh = (await f.call(`/v2/runs/${second.data.run.id}/goal-context`, f.clientToken)).data.goalContext
    assert.ok(fresh.viewRevision > original.viewRevision)
    assert.equal(fresh.summary.todoTasks, 0)
    assert.equal(fresh.summary.blockedTasks, 1)
    assert.equal((await f.execute(f.worker())).status, 'completed')
    const newTurns = modelApi === 'responses' ? f.requests[1].input! : f.requests[1].messages
    const newFacts = newTurns.filter((turn) => turn.role === 'system')
    assert.equal(newFacts.length, 1)
    assert.deepEqual(JSON.parse(newFacts[0].content.slice(newFacts[0].content.indexOf('{'))), fresh)
    assert.equal((await f.call(`/v2/goals/${goalId}`, f.clientToken)).data.goalView.viewRevision, fresh.viewRevision)
    assert.equal((await f.call(`/v2/tasks/${task.id}`, f.clientToken)).data.task.status, 'blocked')
    assert.equal((await f.messages()).data.messages.filter((message: { role: string }) => message.role === 'assistant').length, 2)
  })

  test(`${modelApi} rejects a goal snapshot that cannot fit with its question before model HTTP`, async (t) => {
    const f = await fixture(t, (_body, response) => {
      if (modelApi === 'responses') responsesAnswer(response, 'must not execute')
      else answer(response, 'must not execute')
    }, undefined, modelApi, true)
    const goal = (await f.call('/v2/goals', f.clientToken, { commandId: randomUUID(), title: 'Goal exceeds configured budget' })).data.goal
    const sent = await f.call(`/v2/goals/${goal.id}/questions`, f.clientToken, {
      conversationId: f.conversationId, clientRequestId: randomUUID(), text: 'Review',
    })
    assert.equal(sent.status, 201)
    assert.equal((await f.execute(f.worker({ maxContextChars: 50 }))).status, 'failed')
    assert.equal(f.requests.length, 0)
    assert.equal((await f.run(sent.data.run.id)).data.run.status, 'failed')
    assert.equal((await f.messages()).data.messages.length, 1)
  })

  test(`${modelApi} reserves the goal snapshot character budget by dropping only old chat history`, async (t) => {
    const f = await fixture(t, (_body, response) => {
      if (modelApi === 'responses') responsesAnswer(response, 'bounded goal answer')
      else answer(response, 'bounded goal answer')
    }, undefined, modelApi, true)
    const history = f.store.appendUserMessage({ conversationId: f.conversationId, role: 'user', text: 'old question '.repeat(10), clientRequestId: randomUUID() })
    const lease = f.store.leaseRun({ leaseMs: f.config.leaseMs })!
    assert.equal(lease.run.id, history.run.id)
    f.store.completeRun(history.run.id, lease.leaseToken, { status: 'completed', resultText: 'old answer '.repeat(10) })
    const goal = (await f.call('/v2/goals', f.clientToken, { commandId: randomUUID(), title: 'Preserve full facts' })).data.goal
    const sent = await f.call(`/v2/goals/${goal.id}/questions`, f.clientToken, {
      conversationId: f.conversationId, clientRequestId: randomUUID(), text: 'Current goal question',
    })
    assert.equal(sent.status, 201)
    const context = (await f.call(`/v2/runs/${sent.data.run.id}/goal-context`, f.clientToken)).data.goalContext
    const maxContextChars = JSON.stringify(context).length + 200
    assert.equal((await f.execute(f.worker({ maxContextChars }))).status, 'completed')
    const turns = modelApi === 'responses' ? f.requests[0].input! : f.requests[0].messages
    assert.ok(turns.reduce((total, turn) => total + turn.content.length, 0) <= maxContextChars)
    assert.deepEqual(turns.map((turn) => turn.role), ['system', 'user'])
    assert.equal(turns.at(-1)!.content, 'Current goal question')
    assert.deepEqual(JSON.parse(turns[0].content.slice(turns[0].content.indexOf('{'))), context)
  })

  test(`${modelApi} counts goal facts toward the message budget without dropping the current question`, async (t) => {
    const f = await fixture(t, (_body, response) => {
      if (modelApi === 'responses') responsesAnswer(response, 'bounded goal answer')
      else answer(response, 'bounded goal answer')
    }, undefined, modelApi, true)
    const goal = (await f.call('/v2/goals', f.clientToken, { commandId: randomUUID(), title: 'Message budget' })).data.goal
    const path = `/v2/goals/${goal.id}/questions`
    const first = await f.call(path, f.clientToken, {
      conversationId: f.conversationId, clientRequestId: randomUUID(), text: 'First question',
    })
    assert.equal(first.status, 201)
    assert.equal((await f.execute(f.worker({ maxContextMessages: 1 }))).status, 'failed')
    assert.equal(f.requests.length, 0)
    const second = await f.call(path, f.clientToken, {
      conversationId: f.conversationId, clientRequestId: randomUUID(), text: 'Second question',
    })
    assert.equal(second.status, 201)
    assert.equal((await f.execute(f.worker({ maxContextMessages: 2 }))).status, 'completed')
    const turns = modelApi === 'responses' ? f.requests[0].input! : f.requests[0].messages
    assert.deepEqual(turns.map((turn) => turn.role), ['system', 'user'])
    assert.equal(turns.at(-1)!.content, 'Second question')
  })
}

test('a recovered goal run keeps its original snapshot after business changes and remains fenced from old workers', async (t) => {
  let timestamp = Date.now()
  const started = deferred<void>()
  let attempts = 0
  const f = await fixture(t, (_body, response) => {
    attempts += 1
    if (attempts === 1) started.resolve()
    else responsesAnswer(response, 'recovered goal reply')
  }, () => new Date(timestamp), 'responses', true)
  const created = await f.call('/v2/goals', f.clientToken, { commandId: randomUUID(), title: 'Original goal title' })
  assert.equal(created.status, 201)
  const goal = created.data.goal
  const sent = await f.call(`/v2/goals/${goal.id}/questions`, f.clientToken, {
    conversationId: f.conversationId, clientRequestId: randomUUID(), text: 'Review this goal',
  })
  assert.equal(sent.status, 201)
  const firstWorker = f.worker()
  const work = f.execute(firstWorker)
  await bounded(started.promise)
  const originalRun = f.store.getRun(sent.data.run.id)!
  firstWorker.shutdown()
  assert.equal((await bounded(work)).status, 'stopped')
  const updated = await f.call(`/v2/goals/${goal.id}/commands`, f.clientToken, {
    commandId: randomUUID(), expectedRevision: goal.revision, action: 'update', title: 'Changed after worker stopped',
  })
  assert.equal(updated.status, 200)
  timestamp += f.config.leaseMs + 1
  const oldLease = await f.call('/v2/runs/lease', f.config.agentToken, { leaseMs: f.config.leaseMs })
  assert.equal(oldLease.status, 200)
  assert.equal(oldLease.data.run, null)
  assert.equal((await f.execute(f.worker())).status, 'completed')
  assert.equal(f.requests.length, 2)
  const firstFacts = f.requests[0].input!.find((turn) => turn.role === 'system')!
  const recoveredFacts = f.requests[1].input!.find((turn) => turn.role === 'system')!
  assert.deepEqual(recoveredFacts, firstFacts)
  assert.equal(firstFacts.content.includes('Original goal title'), true)
  assert.equal(recoveredFacts.content.includes('Changed after worker stopped'), false)
  assert.equal(f.store.completeRun(originalRun.id, originalRun.leaseToken!, { status: 'completed', resultText: 'late answer' }), null)
  assert.deepEqual((await f.messages()).data.messages.map((message: { text: string }) => message.text), ['Review this goal', 'recovered goal reply'])
})

test('Responses cancellation aborts upstream HTTP without a late reply', async (t) => {
  const started = deferred<void>()
  const disconnected = deferred<void>()
  const f = await fixture(t, (_body, response) => {
    response.once('close', () => disconnected.resolve())
    started.resolve()
  }, undefined, 'responses')
  const sent = await f.send('cancel responses')
  const work = f.execute(f.worker())
  await bounded(started.promise)
  await f.cancel(sent.data.run.id)
  await bounded(work)
  await bounded(disconnected.promise)
  assert.equal((await f.run(sent.data.run.id)).data.run.status, 'canceled')
  assert.equal((await f.messages()).data.messages.length, 1)
})
