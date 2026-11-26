import assert from 'node:assert/strict'
import { createHash } from 'node:crypto'
import { DatabaseSync } from 'node:sqlite'
import { mkdtempSync, rmSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { basename, dirname, join } from 'node:path'
import { test } from 'node:test'
import type { TestContext } from 'node:test'
import { CloudStore } from '../src/store.ts'
import { createV2Server } from '../src/server.ts'

const PAIR_SECRET = 'contract-e2e-pair-secret-never-echo'
const INVALID_LEASE_TOKEN = 'contract-e2e-invalid-lease-token-never-echo'
const PRIVATE_ERROR = 'contract-e2e-private-database-error-never-echo'

function exactKeys(value: object, expected: string[]): void {
  assert.deepEqual(Object.keys(value).sort(), [...expected].sort())
}

function assertOpaqueId(value: unknown): asserts value is string {
  assert.ok(typeof value === 'string')
  assert.match(value, /^[A-Za-z0-9_-]+$/)
}

function assertIsoDate(value: unknown): asserts value is string {
  assert.ok(typeof value === 'string')
  assert.ok(Number.isFinite(Date.parse(value)))
}

function assertDevice(
  device: Record<string, any>,
  name: string,
  role: 'client' | 'agent',
  lastSeenAt: string | null = null,
): void {
  exactKeys(device, ['id', 'name', 'role', 'createdAt', 'lastSeenAt', 'revokedAt'])
  assertOpaqueId(device.id)
  assert.equal(device.name, name)
  assert.equal(device.role, role)
  assertIsoDate(device.createdAt)
  assert.equal(device.lastSeenAt, lastSeenAt)
  assert.equal(device.revokedAt, null)
  assert.equal('tokenHash' in device, false)
}

function assertConversation(conversation: Record<string, any>, title: string): void {
  exactKeys(conversation, ['id', 'ownerId', 'title', 'createdAt', 'updatedAt'])
  assertOpaqueId(conversation.id)
  assert.equal(conversation.ownerId, 'default')
  assert.equal(conversation.title, title)
  assertIsoDate(conversation.createdAt)
  assertIsoDate(conversation.updatedAt)
}

function assertMessage(message: Record<string, any>, expected: {
  conversationId: string
  role: 'user' | 'assistant'
  text: string
  clientRequestId: string | null
  seq: number
}): void {
  exactKeys(message, ['id', 'conversationId', 'role', 'text', 'clientRequestId', 'seq', 'createdAt'])
  assertOpaqueId(message.id)
  assert.equal(message.conversationId, expected.conversationId)
  assert.equal(message.role, expected.role)
  assert.equal(message.text, expected.text)
  assert.equal(message.clientRequestId, expected.clientRequestId)
  assert.equal(message.seq, expected.seq)
  assertIsoDate(message.createdAt)
}

function assertRun(run: Record<string, any>, expected: {
  conversationId: string
  messageId: string
  status: 'queued' | 'running' | 'completed'
  leaseToken: string | null
  resultText: string | null
}): void {
  exactKeys(run, ['id', 'conversationId', 'messageId', 'status', 'leaseToken', 'leasedUntil',
    'createdAt', 'startedAt', 'finishedAt', 'resultText', 'error'])
  assertOpaqueId(run.id)
  assert.equal(run.conversationId, expected.conversationId)
  assert.equal(run.messageId, expected.messageId)
  assert.equal(run.status, expected.status)
  assert.equal(run.leaseToken, expected.leaseToken)
  assert.equal(run.resultText, expected.resultText)
  assert.equal(run.error, null)
  assertIsoDate(run.createdAt)
  if (expected.status === 'queued') {
    assert.equal(run.leasedUntil, null)
    assert.equal(run.startedAt, null)
    assert.equal(run.finishedAt, null)
  } else if (expected.status === 'running') {
    assertIsoDate(run.leasedUntil)
    assertIsoDate(run.startedAt)
    assert.equal(run.finishedAt, null)
  } else {
    assert.equal(run.leasedUntil, null)
    assertIsoDate(run.startedAt)
    assertIsoDate(run.finishedAt)
  }
}

test('v2 frozen contract works end-to-end over HTTP and SQLite without leaking sensitive fields', async (t: TestContext) => {
  const directory = mkdtempSync(join(tmpdir(), 'cloud-v2-contract-e2e-'))
  const dbPath = join(directory, 'cloud.sqlite')
  const store = new CloudStore(dbPath)
  const server = createV2Server({ store, adminSecret: PAIR_SECRET })
  let storeClosed = false
  t.after(async () => {
    await new Promise<void>((resolve, reject) => {
      if (!server.listening) return resolve()
      server.close((error) => error ? reject(error) : resolve())
      server.closeAllConnections()
    })
    if (!storeClosed) store.close()
    assert.equal(dirname(directory), tmpdir())
    assert.ok(basename(directory).startsWith('cloud-v2-contract-e2e-'))
    rmSync(directory, { recursive: true, force: true })
  })

  await new Promise<void>((resolve, reject) => {
    server.once('error', reject)
    server.listen(0, '127.0.0.1', () => {
      server.off('error', reject)
      resolve()
    })
  })
  const address = server.address()
  assert.ok(address && typeof address !== 'string')
  const baseUrl = `http://127.0.0.1:${address.port}`

  async function call(path: string, options: {
    token?: string
    method?: 'GET' | 'POST'
    body?: unknown
    pairSecret?: string
  } = {}) {
    const response = await fetch(`${baseUrl}${path}`, {
      method: options.method ?? 'GET',
      headers: {
        ...(options.token ? { authorization: `Bearer ${options.token}` } : {}),
        ...(options.pairSecret ? { 'x-pair-secret': options.pairSecret } : {}),
        ...(options.body !== undefined ? { 'content-type': 'application/json' } : {}),
      },
      body: options.body === undefined ? undefined : JSON.stringify(options.body),
      signal: AbortSignal.timeout(8_000),
    })
    return {
      status: response.status,
      headers: response.headers,
      data: await response.json() as Record<string, any>,
    }
  }

  const health = await call('/v2/health')
  assert.equal(health.status, 200)
  exactKeys(health.data, ['ok', 'service', 'protocolVersion', 'dbPath'])
  assert.deepEqual(health.data, {
    ok: true, service: 'personal-os-cloud', protocolVersion: 2, dbPath,
  })
  assert.equal(health.headers.get('cache-control'), 'no-store')
  assert.equal(JSON.stringify(health.data).includes(PAIR_SECRET), false)

  async function pair(name: string, role: 'client' | 'agent') {
    const response = await call('/v2/pair', {
      method: 'POST', pairSecret: PAIR_SECRET, body: { name, role },
    })
    assert.equal(response.status, 201)
    exactKeys(response.data, ['device', 'token'])
    assert.equal(typeof response.data.token, 'string')
    assert.ok(response.data.token.length >= 32)
    assertDevice(response.data.device, name, role)
    assert.equal(JSON.stringify(response.data.device).includes(response.data.token), false)
    assert.equal(JSON.stringify(response.data.device).includes(PAIR_SECRET), false)
    return { token: response.data.token as string, device: response.data.device as Record<string, any> }
  }

  const client = await pair('contract-client', 'client')
  const agent = await pair('contract-agent', 'agent')
  assert.notEqual(client.token, agent.token)
  assert.notEqual(client.device.id, agent.device.id)
  const inspection = new DatabaseSync(dbPath, { readOnly: true })
  try {
    const storedHashes = inspection.prepare('SELECT token_hash AS tokenHash FROM devices ORDER BY name')
      .all() as Array<{ tokenHash: string }>
    assert.deepEqual(storedHashes.map(({ tokenHash }) => tokenHash), [
      agent.token, client.token,
    ].map((token) => createHash('sha256').update(token).digest('hex')))
    assert.ok(storedHashes.every(({ tokenHash }) => tokenHash !== client.token && tokenHash !== agent.token))
  } finally {
    inspection.close()
  }

  const identity = await call('/v2/me', { token: client.token })
  assert.equal(identity.status, 200)
  exactKeys(identity.data, ['device'])
  assert.equal(identity.data.device.id, client.device.id)
  assertIsoDate(identity.data.device.lastSeenAt)
  assertDevice(identity.data.device, 'contract-client', 'client', identity.data.device.lastSeenAt)
  assert.equal(JSON.stringify(identity.data).includes(client.token), false)

  const created = await call('/v2/conversations', {
    method: 'POST', token: client.token, body: { title: 'contract conversation' },
  })
  assert.equal(created.status, 201)
  exactKeys(created.data, ['conversation'])
  assertConversation(created.data.conversation, 'contract conversation')
  const conversationId = created.data.conversation.id as string

  const listed = await call('/v2/conversations', { token: agent.token })
  assert.equal(listed.status, 200)
  exactKeys(listed.data, ['conversations'])
  assert.ok(Array.isArray(listed.data.conversations))
  assert.deepEqual(listed.data.conversations.map((item: Record<string, unknown>) => item.id), [conversationId])
  assertConversation(listed.data.conversations[0], 'contract conversation')

  const messagesPath = `/v2/conversations/${conversationId}/messages`
  const sent = await call(messagesPath, {
    method: 'POST', token: client.token,
    body: { clientRequestId: 'contract-request-1', text: 'hello from client' },
  })
  assert.equal(sent.status, 201)
  exactKeys(sent.data, ['message', 'run', 'created'])
  assert.equal(sent.data.created, true)
  assertMessage(sent.data.message, {
    conversationId, role: 'user', text: 'hello from client', clientRequestId: 'contract-request-1', seq: 1,
  })
  assertRun(sent.data.run, {
    conversationId, messageId: sent.data.message.id, status: 'queued', leaseToken: null, resultText: null,
  })

  const replay = await call(messagesPath, {
    method: 'POST', token: agent.token,
    body: { clientRequestId: 'contract-request-1', text: 'changed retry text' },
  })
  assert.equal(replay.status, 200)
  exactKeys(replay.data, ['message', 'run', 'created'])
  assert.equal(replay.data.created, false)
  assert.deepEqual(replay.data.message, sent.data.message)
  assert.deepEqual(replay.data.run, sent.data.run)

  const forbiddenLease = await call('/v2/runs/lease', {
    method: 'POST', token: client.token, body: { leaseMs: 5_000 },
  })
  assert.equal(forbiddenLease.status, 403)
  exactKeys(forbiddenLease.data, ['error'])
  exactKeys(forbiddenLease.data.error, ['code', 'message'])
  assert.equal(forbiddenLease.data.error.code, 'forbidden')
  assert.equal(JSON.stringify(forbiddenLease.data).includes(client.token), false)
  assert.equal(JSON.stringify(forbiddenLease.data).includes(PAIR_SECRET), false)

  const leased = await call('/v2/runs/lease', {
    method: 'POST', token: agent.token, body: { leaseMs: 5_000 },
  })
  assert.equal(leased.status, 200)
  exactKeys(leased.data, ['run', 'leaseToken'])
  assert.equal(typeof leased.data.leaseToken, 'string')
  assertRun(leased.data.run, {
    conversationId, messageId: sent.data.message.id, status: 'running',
    leaseToken: leased.data.leaseToken, resultText: null,
  })
  const runId = leased.data.run.id as string

  const completePath = `/v2/runs/${runId}/complete`
  const rejected = await call(completePath, {
    method: 'POST', token: agent.token,
    body: {
      leaseToken: INVALID_LEASE_TOKEN, status: 'completed',
      resultText: PRIVATE_ERROR,
    },
  })
  assert.equal(rejected.status, 409)
  exactKeys(rejected.data, ['error'])
  exactKeys(rejected.data.error, ['code', 'message'])
  assert.equal(rejected.data.error.code, 'conflict')
  for (const secret of [PAIR_SECRET, client.token, agent.token, leased.data.leaseToken,
    INVALID_LEASE_TOKEN, PRIVATE_ERROR]) {
    assert.equal(JSON.stringify(rejected.data).includes(secret), false)
  }

  const waitingForAssistant = call(`${messagesPath}?after=1&wait=5`, { token: agent.token })
  const completed = await call(completePath, {
    method: 'POST', token: agent.token,
    body: { leaseToken: leased.data.leaseToken, status: 'completed', resultText: 'assistant reply' },
  })
  assert.equal(completed.status, 200)
  exactKeys(completed.data, ['run'])
  assertRun(completed.data.run, {
    conversationId, messageId: sent.data.message.id, status: 'completed', leaseToken: null,
    resultText: 'assistant reply',
  })
  assert.equal(JSON.stringify(completed.data).includes(leased.data.leaseToken), false)

  const polled = await waitingForAssistant
  assert.equal(polled.status, 200)
  exactKeys(polled.data, ['messages', 'nextCursor'])
  assert.equal(polled.data.nextCursor, 2)
  assert.equal(polled.data.messages.length, 1)
  assertMessage(polled.data.messages[0], {
    conversationId, role: 'assistant', text: 'assistant reply', clientRequestId: null, seq: 2,
  })

  const emptyCursor = await call(`${messagesPath}?after=2&wait=0`, { token: client.token })
  assert.equal(emptyCursor.status, 200)
  assert.deepEqual(emptyCursor.data, { messages: [], nextCursor: 2 })

  // A closed SQLite connection forces an internal storage exception; only the stable public error envelope may escape.
  store.close()
  storeClosed = true
  const failedStorage = await call('/v2/me', { token: client.token })
  assert.equal(failedStorage.status, 500)
  assert.deepEqual(failedStorage.data, {
    error: { code: 'internal_error', message: 'Internal server error.' },
  })
  for (const secret of [PAIR_SECRET, client.token, agent.token, leased.data.leaseToken,
    INVALID_LEASE_TOKEN, PRIVATE_ERROR, 'database is not open']) {
    assert.equal(JSON.stringify(failedStorage.data).includes(secret), false)
  }
})
