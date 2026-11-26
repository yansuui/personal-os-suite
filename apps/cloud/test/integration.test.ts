import assert from 'node:assert/strict'
import { mkdtempSync, rmSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { basename, dirname, join } from 'node:path'
import { test } from 'node:test'
import type { TestContext } from 'node:test'
import { CloudStore } from '../src/store.ts'
import { createV2Server } from '../src/server.ts'

const SECRET = 'integration-only-pair-secret'

async function listen(t: TestContext, store: CloudStore, now?: () => Date) {
  const server = createV2Server({ store, adminSecret: SECRET, now })
  await new Promise<void>((resolve, reject) => {
    server.once('error', reject)
    server.listen(0, '127.0.0.1', () => {
      server.off('error', reject)
      resolve()
    })
  })
  const address = server.address()
  assert.ok(address && typeof address !== 'string')
  const base = `http://127.0.0.1:${address.port}`
  let stopped = false
  const stop = async () => {
    if (stopped) return
    stopped = true
    await new Promise<void>((resolve, reject) => {
      server.close((error) => error ? reject(error) : resolve())
      server.closeAllConnections()
    })
    store.close()
  }
  t.after(stop)
  async function request(path: string, token?: string, body?: unknown, headers: Record<string, string> = {}) {
    const response = await fetch(`${base}${path}`, {
      method: body === undefined ? 'GET' : 'POST',
      headers: {
        ...(token ? { authorization: `Bearer ${token}` } : {}),
        ...(body !== undefined ? { 'content-type': 'application/json' } : {}),
        ...headers,
      },
      body: body === undefined ? undefined : JSON.stringify(body),
      signal: AbortSignal.timeout(8_000),
    })
    // Runtime assertions below validate these wire shapes independently of the store implementation.
    const data = await response.json() as Record<string, any>
    return { status: response.status, data }
  }
  async function pair(name: string, role: 'client' | 'agent') {
    const result = await request('/v2/pair', undefined, { name, role }, { 'x-pair-secret': SECRET })
    assert.equal(result.status, 201)
    assert.equal(typeof result.data.token, 'string')
    assert.equal('tokenHash' in result.data.device, false)
    return result.data.token as string
  }
  return { request, pair, stop }
}

test('real HTTP and SQLite: two clients share a conversation and observe one assistant reply', async (t) => {
  const store = new CloudStore(':memory:')
  const api = await listen(t, store)
  const phone = await api.pair('phone', 'client')
  const desktop = await api.pair('desktop', 'client')
  const agent = await api.pair('cloud-agent', 'agent')
  const created = await api.request('/v2/conversations', phone, { title: 'shared conversation' })
  assert.equal(created.status, 201)
  const conversationId = created.data.conversation.id
  const conversations = await api.request('/v2/conversations', desktop)
  assert.ok(conversations.data.conversations.some((entry: { id: string }) => entry.id === conversationId))
  const messagesPath = `/v2/conversations/${conversationId}/messages`
  const sent = await api.request(messagesPath, phone, { clientRequestId: 'same-request', text: '今天有什么安排' })
  assert.equal(sent.status, 201)
  const retry = await api.request(messagesPath, desktop, { clientRequestId: 'same-request', text: '今天有什么安排' })
  assert.equal(retry.status, 200)
  assert.equal(retry.data.created, false)
  assert.equal(retry.data.message.id, sent.data.message.id)
  assert.equal(retry.data.run.id, sent.data.run.id)
  const forbidden = await api.request('/v2/runs/lease', phone, { leaseMs: 5_000 })
  assert.equal(forbidden.status, 403)
  const lease = await api.request('/v2/runs/lease', agent, { leaseMs: 5_000 })
  assert.equal(lease.status, 200)
  assert.equal(lease.data.run.id, sent.data.run.id)
  const completePath = `/v2/runs/${sent.data.run.id}/complete`
  const wrong = await api.request(completePath, agent, { leaseToken: 'wrong-token', status: 'completed', resultText: 'must not appear' })
  assert.equal(wrong.status, 409)
  const awaitingReply = api.request(`${messagesPath}?after=1&wait=2`, desktop)
  const complete = await api.request(completePath, agent, {
    leaseToken: lease.data.leaseToken, status: 'completed', resultText: '已读取你的安排。',
  })
  assert.equal(complete.status, 200)
  assert.equal(complete.data.run.status, 'completed')
  const replies = await awaitingReply
  assert.equal(replies.status, 200)
  assert.equal(replies.data.nextCursor, 2)
  assert.equal(replies.data.messages.length, 1)
  assert.equal(replies.data.messages[0].role, 'assistant')
  assert.equal(replies.data.messages[0].text, '已读取你的安排。')
  const duplicateComplete = await api.request(completePath, agent, {
    leaseToken: lease.data.leaseToken, status: 'completed', resultText: 'duplicate reply',
  })
  assert.equal(duplicateComplete.status, 409)
  const all = await api.request(`${messagesPath}?after=0`, phone)
  assert.deepEqual(all.data.messages.map((message: { seq: number }) => message.seq), [1, 2])
  const empty = await api.request(`${messagesPath}?after=2&wait=0.02`, phone)
  assert.equal(empty.data.nextCursor, 2)
  assert.deepEqual(empty.data.messages, [])
})

test('real HTTP and SQLite: expired lease is fenced before and after another agent claims it', async (t) => {
  let timestamp = Date.parse('2026-11-25T01:00:00.000Z')
  const now = () => new Date(timestamp)
  const store = new CloudStore(':memory:', now)
  const api = await listen(t, store, now)
  const client = await api.pair('phone', 'client')
  const agent = await api.pair('agent', 'agent')
  const conversation = store.createConversation({})
  const message = store.appendUserMessage({ conversationId: conversation.id, role: 'user', text: 'test', clientRequestId: 'expiry-request' })
  const first = await api.request('/v2/runs/lease', agent, { leaseMs: 100 })
  timestamp += 100
  const path = `/v2/runs/${message.run.id}/complete`
  assert.equal((await api.request(path, agent, { leaseToken: first.data.leaseToken, status: 'completed', resultText: 'expired' })).status, 409)
  const second = await api.request('/v2/runs/lease', agent, { leaseMs: 5_000 })
  assert.equal(second.data.run.id, message.run.id)
  assert.notEqual(second.data.leaseToken, first.data.leaseToken)
  assert.equal((await api.request(path, agent, { leaseToken: first.data.leaseToken, status: 'completed', resultText: 'stale' })).status, 409)
  assert.equal((await api.request(path, agent, { leaseToken: second.data.leaseToken, status: 'completed', resultText: 'current reply' })).status, 200)
  const timeline = await api.request(`/v2/conversations/${conversation.id}/messages?after=1`, client)
  assert.deepEqual(timeline.data.messages.map((entry: { text: string }) => entry.text), ['current reply'])
})

test('real HTTP and SQLite: 205 messages paginate without gaps and survive a service restart', async (t) => {
  const directory = mkdtempSync(join(tmpdir(), 'personal-os-cloud-integration-'))
  const dbPath = join(directory, 'cloud.sqlite')
  let stopFirst: (() => Promise<void>) | undefined
  let stopSecond: (() => Promise<void>) | undefined
  t.after(async () => {
    await stopSecond?.()
    await stopFirst?.()
    assert.equal(dirname(directory), tmpdir())
    assert.ok(basename(directory).startsWith('personal-os-cloud-integration-'))
    rmSync(directory, { recursive: true, force: true })
  })
  const store = new CloudStore(dbPath)
  const first = await listen(t, store)
  stopFirst = first.stop
  const client = await first.pair('persistent-phone', 'client')
  const conversation = store.createConversation({ title: 'persistent' })
  for (let index = 0; index < 205; index += 1) {
    store.appendUserMessage({ conversationId: conversation.id, role: 'user', text: `message ${index + 1}`, clientRequestId: `page-${index}` })
  }
  const path = `/v2/conversations/${conversation.id}/messages`
  const page1 = await first.request(`${path}?after=0`, client)
  assert.equal(page1.data.messages.length, 200)
  assert.equal(page1.data.nextCursor, 200)
  await first.stop()
  const second = await listen(t, new CloudStore(dbPath))
  stopSecond = second.stop
  const restoredIdentity = await second.request('/v2/me', client)
  assert.equal(restoredIdentity.status, 200)
  const page2 = await second.request(`${path}?after=${page1.data.nextCursor}`, client)
  assert.equal(page2.data.messages.length, 5)
  assert.deepEqual(page2.data.messages.map((entry: { seq: number }) => entry.seq), [201, 202, 203, 204, 205])
  const retried = await second.request(path, client, { clientRequestId: 'page-0', text: 'message 1' })
  assert.equal(retried.status, 200)
  assert.equal(retried.data.created, false)
  assert.equal(retried.data.message.seq, 1)
})
