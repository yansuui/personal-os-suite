import assert from 'node:assert/strict'
import { once } from 'node:events'
import { randomUUID } from 'node:crypto'
import { request as httpRequest } from 'node:http'
import { setTimeout as delay } from 'node:timers/promises'
import { test } from 'node:test'
import type { TestContext } from 'node:test'
import { hashToken } from '../src/auth.ts'
import { createV2Server } from '../src/server.ts'
import type { CloudStoreApi, CompleteRunInput, CreateGoalInput, CreateTaskInput, GoalCommandInput, InsertMessageInput, TaskCommandInput } from '../src/store-api.ts'
import type {
  ConversationRecord, DeviceRecord, DeviceRole, MessageRecord, MessageWithRun, RunLease, RunRecord,
} from '../src/types.ts'

class MemoryStore implements CloudStoreApi {
  readonly dbPath = ':memory:'
  devices: DeviceRecord[] = []
  conversations: ConversationRecord[] = []
  messages: MessageRecord[] = []
  runs: RunRecord[] = []
  listReads = 0
  touches = 0
  lastLeaseMs: number | null = null
  onRead: (() => void) | undefined
  failList = false

  close(): void {}
  pairDevice(input: { name: string; role: DeviceRole; tokenHash: string }): DeviceRecord {
    const device = { ...input, id: randomUUID(), createdAt: new Date().toISOString(), lastSeenAt: null, revokedAt: null }
    this.devices.push(device)
    return { ...device }
  }
  deviceByTokenHash(tokenHash: string): DeviceRecord | null {
    const device = this.devices.find((item) => item.tokenHash === tokenHash)
    return device ? { ...device } : null
  }
  deviceById(id: string): DeviceRecord | null {
    const device = this.devices.find((item) => item.id === id)
    return device ? { ...device } : null
  }
  touchDevice(id: string, at = new Date()): void {
    const device = this.devices.find((item) => item.id === id)
    if (device) device.lastSeenAt = at.toISOString()
    this.touches += 1
  }
  createConversation(input: { title?: string | null }): ConversationRecord {
    const timestamp = new Date().toISOString()
    const conversation = { id: randomUUID(), ownerId: 'default', title: input.title ?? null, createdAt: timestamp, updatedAt: timestamp }
    this.conversations.push(conversation)
    return { ...conversation }
  }
  listConversations(): ConversationRecord[] {
    if (this.failList) throw new Error('private database failure')
    return this.conversations.map((item) => ({ ...item }))
  }
  getConversation(id: string): ConversationRecord | null {
    const conversation = this.conversations.find((item) => item.id === id)
    return conversation ? { ...conversation } : null
  }
  listMessages(conversationId: string, afterSeq: number, limit = 200): MessageRecord[] {
    this.listReads += 1
    this.onRead?.()
    return this.messages.filter((item) => item.conversationId === conversationId && item.seq > afterSeq)
      .slice(0, limit).map((item) => ({ ...item }))
  }
  appendUserMessage(input: InsertMessageInput): MessageWithRun {
    const previous = this.messages.find((item) => input.clientRequestId !== null &&
      item.conversationId === input.conversationId && item.clientRequestId === input.clientRequestId)
    if (previous) {
      const run = this.runs.find((item) => item.messageId === previous.id)!
      return { message: { ...previous }, run: { ...run }, created: false }
    }
    const timestamp = new Date().toISOString()
    const seq = this.messages.filter((item) => item.conversationId === input.conversationId).length + 1
    const message = { ...input, id: randomUUID(), seq, createdAt: timestamp }
    const run: RunRecord = {
      id: randomUUID(), conversationId: input.conversationId, messageId: message.id, status: 'queued',
      leaseToken: null, leasedUntil: null, createdAt: timestamp, startedAt: null, finishedAt: null,
      resultText: null, error: null,
    }
    this.messages.push(message)
    this.runs.push(run)
    this.conversations.find((item) => item.id === input.conversationId)!.updatedAt = timestamp
    return { message: { ...message }, run: { ...run }, created: true }
  }
  goalContextForRun(): null { return null }
  getRun(id: string): RunRecord | null {
    const run = this.runs.find((item) => item.id === id)
    return run ? { ...run } : null
  }
  leaseRun({ leaseMs }: { leaseMs: number }): RunLease | null {
    this.lastLeaseMs = leaseMs
    if (this.runs.some((item) => item.status === 'running')) return null
    const run = this.runs.find((item) => item.status === 'queued')
    if (!run) return null
    run.status = 'running'
    run.leaseToken = randomUUID()
    run.startedAt = new Date().toISOString()
    run.leasedUntil = new Date(Date.now() + leaseMs).toISOString()
    return { run: { ...run }, leaseToken: run.leaseToken }
  }
  completeRun(id: string, leaseToken: string, input: CompleteRunInput): RunRecord | null {
    const run = this.runs.find((item) => item.id === id)
    if (!run || run.status !== 'running' || run.leaseToken !== leaseToken ||
      Date.parse(run.leasedUntil!) <= Date.now()) return null
    run.status = input.status
    run.resultText = input.resultText ?? null
    run.error = input.error ?? null
    run.finishedAt = new Date().toISOString()
    run.leaseToken = null
    run.leasedUntil = null
    if (input.status === 'completed' && input.resultText) {
      const seq = this.messages.filter((item) => item.conversationId === run.conversationId).length + 1
      this.messages.push({ id: randomUUID(), conversationId: run.conversationId, role: 'assistant',
        text: input.resultText, clientRequestId: null, seq, createdAt: run.finishedAt })
    }
    return { ...run }
  }
  cancelRun(id: string): RunRecord | null {
    const run = this.runs.find((item) => item.id === id)
    if (!run) return null
    if (run.status === 'queued' || run.status === 'running') {
      run.status = 'canceled'
      run.finishedAt = new Date().toISOString()
      run.leaseToken = null
      run.leasedUntil = null
    }
    return { ...run }
  }
  listGoals(_status?: import('../src/types.ts').GoalStatus, _after?: number, _limit?: number): { goals: import('../src/types.ts').GoalListItem[]; nextCursor: number | null } { return { goals: [], nextCursor: null } }
  getGoalView(_id: string): import('../src/types.ts').GoalView | null { return null }
  createGoal(_input: CreateGoalInput): import('../src/types.ts').CommandResult<import('../src/types.ts').GoalRecord> { throw new Error('business store not enabled in this test double') }
  updateGoal(_id: string, _input: GoalCommandInput): import('../src/types.ts').CommandResult<import('../src/types.ts').GoalRecord> | null { return null }
  createTask(_goalId: string, _input: CreateTaskInput): import('../src/types.ts').CommandResult<import('../src/types.ts').TaskRecord> | null { return null }
  getTask(_id: string): import('../src/types.ts').TaskView | null { return null }
  updateTask(_id: string, _input: TaskCommandInput): import('../src/types.ts').CommandResult<import('../src/types.ts').TaskRecord> | null { return null }
  requeueExpiredLeases(): number {
    let count = 0
    for (const run of this.runs) {
      if (run.status === 'running' && Date.parse(run.leasedUntil!) <= Date.now()) {
        run.status = 'queued'
        run.leaseToken = null
        run.leasedUntil = null
        count += 1
      }
    }
    return count
  }
}

interface CallOptions {
  method?: string
  token?: string
  body?: unknown
  raw?: string | Buffer
  headers?: Record<string, string>
}

async function setup(t: TestContext, model?: string) {
  const store = new MemoryStore()
  const now = new Date('2026-11-25T01:00:00.000Z')
  const server = createV2Server({ store, adminSecret: 'test-pair-secret', model, now: () => now })
  server.listen(0, '127.0.0.1')
  await once(server, 'listening')
  const address = server.address()
  assert.ok(address && typeof address === 'object')
  const base = `http://127.0.0.1:${address.port}`
  t.after(async () => {
    const closing = new Promise<void>((resolve, reject) => server.close((error) => error ? reject(error) : resolve()))
    server.closeAllConnections()
    await closing
    store.close()
  })
  async function call(path: string, options: CallOptions = {}) {
    const body = options.raw ?? (options.body === undefined ? undefined : JSON.stringify(options.body))
    const response = await fetch(base + path, {
      method: options.method ?? 'GET',
      headers: {
        ...(body === undefined ? {} : { 'content-type': 'application/json' }),
        ...(options.token ? { authorization: `Bearer ${options.token}` } : {}),
        ...options.headers,
      },
      body,
    })
    return { status: response.status, headers: response.headers, json: await response.json() as Record<string, any> }
  }
  async function pair(role: DeviceRole = 'client') {
    const response = await call('/v2/pair', { method: 'POST', headers: { 'x-pair-secret': 'test-pair-secret' },
      body: { name: `${role} device`, role } })
    assert.equal(response.status, 201)
    return response.json.token as string
  }
  async function conversation(token: string) {
    const response = await call('/v2/conversations', { method: 'POST', token, body: { title: 'Test' } })
    assert.equal(response.status, 201)
    return response.json.conversation.id as string
  }
  async function message(token: string, id: string, key: string = randomUUID()) {
    return call(`/v2/conversations/${id}/messages`, { method: 'POST', token, body: { clientRequestId: key, text: 'Hello' } })
  }
  return { store, server, base, now, call, pair, conversation, message }
}

function errorIs(response: { status: number; json: Record<string, any> }, status: number, code: string) {
  assert.equal(response.status, status)
  assert.deepEqual(Object.keys(response.json), ['error'])
  assert.equal(response.json.error.code, code)
  assert.equal(typeof response.json.error.message, 'string')
  assert.ok(response.json.error.message.length > 0)
}

test('public health reports protocol v2 without exposing credentials', async (t) => {
  const { call } = await setup(t)
  const response = await call('/v2/health')
  assert.equal(response.status, 200)
  assert.deepEqual(response.json, { ok: true, service: 'personal-os-cloud', protocolVersion: 2, dbPath: ':memory:' })
  assert.equal(response.headers.get('content-type'), 'application/json; charset=utf-8')
  assert.equal(response.headers.get('cache-control'), 'no-store')
  assert.doesNotMatch(JSON.stringify(response.json), /test-pair-secret/)
})

test('public health optionally reports only the configured model identifier', async (t) => {
  const { call } = await setup(t, '  gpt-6.1-sol  ')
  const response = await call('/v2/health')
  assert.equal(response.status, 200)
  assert.deepEqual(response.json, {
    ok: true, service: 'personal-os-cloud', protocolVersion: 2, dbPath: ':memory:', model: 'gpt-6.1-sol',
  })
  assert.equal(response.headers.get('cache-control'), 'no-store')
})

test('model metadata rejects empty, multiline and credential URL values', () => {
  for (const model of ['', '  ', 'model\nprivate', 'https://user@provider.invalid/model', 'x'.repeat(201)]) {
    assert.throws(() => createV2Server({ store: new MemoryStore(), adminSecret: 'test-only', model }), /model must be/)
  }
})

test('pair requires the secret, returns random tokens once, and stores only SHA-256', async (t) => {
  const { call, pair, store, now } = await setup(t)
  errorIs(await call('/v2/pair', { method: 'POST', body: { name: 'Phone', role: 'client' } }), 401, 'unauthorized')
  errorIs(await call('/v2/pair', { method: 'POST', headers: { 'x-pair-secret': 'wrong' }, body: {} }), 401, 'unauthorized')
  const token = await pair()
  const second = await pair('agent')
  assert.notEqual(token, second)
  assert.ok(token.length >= 32)
  assert.equal(store.devices[0].tokenHash, hashToken(token))
  assert.notEqual(store.devices[0].tokenHash, token)
  const me = await call('/v2/me', { token })
  assert.equal(me.status, 200)
  assert.equal(me.json.device.role, 'client')
  assert.equal(me.json.device.lastSeenAt, now.toISOString())
  assert.equal(store.touches, 1)
  assert.equal('tokenHash' in me.json.device, false)
  assert.equal('token' in me.json, false)
  assert.doesNotMatch(JSON.stringify(me.json), new RegExp(token))
})

test('missing, malformed, unknown and revoked bearer tokens return 401', async (t) => {
  const { call, pair, store } = await setup(t)
  for (const authorization of ['', 'Basic abc', 'Bearer', 'Bearer invalid', 'Bearer a b']) {
    errorIs(await call('/v2/me', { headers: { authorization } }), 401, 'unauthorized')
  }
  const token = await pair()
  store.devices[0].revokedAt = new Date().toISOString()
  errorIs(await call('/v2/me', { token }), 401, 'unauthorized')
  assert.equal(store.touches, 0)
  errorIs(await call('/v2/unknown'), 401, 'unauthorized')
})

test('both device roles can create/list conversations and only agents can lease/complete', async (t) => {
  const { call, pair, conversation } = await setup(t)
  const client = await pair()
  const agent = await pair('agent')
  await conversation(client)
  await conversation(agent)
  assert.equal((await call('/v2/conversations', { token: client })).json.conversations.length, 2)
  assert.equal((await call('/v2/conversations', { token: agent })).json.conversations.length, 2)
  errorIs(await call('/v2/runs/lease', { method: 'POST', token: client, body: {} }), 403, 'forbidden')
  errorIs(await call('/v2/runs/missing/complete', { method: 'POST', token: client, body: {} }), 403, 'forbidden')
  const result = await call('/v2/runs/lease', { method: 'POST', token: agent, body: {} })
  assert.equal(result.status, 200)
  assert.deepEqual(result.json, { run: null, leaseToken: null })
})

test('message idempotency returns 201 then 200 and independent conversation cursors', async (t) => {
  const { call, pair, conversation, message, store } = await setup(t)
  const token = await pair()
  const id = await conversation(token)
  const first = await message(token, id, 'same-key')
  const replay = await call(`/v2/conversations/${id}/messages`, { method: 'POST', token,
    body: { clientRequestId: 'same-key', text: 'Changed replay text' } })
  assert.equal(first.status, 201)
  assert.equal(first.json.created, true)
  assert.equal(replay.status, 200)
  assert.equal(replay.json.created, false)
  assert.deepEqual(replay.json.message, first.json.message)
  assert.deepEqual(replay.json.run, first.json.run)
  assert.equal(store.messages.length, 1)
  assert.equal(store.runs.length, 1)
  const second = await message(token, id)
  assert.equal(second.json.message.seq, 2)
  const stream = await call(`/v2/conversations/${id}/messages?after=1`, { token })
  assert.deepEqual(stream.json.messages.map((item: MessageRecord) => item.seq), [2])
  assert.equal(stream.json.nextCursor, 2)
  const other = await conversation(token)
  assert.equal((await message(token, other, 'same-key')).json.message.seq, 1)
})

test('lease/complete publishes the assistant result through the same message stream', async (t) => {
  const { call, pair, conversation, message, store } = await setup(t)
  const client = await pair()
  const agent = await pair('agent')
  const id = await conversation(client)
  const queued = await message(client, id)
  const runId = queued.json.run.id
  assert.equal((await call(`/v2/runs/${runId}`, { token: client })).json.run.status, 'queued')
  const leased = await call('/v2/runs/lease', { method: 'POST', token: agent })
  assert.equal(leased.status, 200)
  assert.equal(leased.json.run.status, 'running')
  assert.equal(store.lastLeaseMs, 30_000)
  assert.deepEqual((await call('/v2/runs/lease', { method: 'POST', token: agent, body: { leaseMs: 5000 } })).json,
    { run: null, leaseToken: null })
  errorIs(await call(`/v2/runs/${runId}/complete`, { method: 'POST', token: agent,
    body: { leaseToken: 'wrong', status: 'completed' } }), 409, 'conflict')
  const result = await call(`/v2/runs/${runId}/complete`, { method: 'POST', token: agent,
    body: { leaseToken: leased.json.leaseToken, status: 'completed', resultText: 'Assistant reply' } })
  assert.equal(result.status, 200)
  assert.equal(result.json.run.status, 'completed')
  const stream = await call(`/v2/conversations/${id}/messages?after=1`, { token: client })
  assert.equal(stream.status, 200)
  assert.deepEqual(stream.json.messages.map((item: MessageRecord) => [item.role, item.text, item.seq]),
    [['assistant', 'Assistant reply', 2]])
  assert.equal(stream.json.nextCursor, 2)
  errorIs(await call(`/v2/runs/${runId}/complete`, { method: 'POST', token: agent,
    body: { leaseToken: leased.json.leaseToken, status: 'completed' } }), 409, 'conflict')
})

test('failed completion and cancellation preserve terminal runs and reject stale leases', async (t) => {
  const { call, pair, conversation, message } = await setup(t)
  const client = await pair()
  const agent = await pair('agent')
  const id = await conversation(client)
  const queued = await message(client, id)
  const runId = queued.json.run.id
  const leased = await call('/v2/runs/lease', { method: 'POST', token: agent, body: { leaseMs: 10_000 } })
  const failed = await call(`/v2/runs/${runId}/complete`, { method: 'POST', token: agent,
    body: { leaseToken: leased.json.leaseToken, status: 'failed', error: 'Agent failed' } })
  assert.equal(failed.status, 200)
  assert.equal(failed.json.run.error, 'Agent failed')
  assert.equal((await call(`/v2/runs/${runId}/cancel`, { method: 'POST', token: client })).json.run.status, 'failed')
  const second = (await message(client, id)).json.run.id
  const canceled = await call(`/v2/runs/${second}/cancel`, { method: 'POST', token: client })
  assert.equal(canceled.json.run.status, 'canceled')
  assert.deepEqual((await call(`/v2/runs/${second}/cancel`, { method: 'POST', token: agent })).json, canceled.json)
  const third = (await message(client, id)).json.run.id
  const running = await call('/v2/runs/lease', { method: 'POST', token: agent, body: {} })
  assert.equal((await call(`/v2/runs/${third}/cancel`, { method: 'POST', token: client })).json.run.status, 'canceled')
  errorIs(await call(`/v2/runs/${third}/complete`, { method: 'POST', token: agent,
    body: { leaseToken: running.json.leaseToken, status: 'completed' } }), 409, 'conflict')
})

test('long poll returns existing messages immediately', async (t) => {
  const { call, pair, conversation, message, store } = await setup(t)
  const token = await pair()
  const id = await conversation(token)
  await message(token, id)
  const response = await call(`/v2/conversations/${id}/messages?after=0&wait=25`, { token })
  assert.equal(response.json.messages.length, 1)
  assert.equal(response.json.nextCursor, 1)
  assert.equal(store.listReads, 1)
})

test('long poll checks again at 250ms and returns a newly posted message', async (t) => {
  const { call, pair, conversation, message, store } = await setup(t)
  const token = await pair()
  const id = await conversation(token)
  let observed!: () => void
  const firstRead = new Promise<void>((resolve) => { observed = resolve })
  store.onRead = observed
  const waiting = call(`/v2/conversations/${id}/messages?after=0&wait=2`, { token })
  await firstRead
  await message(token, id)
  const response = await waiting
  assert.equal(response.status, 200)
  assert.equal(response.json.messages[0].text, 'Hello')
  assert.equal(response.json.nextCursor, 1)
  assert.equal(store.listReads, 2)
})

test('long poll timeout returns an empty array and preserves the cursor', async (t) => {
  const { call, pair, conversation, store } = await setup(t)
  const token = await pair()
  const id = await conversation(token)
  const started = performance.now()
  const response = await call(`/v2/conversations/${id}/messages?after=7&wait=0.05`, { token })
  assert.equal(response.status, 200)
  assert.deepEqual(response.json, { messages: [], nextCursor: 7 })
  assert.ok(performance.now() - started >= 35)
  assert.ok(store.listReads >= 2)
})

test('disconnecting a long poll cancels further polling', async (t) => {
  const { call, pair, conversation, store, base } = await setup(t)
  const token = await pair()
  const id = await conversation(token)
  let observed!: () => void
  const firstRead = new Promise<void>((resolve) => { observed = resolve })
  store.onRead = observed
  const request = httpRequest(`${base}/v2/conversations/${id}/messages?wait=25`, {
    headers: { authorization: `Bearer ${token}` },
  })
  request.on('error', () => {})
  request.end()
  await firstRead
  const closed = new Promise<void>((resolve) => request.once('close', resolve))
  request.destroy()
  await closed
  const readsAtClose = store.listReads
  await delay(350)
  assert.equal(store.listReads, readsAtClose)
  assert.equal((await call('/v2/health')).status, 200)
})

test('malformed JSON, non-object bodies and invalid UTF-8 consistently return 400', async (t) => {
  const { call, pair } = await setup(t)
  const token = await pair()
  for (const raw of ['', '{', '{"title":}', Buffer.from([0x7b, 0x22, 0x78, 0x22, 0x3a, 0x22, 0xff, 0x22, 0x7d])]) {
    errorIs(await call('/v2/conversations', { method: 'POST', token, raw }), 400, 'invalid_json')
  }
  for (const body of [null, [], 3, 'title']) {
    errorIs(await call('/v2/conversations', { method: 'POST', token, body }), 400, 'invalid_request')
  }
  errorIs(await call('/v2/conversations', { method: 'POST', token, body: {},
    headers: { 'content-type': 'text/plain' } }), 400, 'invalid_request')
})

test('JSON body larger than 1 MB returns the standard 413 envelope', async (t) => {
  const { call, pair } = await setup(t)
  const token = await pair()
  errorIs(await call('/v2/conversations', { method: 'POST', token, body: { title: 'x'.repeat(1024 * 1024) } }),
    413, 'payload_too_large')
  assert.equal((await call('/v2/health')).status, 200)
})

test('path and query validation rejects malformed values and ambiguous parameters', async (t) => {
  const { call, pair, conversation } = await setup(t)
  const token = await pair()
  const id = await conversation(token)
  for (const query of ['after=-1', 'after=1.5', 'after=9007199254740992', 'after=', 'after=NaN',
    'wait=-1', 'wait=26', 'wait=Infinity', 'wait=', 'after=0&after=1', 'wait=0&wait=1', 'other=1']) {
    errorIs(await call(`/v2/conversations/${id}/messages?${query}`, { token }), 400, 'invalid_request')
  }
  for (const path of ['/v2/conversations/%ZZ/messages', '/v2/conversations/%2F/messages',
    '/v2/conversations//messages', '/v2/runs/%20', '/v2/runs/%5C']) {
    errorIs(await call(path, { token }), 400, 'invalid_request')
  }
  errorIs(await call('/v2/me?unexpected=1', { token }), 400, 'invalid_request')
})

test('request field validation covers pair, conversation, message, lease and completion', async (t) => {
  const { call, pair, conversation, message } = await setup(t)
  for (const body of [{ name: 'x', role: 'admin' }, { name: ' ', role: 'client' }, { name: 1, role: 'client' },
    { name: 'x', role: 'client', tokenHash: 'injected' }]) {
    errorIs(await call('/v2/pair', { method: 'POST', headers: { 'x-pair-secret': 'test-pair-secret' }, body }),
      400, 'invalid_request')
  }
  const token = await pair('agent')
  const id = await conversation(token)
  for (const body of [{ title: 1 }, { ownerId: 'injected' }]) {
    errorIs(await call('/v2/conversations', { method: 'POST', token, body }), 400, 'invalid_request')
  }
  for (const body of [{ text: 'hello' }, { clientRequestId: 'key', text: ' ' },
    { clientRequestId: '', text: 'hello' }, { clientRequestId: 'key', text: 5 },
    { clientRequestId: 'key', text: 'hello', role: 'assistant' }]) {
    errorIs(await call(`/v2/conversations/${id}/messages`, { method: 'POST', token, body }), 400, 'invalid_request')
  }
  for (const leaseMs of [0, -1, 1.5, '30000', null, 86_400_001, Number.MAX_SAFE_INTEGER + 1]) {
    errorIs(await call('/v2/runs/lease', { method: 'POST', token, body: { leaseMs } }), 400, 'invalid_request')
  }
  const runId = (await message(token, id)).json.run.id
  for (const body of [{ leaseToken: 'x', status: 'running' }, { leaseToken: '', status: 'completed' },
    { leaseToken: 'x', status: 'canceled' }, { leaseToken: 'x', status: 'completed', resultText: 1 },
    { leaseToken: 'x', status: 'failed', error: false }]) {
    errorIs(await call(`/v2/runs/${runId}/complete`, { method: 'POST', token, body }), 400, 'invalid_request')
  }
  errorIs(await call(`/v2/runs/${runId}/cancel`, { method: 'POST', token, body: { extra: true } }),
    400, 'invalid_request')
})

test('missing resources and unknown routes return 404; store failures return a safe 500', async (t) => {
  const { call, pair, store } = await setup(t)
  const token = await pair('agent')
  for (const [method, path, body] of [
    ['GET', '/v2/conversations/missing/messages', undefined],
    ['POST', '/v2/conversations/missing/messages', { clientRequestId: 'x', text: 'Hello' }],
    ['GET', '/v2/runs/missing', undefined], ['POST', '/v2/runs/missing/cancel', undefined],
    ['POST', '/v2/runs/missing/complete', { leaseToken: 'x', status: 'completed' }],
    ['GET', '/v2/unknown', undefined], ['DELETE', '/v2/conversations', undefined],
  ] as const) {
    errorIs(await call(path, { method, token, body }), 404, 'not_found')
  }
  store.failList = true
  const failed = await call('/v2/conversations', { token })
  errorIs(failed, 500, 'internal_error')
  assert.doesNotMatch(JSON.stringify(failed.json), /private database failure/)
})

test('server creation rejects an empty admin secret', () => {
  assert.throws(() => createV2Server({ store: new MemoryStore(), adminSecret: '' }), /adminSecret/)
})
