import { randomUUID } from 'node:crypto'
import { mkdirSync } from 'node:fs'
import { dirname } from 'node:path'
import { DatabaseSync } from 'node:sqlite'
import type { SQLInputValue } from 'node:sqlite'
import type {
  CloudStoreApi,
  CompleteRunInput,
  InsertMessageInput,
  StoreClock,
} from './store-api.ts'
import { OWNER_ID } from './types.ts'
import type {
  ConversationRecord,
  DeviceRecord,
  DeviceRole,
  MessageRecord,
  MessageRole,
  MessageWithRun,
  RunLease,
  RunRecord,
} from './types.ts'

const DEVICE_COLUMNS = `id, name, role, token_hash AS tokenHash,
  created_at AS createdAt, last_seen_at AS lastSeenAt, revoked_at AS revokedAt`
const CONVERSATION_COLUMNS = `id, owner_id AS ownerId, title,
  created_at AS createdAt, updated_at AS updatedAt`
const MESSAGE_COLUMNS = `id, conversation_id AS conversationId, role, text,
  client_request_id AS clientRequestId, seq, created_at AS createdAt`
const RUN_COLUMNS = `id, conversation_id AS conversationId, message_id AS messageId,
  status, lease_token AS leaseToken, leased_until AS leasedUntil,
  created_at AS createdAt, started_at AS startedAt, finished_at AS finishedAt,
  result_text AS resultText, error`

const SCHEMA = `
  CREATE TABLE IF NOT EXISTS devices (
    id TEXT PRIMARY KEY NOT NULL,
    name TEXT NOT NULL,
    role TEXT NOT NULL CHECK (role IN ('client', 'agent')),
    token_hash TEXT NOT NULL UNIQUE,
    created_at TEXT NOT NULL,
    last_seen_at TEXT,
    revoked_at TEXT
  ) STRICT;

  CREATE TABLE IF NOT EXISTS conversations (
    id TEXT PRIMARY KEY NOT NULL,
    owner_id TEXT NOT NULL,
    title TEXT,
    created_at TEXT NOT NULL,
    updated_at TEXT NOT NULL
  ) STRICT;

  CREATE TABLE IF NOT EXISTS messages (
    id TEXT PRIMARY KEY NOT NULL,
    conversation_id TEXT NOT NULL REFERENCES conversations(id),
    role TEXT NOT NULL CHECK (role IN ('user', 'assistant', 'system')),
    text TEXT NOT NULL,
    client_request_id TEXT,
    seq INTEGER NOT NULL CHECK (seq > 0),
    created_at TEXT NOT NULL,
    UNIQUE (conversation_id, seq),
    UNIQUE (conversation_id, client_request_id)
  ) STRICT;

  CREATE TABLE IF NOT EXISTS runs (
    id TEXT PRIMARY KEY NOT NULL,
    conversation_id TEXT NOT NULL REFERENCES conversations(id),
    message_id TEXT NOT NULL UNIQUE REFERENCES messages(id),
    status TEXT NOT NULL CHECK (
      status IN ('queued', 'running', 'completed', 'failed', 'canceled')
    ),
    lease_token TEXT,
    leased_until TEXT,
    created_at TEXT NOT NULL,
    started_at TEXT,
    finished_at TEXT,
    result_text TEXT,
    error TEXT,
    CHECK (
      (status = 'running' AND lease_token IS NOT NULL AND leased_until IS NOT NULL)
      OR (status <> 'running' AND lease_token IS NULL AND leased_until IS NULL)
    )
  ) STRICT;

  CREATE INDEX IF NOT EXISTS conversations_updated ON conversations(updated_at);
  CREATE INDEX IF NOT EXISTS runs_queue ON runs(status, created_at);
  CREATE UNIQUE INDEX IF NOT EXISTS runs_single_running ON runs(status)
    WHERE status = 'running';
`

/** Defensive equivalent of the HTTP conversation existence check. */
export class ConversationNotFoundError extends Error {
  readonly code = 'CONVERSATION_NOT_FOUND'

  constructor(conversationId: string) {
    super(`Conversation not found: ${conversationId}`)
    this.name = 'ConversationNotFoundError'
  }
}

export class CloudStore implements CloudStoreApi {
  readonly dbPath: string
  #db: DatabaseSync
  #clock: StoreClock
  #closed = false

  constructor(dbPath: string, clock: StoreClock = () => new Date()) {
    this.dbPath = dbPath
    this.#clock = clock
    if (dbPath !== ':memory:') mkdirSync(dirname(dbPath), { recursive: true })
    this.#db = new DatabaseSync(dbPath)
    try {
      this.#db.exec(`PRAGMA foreign_keys = ON;
        PRAGMA busy_timeout = 5000;
        PRAGMA journal_mode = WAL;`)
      this.#transaction(() => this.#db.exec(SCHEMA))
    } catch (error) {
      this.#db.close()
      this.#closed = true
      throw error
    }
  }

  close(): void {
    if (this.#closed) return
    this.#db.close()
    this.#closed = true
  }

  pairDevice(input: { name: string; role: DeviceRole; tokenHash: string }): DeviceRecord {
    const device: DeviceRecord = {
      id: randomUUID(),
      name: input.name,
      role: input.role,
      tokenHash: input.tokenHash,
      createdAt: this.#clock().toISOString(),
      lastSeenAt: null,
      revokedAt: null,
    }
    this.#db.prepare(`INSERT INTO devices
      (id, name, role, token_hash, created_at, last_seen_at, revoked_at)
      VALUES (?, ?, ?, ?, ?, NULL, NULL)`).run(
      device.id, device.name, device.role, device.tokenHash, device.createdAt,
    )
    return device
  }

  deviceByTokenHash(tokenHash: string): DeviceRecord | null {
    return this.#one<DeviceRecord>(
      `SELECT ${DEVICE_COLUMNS} FROM devices WHERE token_hash = ?`, tokenHash,
    )
  }

  deviceById(id: string): DeviceRecord | null {
    return this.#one<DeviceRecord>(`SELECT ${DEVICE_COLUMNS} FROM devices WHERE id = ?`, id)
  }

  touchDevice(id: string, at?: Date): void {
    this.#db.prepare('UPDATE devices SET last_seen_at = ? WHERE id = ?').run(
      (at ?? this.#clock()).toISOString(), id,
    )
  }

  createConversation(input: { title?: string | null }): ConversationRecord {
    const now = this.#clock().toISOString()
    const conversation: ConversationRecord = {
      id: randomUUID(),
      ownerId: OWNER_ID,
      title: input.title ?? null,
      createdAt: now,
      updatedAt: now,
    }
    this.#db.prepare(`INSERT INTO conversations (id, owner_id, title, created_at, updated_at)
      VALUES (?, ?, ?, ?, ?)`).run(
      conversation.id, conversation.ownerId, conversation.title, now, now,
    )
    return conversation
  }

  listConversations(): ConversationRecord[] {
    return this.#all<ConversationRecord>(`SELECT ${CONVERSATION_COLUMNS}
      FROM conversations ORDER BY updated_at DESC, rowid DESC`)
  }

  getConversation(id: string): ConversationRecord | null {
    return this.#one<ConversationRecord>(
      `SELECT ${CONVERSATION_COLUMNS} FROM conversations WHERE id = ?`, id,
    )
  }

  listMessages(conversationId: string, afterSeq: number, limit = 200): MessageRecord[] {
    if (!Number.isSafeInteger(afterSeq) || afterSeq < 0) {
      throw new RangeError('afterSeq must be a non-negative safe integer')
    }
    if (!Number.isSafeInteger(limit) || limit < 1) {
      throw new RangeError('limit must be a positive safe integer')
    }
    return this.#all<MessageRecord>(`SELECT ${MESSAGE_COLUMNS} FROM messages
      WHERE conversation_id = ? AND seq > ? ORDER BY seq ASC LIMIT ?`,
    conversationId, afterSeq, Math.min(limit, 500))
  }

  appendUserMessage(input: InsertMessageInput): MessageWithRun {
    if (input.role !== 'user') {
      throw new TypeError('appendUserMessage only accepts role=user')
    }
    return this.#transaction(() => {
      if (!this.getConversation(input.conversationId)) {
        throw new ConversationNotFoundError(input.conversationId)
      }
      if (input.clientRequestId !== null) {
        const message = this.#one<MessageRecord>(`SELECT ${MESSAGE_COLUMNS}
          FROM messages WHERE conversation_id = ? AND client_request_id = ?`,
        input.conversationId, input.clientRequestId)
        if (message) {
          const run = this.#one<RunRecord>(
            `SELECT ${RUN_COLUMNS} FROM runs WHERE message_id = ?`, message.id,
          )
          if (!run) throw new Error(`Missing run for message: ${message.id}`)
          return { message, run, created: false }
        }
      }

      const now = this.#clock().toISOString()
      const message = this.#insertMessage(
        input.conversationId, 'user', input.text, input.clientRequestId, now,
      )
      const run: RunRecord = {
        id: randomUUID(),
        conversationId: input.conversationId,
        messageId: message.id,
        status: 'queued',
        leaseToken: null,
        leasedUntil: null,
        createdAt: now,
        startedAt: null,
        finishedAt: null,
        resultText: null,
        error: null,
      }
      this.#db.prepare(`INSERT INTO runs
        (id, conversation_id, message_id, status, created_at)
        VALUES (?, ?, ?, 'queued', ?)`).run(
        run.id, run.conversationId, run.messageId, now,
      )
      return { message, run, created: true }
    })
  }

  getRun(id: string): RunRecord | null {
    return this.#one<RunRecord>(`SELECT ${RUN_COLUMNS} FROM runs WHERE id = ?`, id)
  }

  leaseRun(input: { leaseMs: number }): RunLease | null {
    if (!Number.isSafeInteger(input.leaseMs) || input.leaseMs <= 0) {
      throw new RangeError('leaseMs must be a positive safe integer')
    }
    return this.#transaction(() => {
      const date = this.#clock()
      const now = date.toISOString()
      const leasedUntil = new Date(date.getTime() + input.leaseMs).toISOString()
      this.#requeueExpiredAt(now)
      if (this.#one<{ id: string }>("SELECT id FROM runs WHERE status = 'running'")) {
        return null
      }
      const run = this.#one<RunRecord>(`SELECT ${RUN_COLUMNS} FROM runs
        WHERE status = 'queued' ORDER BY created_at ASC, rowid ASC LIMIT 1`)
      if (!run) return null

      const leaseToken = randomUUID()
      this.#db.prepare(`UPDATE runs SET status = 'running', lease_token = ?,
        leased_until = ?, started_at = ? WHERE id = ?`).run(
        leaseToken, leasedUntil, now, run.id,
      )
      return { run: this.getRun(run.id)!, leaseToken }
    })
  }

  completeRun(id: string, leaseToken: string, input: CompleteRunInput): RunRecord | null {
    if (!['completed', 'failed', 'canceled'].includes(input.status)) {
      throw new TypeError('completeRun requires a terminal status')
    }
    return this.#transaction(() => {
      const now = this.#clock().toISOString()
      const resultText = input.resultText ?? null
      const result = this.#db.prepare(`UPDATE runs SET status = ?, result_text = ?,
        error = ?, finished_at = ?, lease_token = NULL, leased_until = NULL
        WHERE id = ? AND status = 'running' AND lease_token = ? AND leased_until > ?`).run(
        input.status, resultText, input.error ?? null, now, id, leaseToken, now,
      )
      if (result.changes === 0) return null

      const run = this.getRun(id)!
      if (input.status === 'completed' && resultText !== null && resultText !== '') {
        this.#insertMessage(run.conversationId, 'assistant', resultText, null, now)
      }
      return run
    })
  }

  cancelRun(id: string): RunRecord | null {
    return this.#transaction(() => {
      const run = this.getRun(id)
      if (!run || (run.status !== 'queued' && run.status !== 'running')) return run
      this.#db.prepare(`UPDATE runs SET status = 'canceled', finished_at = ?,
        lease_token = NULL, leased_until = NULL WHERE id = ?`).run(
        this.#clock().toISOString(), id,
      )
      return this.getRun(id)
    })
  }

  requeueExpiredLeases(): number {
    return this.#transaction(() => this.#requeueExpiredAt(this.#clock().toISOString()))
  }

  #requeueExpiredAt(now: string): number {
    const result = this.#db.prepare(`UPDATE runs SET status = 'queued',
      lease_token = NULL, leased_until = NULL, started_at = NULL,
      finished_at = NULL, result_text = NULL, error = NULL
      WHERE status = 'running' AND leased_until <= ?`).run(now)
    return Number(result.changes)
  }

  #insertMessage(
    conversationId: string,
    role: MessageRole,
    text: string,
    clientRequestId: string | null,
    now: string,
  ): MessageRecord {
    const { seq } = this.#one<{ seq: number }>(`SELECT COALESCE(MAX(seq), 0) + 1 AS seq
      FROM messages WHERE conversation_id = ?`, conversationId)!
    const message: MessageRecord = {
      id: randomUUID(), conversationId, role, text, clientRequestId, seq, createdAt: now,
    }
    this.#db.prepare(`INSERT INTO messages
      (id, conversation_id, role, text, client_request_id, seq, created_at)
      VALUES (?, ?, ?, ?, ?, ?, ?)`).run(
      message.id, conversationId, role, text, clientRequestId, seq, now,
    )
    this.#db.prepare('UPDATE conversations SET updated_at = ? WHERE id = ?').run(
      now, conversationId,
    )
    return message
  }

  #one<T>(sql: string, ...parameters: SQLInputValue[]): T | null {
    const row = this.#db.prepare(sql).get(...parameters)
    // Queries use explicit aliases matching the public record contracts.
    return row === undefined ? null : { ...row } as T
  }

  #all<T>(sql: string, ...parameters: SQLInputValue[]): T[] {
    return this.#db.prepare(sql).all(...parameters).map(row => ({ ...row }) as T)
  }

  #transaction<T>(work: () => T): T {
    this.#db.exec('BEGIN IMMEDIATE')
    try {
      const result = work()
      this.#db.exec('COMMIT')
      return result
    } catch (error) {
      this.#db.exec('ROLLBACK')
      throw error
    }
  }
}
