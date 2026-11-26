import assert from 'node:assert/strict'
import { existsSync, mkdtempSync, rmSync } from 'node:fs'
import { basename, dirname, join } from 'node:path'
import { DatabaseSync } from 'node:sqlite'
import { test } from 'node:test'
import type { TestContext } from 'node:test'
import { CloudStore, ConversationNotFoundError } from '../src/store.ts'
import type { CloudStoreApi, CompleteRunInput } from '../src/store-api.ts'
import { OWNER_ID } from '../src/types.ts'

const START = Date.parse('2026-01-02T03:04:05.000Z')

function fixture(t: TestContext) {
  let time = START
  const store = new CloudStore(':memory:', () => new Date(time))
  t.after(() => store.close())
  return {
    store,
    now: () => new Date(time).toISOString(),
    advance: (milliseconds: number) => { time += milliseconds },
  }
}

function fileFixture(t: TestContext) {
  let time = START
  const directory = mkdtempSync(join(import.meta.dirname, '.store-test-'))
  const dbPath = join(directory, 'nested', 'cloud.sqlite')
  const stores: CloudStore[] = []
  t.after(() => {
    for (const store of stores) store.close()
    // Verify the exact temporary directory before deleting generated test data.
    assert.equal(dirname(directory), import.meta.dirname)
    assert.ok(basename(directory).startsWith('.store-test-'))
    rmSync(directory, { recursive: true, force: true })
  })
  return {
    dbPath,
    open: () => {
      const store = new CloudStore(dbPath, () => new Date(time))
      stores.push(store)
      return store
    },
    now: () => new Date(time).toISOString(),
    advance: (milliseconds: number) => { time += milliseconds },
  }
}

function append(store: CloudStoreApi, conversationId: string, key: string | null = null) {
  return store.appendUserMessage({
    conversationId, role: 'user', text: `message ${key ?? 'without key'}`, clientRequestId: key,
  })
}

test('SQLite stores device records and opaque token hashes without hashing them', t => {
  const { store, now, advance } = fixture(t)
  assert.equal(store.dbPath, ':memory:')
  const device = store.pairDevice({ name: "phone's device", role: 'client', tokenHash: 'opaque hash' })
  assert.ok(device.id)
  assert.deepEqual(device, {
    id: device.id, name: "phone's device", role: 'client', tokenHash: 'opaque hash',
    createdAt: now(), lastSeenAt: null, revokedAt: null,
  })
  assert.deepEqual(store.deviceById(device.id), device)
  assert.deepEqual(store.deviceByTokenHash('opaque hash'), device)
  assert.equal(store.deviceById('missing'), null)
  assert.equal(store.deviceByTokenHash('missing'), null)

  advance(1_000)
  store.touchDevice(device.id)
  assert.equal(store.deviceById(device.id)?.lastSeenAt, now())
  const explicit = new Date('2026-02-03T04:05:06Z')
  store.touchDevice(device.id, explicit)
  assert.equal(store.deviceById(device.id)?.lastSeenAt, explicit.toISOString())
  assert.doesNotThrow(() => store.touchDevice('missing'))

  // Returned records are snapshots, rather than mutable in-memory storage.
  device.name = 'changed locally'
  assert.equal(store.deviceById(device.id)?.name, "phone's device")
  const agent = store.pairDevice({ name: 'worker', role: 'agent', tokenHash: 'agent hash' })
  assert.notEqual(agent.id, device.id)
  assert.equal(store.deviceById(agent.id)?.role, 'agent')
})

test('SQLite schema enforces token uniqueness and device role constraints', t => {
  const { store } = fixture(t)
  const device = store.pairDevice({ name: 'first', role: 'client', tokenHash: 'same hash' })
  assert.throws(() => store.pairDevice({ name: 'duplicate', role: 'agent', tokenHash: 'same hash' }),
    /UNIQUE constraint failed/)
  assert.deepEqual(store.deviceByTokenHash('same hash'), device)
  assert.throws(() => store.pairDevice({
    name: 'invalid', role: 'invalid' as 'client', tokenHash: 'invalid role hash',
  }), /CHECK constraint failed/)
  assert.equal(store.deviceByTokenHash('invalid role hash'), null)
})

test('conversations persist defaults and are ordered by latest message activity', t => {
  const { store, advance, now } = fixture(t)
  const first = store.createConversation({ title: "'); DROP TABLE messages; --" })
  assert.deepEqual(first, {
    id: first.id, ownerId: OWNER_ID, title: "'); DROP TABLE messages; --",
    createdAt: now(), updatedAt: now(),
  })
  assert.deepEqual(store.getConversation(first.id), first)
  assert.equal(store.getConversation('missing'), null)
  advance(10)
  const second = store.createConversation({})
  assert.equal(second.title, null)
  assert.deepEqual(store.listConversations().map(item => item.id), [second.id, first.id])
  advance(10)
  append(store, first.id)
  assert.equal(store.getConversation(first.id)?.updatedAt, now())
  assert.equal(store.getConversation(first.id)?.createdAt, first.createdAt)
  assert.deepEqual(store.listConversations().map(item => item.id), [first.id, second.id])
})

test('append atomically stores one user message and its queued run', t => {
  const { store, advance, now } = fixture(t)
  const conversation = store.createConversation({})
  advance(500)
  const result = append(store, conversation.id, 'request-1')
  assert.equal(result.created, true)
  assert.deepEqual(result.message, {
    id: result.message.id, conversationId: conversation.id, role: 'user',
    text: 'message request-1', clientRequestId: 'request-1', seq: 1, createdAt: now(),
  })
  assert.deepEqual(result.run, {
    id: result.run.id, conversationId: conversation.id, messageId: result.message.id,
    status: 'queued', leaseToken: null, leasedUntil: null, createdAt: now(),
    startedAt: null, finishedAt: null, resultText: null, error: null,
  })
  assert.deepEqual(store.listMessages(conversation.id, 0), [result.message])
  assert.deepEqual(store.getRun(result.run.id), result.run)
  assert.equal(store.getConversation(conversation.id)?.updatedAt, now())
})

test('idempotency keys are conversation scoped; null keys always append and empty keys deduplicate', t => {
  const { store, advance } = fixture(t)
  const first = store.createConversation({})
  const second = store.createConversation({})
  const original = append(store, first.id, 'same key')
  const updatedAt = store.getConversation(first.id)?.updatedAt
  advance(1_000)
  const duplicate = store.appendUserMessage({
    conversationId: first.id, role: 'user', text: 'changed retry', clientRequestId: 'same key',
  })
  assert.deepEqual(duplicate, { ...original, created: false })
  assert.equal(store.getConversation(first.id)?.updatedAt, updatedAt)

  const other = append(store, second.id, 'same key')
  assert.equal(other.created, true)
  assert.notEqual(other.run.id, original.run.id)
  assert.equal(other.message.seq, 1)
  assert.equal(append(store, first.id).message.seq, 2)
  assert.equal(append(store, first.id).message.seq, 3)
  const emptyKey = append(store, first.id, '')
  assert.equal(emptyKey.message.seq, 4)
  assert.deepEqual(append(store, first.id, ''), { ...emptyKey, created: false })
  assert.deepEqual(store.listMessages(first.id, 0).map(message => message.seq), [1, 2, 3, 4])
})

test('an idempotent retry returns the current run without creating another assistant reply', t => {
  const { store, advance } = fixture(t)
  const conversation = store.createConversation({})
  const original = append(store, conversation.id, 'retry after completion')
  const lease = store.leaseRun({ leaseMs: 1_000 })!
  advance(10)
  const completed = store.completeRun(lease.run.id, lease.leaseToken, {
    status: 'completed', resultText: 'answer',
  })!
  const updatedAt = store.getConversation(conversation.id)?.updatedAt
  advance(10)
  const retry = append(store, conversation.id, 'retry after completion')
  assert.equal(retry.created, false)
  assert.deepEqual(retry.message, original.message)
  assert.deepEqual(retry.run, completed)
  assert.equal(store.listMessages(conversation.id, 0).length, 2)
  assert.equal(store.getConversation(conversation.id)?.updatedAt, updatedAt)
  assert.equal(store.leaseRun({ leaseMs: 1_000 }), null)
})

test('user and assistant messages share a strictly increasing per-conversation sequence', t => {
  const { store, advance, now } = fixture(t)
  const conversation = store.createConversation({})
  append(store, conversation.id, 'first')
  append(store, conversation.id, 'second')
  const lease = store.leaseRun({ leaseMs: 1_000 })!
  advance(50)
  const completed = store.completeRun(lease.run.id, lease.leaseToken, {
    status: 'completed', resultText: 'reply to first',
  })!
  assert.equal(completed.status, 'completed')
  const messages = store.listMessages(conversation.id, 0)
  assert.deepEqual(messages.map(message => [message.role, message.seq]), [
    ['user', 1], ['user', 2], ['assistant', 3],
  ])
  assert.equal(messages[2].text, 'reply to first')
  assert.equal(messages[2].clientRequestId, null)
  assert.equal(messages[2].createdAt, now())
  assert.equal(store.getConversation(conversation.id)?.updatedAt, now())
  assert.equal(append(store, conversation.id, 'third').message.seq, 4)
  const other = store.createConversation({})
  assert.equal(append(store, other.id).message.seq, 1)
})

test('message pagination is exclusive, ordered, defaults to 200 and caps the limit at 500', t => {
  const { store } = fixture(t)
  const conversation = store.createConversation({})
  for (let index = 0; index < 505; index++) append(store, conversation.id)
  const defaultPage = store.listMessages(conversation.id, 0)
  assert.equal(defaultPage.length, 200)
  assert.equal(defaultPage[0].seq, 1)
  assert.equal(defaultPage[199].seq, 200)
  const maximumPage = store.listMessages(conversation.id, 0, 10_000)
  assert.equal(maximumPage.length, 500)
  assert.equal(maximumPage[499].seq, 500)
  assert.deepEqual(store.listMessages(conversation.id, 500).map(message => message.seq),
    [501, 502, 503, 504, 505])
  assert.deepEqual(store.listMessages(conversation.id, 2, 2).map(message => message.seq), [3, 4])
  assert.deepEqual(store.listMessages(conversation.id, 505), [])
  assert.deepEqual(store.listMessages('missing', 0), [])
  assert.throws(() => store.listMessages(conversation.id, -1), RangeError)
  assert.throws(() => store.listMessages(conversation.id, 0, 0), RangeError)
})

test('invalid appends leave no partial writes or consumed sequence and release the transaction', t => {
  const { store, advance } = fixture(t)
  assert.throws(() => append(store, 'missing'), (error: unknown) => {
    assert.ok(error instanceof ConversationNotFoundError)
    assert.equal(error.code, 'CONVERSATION_NOT_FOUND')
    return true
  })
  assert.deepEqual(store.listMessages('missing', 0), [])
  assert.equal(store.leaseRun({ leaseMs: 1_000 }), null)
  const conversation = store.createConversation({})
  advance(10)
  for (const role of ['assistant', 'system'] as const) {
    assert.throws(() => store.appendUserMessage({
      conversationId: conversation.id, role, text: 'invalid', clientRequestId: null,
    }), TypeError)
  }
  assert.throws(() => store.appendUserMessage({
    conversationId: conversation.id, role: 'user', text: null as unknown as string,
    clientRequestId: 'failed insert',
  }), /NOT NULL constraint failed/)
  assert.deepEqual(store.listMessages(conversation.id, 0), [])
  assert.equal(store.getConversation(conversation.id)?.updatedAt, conversation.updatedAt)
  const valid = append(store, conversation.id, 'failed insert')
  assert.equal(valid.message.seq, 1)
  assert.equal(store.leaseRun({ leaseMs: 1_000 })?.run.id, valid.run.id)
})

test('leasing is FIFO even for tied timestamps and allows only one global active lease', t => {
  const { store, now, advance } = fixture(t)
  const firstConversation = store.createConversation({})
  const secondConversation = store.createConversation({})
  const first = append(store, firstConversation.id)
  const second = append(store, secondConversation.id)
  const lease = store.leaseRun({ leaseMs: 1_000 })!
  assert.equal(lease.run.id, first.run.id)
  assert.ok(lease.leaseToken)
  assert.equal(lease.run.leaseToken, lease.leaseToken)
  assert.equal(lease.run.status, 'running')
  assert.equal(lease.run.startedAt, now())
  assert.equal(lease.run.leasedUntil, new Date(START + 1_000).toISOString())
  assert.equal(store.leaseRun({ leaseMs: 1_000 }), null)
  advance(999)
  assert.equal(store.requeueExpiredLeases(), 0)
  assert.equal(store.leaseRun({ leaseMs: 1_000 }), null)
  assert.equal(store.getRun(second.run.id)?.status, 'queued')
  assert.ok(store.completeRun(first.run.id, lease.leaseToken, { status: 'completed' }))
  assert.equal(store.leaseRun({ leaseMs: 1_000 })?.run.id, second.run.id)
})

test('expiration includes the exact deadline and requeue clears the old lease before re-leasing', t => {
  const { store, advance } = fixture(t)
  const conversation = store.createConversation({})
  const original = append(store, conversation.id)
  const lease = store.leaseRun({ leaseMs: 1_000 })!
  advance(1_000)
  assert.equal(store.completeRun(original.run.id, lease.leaseToken, {
    status: 'completed', resultText: 'too late',
  }), null)
  assert.equal(store.listMessages(conversation.id, 0).length, 1)
  assert.equal(store.requeueExpiredLeases(), 1)
  assert.equal(store.requeueExpiredLeases(), 0)
  assert.deepEqual(store.getRun(original.run.id), original.run)
  assert.equal(store.completeRun(original.run.id, lease.leaseToken, {
    status: 'failed', error: 'stale',
  }), null)
  const renewed = store.leaseRun({ leaseMs: 1_000 })!
  assert.equal(renewed.run.id, original.run.id)
  assert.notEqual(renewed.leaseToken, lease.leaseToken)
  assert.equal(store.completeRun(original.run.id, lease.leaseToken, {
    status: 'completed', resultText: 'stale reply',
  }), null)
  assert.ok(store.completeRun(original.run.id, renewed.leaseToken, {
    status: 'completed', resultText: 'current reply',
  }))
  assert.deepEqual(store.listMessages(conversation.id, 0).map(message => message.text),
    ['message without key', 'current reply'])
})

test('leaseRun automatically requeues expired work and retries the oldest run first', t => {
  const { store, advance, now } = fixture(t)
  const conversation = store.createConversation({})
  const oldest = append(store, conversation.id)
  const firstLease = store.leaseRun({ leaseMs: 20 })!
  advance(10)
  const newer = append(store, conversation.id)
  advance(11)
  const retry = store.leaseRun({ leaseMs: 100 })!
  assert.equal(retry.run.id, oldest.run.id)
  assert.equal(retry.run.startedAt, now())
  assert.notEqual(retry.leaseToken, firstLease.leaseToken)
  assert.equal(store.getRun(newer.run.id)?.status, 'queued')
  assert.equal(store.leaseRun({ leaseMs: 100 }), null)
  assert.equal(store.completeRun(oldest.run.id, firstLease.leaseToken, {
    status: 'completed', resultText: 'expired worker',
  }), null)
  store.cancelRun(oldest.run.id)
  assert.equal(store.leaseRun({ leaseMs: 100 })?.run.id, newer.run.id)
})

test('completion fences wrong tokens, records terminal fields and emits exactly one assistant reply', t => {
  const { store, advance, now } = fixture(t)
  const conversation = store.createConversation({})
  const original = append(store, conversation.id)
  assert.equal(store.completeRun(original.run.id, 'not leased', { status: 'completed' }), null)
  const lease = store.leaseRun({ leaseMs: 1_000 })!
  assert.equal(store.completeRun(original.run.id, 'wrong token', {
    status: 'completed', resultText: 'wrong worker',
  }), null)
  assert.deepEqual(store.getRun(original.run.id), lease.run)
  assert.equal(store.listMessages(conversation.id, 0).length, 1)
  advance(10)
  const completed = store.completeRun(original.run.id, lease.leaseToken, {
    status: 'completed', resultText: 'correct reply', error: null,
  })!
  assert.deepEqual(completed, {
    ...lease.run, status: 'completed', leaseToken: null, leasedUntil: null,
    finishedAt: now(), resultText: 'correct reply', error: null,
  })
  assert.equal(store.completeRun(original.run.id, lease.leaseToken, {
    status: 'completed', resultText: 'duplicate reply',
  }), null)
  assert.deepEqual(store.getRun(original.run.id), completed)
  assert.deepEqual(store.listMessages(conversation.id, 1).map(message => message.text), ['correct reply'])
  advance(10)
  assert.deepEqual(store.cancelRun(original.run.id), completed)
  assert.equal(store.getConversation(conversation.id)?.updatedAt, completed.finishedAt)
  assert.equal(store.completeRun('missing', lease.leaseToken, { status: 'completed' }), null)
})

const completionsWithoutReply: CompleteRunInput[] = [
  { status: 'completed' },
  { status: 'completed', resultText: null },
  { status: 'completed', resultText: '' },
  { status: 'failed', resultText: 'partial output', error: 'upstream failed' },
  { status: 'canceled', resultText: 'discarded output', error: 'canceled by worker' },
]
for (const input of completionsWithoutReply) {
  test(`terminal ${input.status} with result ${JSON.stringify(input.resultText)} emits no reply`, t => {
    const { store, advance, now } = fixture(t)
    const conversation = store.createConversation({})
    const original = append(store, conversation.id)
    const lease = store.leaseRun({ leaseMs: 1_000 })!
    advance(10)
    const completed = store.completeRun(original.run.id, lease.leaseToken, input)!
    assert.equal(completed.status, input.status)
    assert.equal(completed.resultText, input.resultText ?? null)
    assert.equal(completed.error, input.error ?? null)
    assert.equal(completed.finishedAt, now())
    assert.equal(completed.leaseToken, null)
    assert.equal(completed.leasedUntil, null)
    assert.deepEqual(store.listMessages(conversation.id, 0), [original.message])
    assert.deepEqual(store.cancelRun(original.run.id), completed)
    assert.equal(store.leaseRun({ leaseMs: 1_000 }), null)
  })
}

test('cancel is idempotent for queued and running work and invalidates the active token', t => {
  const { store, advance, now } = fixture(t)
  const conversation = store.createConversation({})
  const queued = append(store, conversation.id)
  advance(10)
  const canceled = store.cancelRun(queued.run.id)!
  assert.deepEqual(canceled, { ...queued.run, status: 'canceled', finishedAt: now() })
  advance(10)
  assert.deepEqual(store.cancelRun(queued.run.id), canceled)
  assert.equal(store.cancelRun('missing'), null)
  assert.equal(store.leaseRun({ leaseMs: 1_000 }), null)

  const active = append(store, conversation.id)
  const lease = store.leaseRun({ leaseMs: 1_000 })!
  advance(10)
  const activeCanceled = store.cancelRun(active.run.id)!
  assert.equal(activeCanceled.status, 'canceled')
  assert.equal(activeCanceled.startedAt, lease.run.startedAt)
  assert.equal(activeCanceled.finishedAt, now())
  assert.equal(activeCanceled.leaseToken, null)
  assert.equal(activeCanceled.leasedUntil, null)
  assert.deepEqual(store.cancelRun(active.run.id), activeCanceled)
  assert.equal(store.completeRun(active.run.id, lease.leaseToken, {
    status: 'completed', resultText: 'reply after cancel',
  }), null)
  assert.equal(store.requeueExpiredLeases(), 0)
  assert.deepEqual(store.listMessages(conversation.id, 0).map(message => message.role), ['user', 'user'])
  const next = append(store, conversation.id)
  assert.equal(store.leaseRun({ leaseMs: 1_000 })?.run.id, next.run.id)
})

test('invalid lease durations and terminal inputs do not change queued or running work', t => {
  const { store } = fixture(t)
  const conversation = store.createConversation({})
  const original = append(store, conversation.id)
  for (const leaseMs of [0, -1, 0.5, NaN, Infinity, Number.MAX_SAFE_INTEGER]) {
    assert.throws(() => store.leaseRun({ leaseMs }), RangeError)
    assert.deepEqual(store.getRun(original.run.id), original.run)
  }
  const lease = store.leaseRun({ leaseMs: 1_000 })!
  assert.throws(() => store.completeRun(original.run.id, lease.leaseToken, {
    status: 'queued' as 'completed',
  }), TypeError)
  assert.deepEqual(store.getRun(original.run.id), lease.run)
  assert.ok(store.completeRun(original.run.id, lease.leaseToken, { status: 'completed' }))
})

test('file databases create parent directories, use WAL and retain their schema and records on reopen', t => {
  const { open, dbPath, advance } = fileFixture(t)
  assert.equal(existsSync(dirname(dbPath)), false)
  const first = open()
  assert.equal(existsSync(dirname(dbPath)), true)
  const device = first.pairDevice({ name: 'persistent worker', role: 'agent', tokenHash: 'stored hash' })
  const conversation = first.createConversation({ title: 'persistent conversation' })
  const original = append(first, conversation.id, 'persistent request')
  const lease = first.leaseRun({ leaseMs: 1_000 })!
  advance(10)
  const completed = first.completeRun(original.run.id, lease.leaseToken, {
    status: 'completed', resultText: 'persistent answer',
  })!
  const expectedMessages = first.listMessages(conversation.id, 0)
  first.close()
  first.close()

  const inspection = new DatabaseSync(dbPath)
  try {
    assert.equal(inspection.prepare('PRAGMA journal_mode').get()?.journal_mode, 'wal')
    assert.deepEqual(inspection.prepare(`SELECT name FROM sqlite_schema
      WHERE type = 'table' AND name NOT LIKE 'sqlite_%' ORDER BY name`).all().map(row => row.name),
    ['conversations', 'devices', 'messages', 'runs'])
    assert.deepEqual(inspection.prepare('PRAGMA foreign_key_check').all(), [])
    assert.deepEqual(inspection.prepare('PRAGMA integrity_check').all().map(row => row.integrity_check), ['ok'])
  } finally {
    inspection.close()
  }

  const reopened = open()
  assert.deepEqual(reopened.deviceByTokenHash('stored hash'), device)
  assert.equal(reopened.getConversation(conversation.id)?.title, conversation.title)
  assert.deepEqual(reopened.getRun(original.run.id), completed)
  assert.deepEqual(reopened.listMessages(conversation.id, 0), expectedMessages)
  assert.deepEqual(append(reopened, conversation.id, 'persistent request'), {
    message: original.message, run: completed, created: false,
  })
  assert.equal(append(reopened, conversation.id).message.seq, 3)
})

test('two file database connections share idempotency, sequence and the fenced global lease', t => {
  const { open, advance } = fileFixture(t)
  const first = open()
  const second = open()
  const conversation = first.createConversation({})
  const original = append(first, conversation.id, 'shared request')
  assert.deepEqual(append(second, conversation.id, 'shared request'), { ...original, created: false })
  assert.equal(append(second, conversation.id).message.seq, 2)
  const initial = first.leaseRun({ leaseMs: 100 })!
  assert.equal(second.leaseRun({ leaseMs: 100 }), null)
  advance(100)
  const replacement = second.leaseRun({ leaseMs: 100 })!
  assert.equal(replacement.run.id, initial.run.id)
  assert.notEqual(replacement.leaseToken, initial.leaseToken)
  assert.equal(first.completeRun(initial.run.id, initial.leaseToken, {
    status: 'completed', resultText: 'stale reply',
  }), null)
  assert.ok(second.completeRun(replacement.run.id, replacement.leaseToken, {
    status: 'completed', resultText: 'new worker reply',
  }))
  assert.deepEqual(first.listMessages(conversation.id, 0).map(message => [message.role, message.seq]),
    [['user', 1], ['user', 2], ['assistant', 3]])
  assert.deepEqual(first.listMessages(conversation.id, 0), second.listMessages(conversation.id, 0))
})

test('a failure after inserting the assistant message rolls back the message and run completion together', t => {
  const { open, dbPath, advance, now } = fileFixture(t)
  const store = open()
  const conversation = store.createConversation({})
  const original = append(store, conversation.id)
  const lease = store.leaseRun({ leaseMs: 1_000 })!
  advance(10)
  const inspection = new DatabaseSync(dbPath)
  try {
    inspection.exec(`CREATE TRIGGER reject_conversation_update
      BEFORE UPDATE OF updated_at ON conversations
      BEGIN SELECT RAISE(ABORT, 'forced conversation update failure'); END;`)
    assert.throws(() => store.completeRun(original.run.id, lease.leaseToken, {
      status: 'completed', resultText: 'reply to roll back',
    }), /forced conversation update failure/)
    assert.deepEqual(store.getRun(original.run.id), lease.run)
    assert.deepEqual(store.listMessages(conversation.id, 0), [original.message])
    assert.equal(store.getConversation(conversation.id)?.updatedAt, conversation.updatedAt)
    inspection.exec('DROP TRIGGER reject_conversation_update')
  } finally {
    inspection.close()
  }
  const completed = store.completeRun(original.run.id, lease.leaseToken, {
    status: 'completed', resultText: 'committed reply',
  })!
  assert.equal(completed.finishedAt, now())
  assert.equal(store.getConversation(conversation.id)?.updatedAt, now())
  assert.deepEqual(store.listMessages(conversation.id, 0).map(message => [message.text, message.seq]),
    [['message without key', 1], ['committed reply', 2]])
})

test('a fresh database has no work and close is idempotent', () => {
  const store = new CloudStore(':memory:')
  try {
    assert.deepEqual(store.listConversations(), [])
    assert.equal(store.getRun('missing'), null)
    assert.equal(store.leaseRun({ leaseMs: 1_000 }), null)
    assert.equal(store.requeueExpiredLeases(), 0)
  } finally {
    store.close()
  }
  assert.doesNotThrow(() => store.close())
})
