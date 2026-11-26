import { createHash, randomUUID } from 'node:crypto'
import { mkdirSync } from 'node:fs'
import { dirname } from 'node:path'
import { DatabaseSync } from 'node:sqlite'
import type { SQLInputValue } from 'node:sqlite'
import type {
  CloudStoreApi,
  CompleteRunInput,
  CreateGoalInput,
  CreateTaskInput,
  GoalCommandInput,
  InsertMessageInput,
  StoreClock,
  TaskCommandInput,
} from './store-api.ts'
import { GoalCommandError } from './store-api.ts'
import { OWNER_ID } from './types.ts'
import type {
  ConversationRecord,
  CommandResult,
  DeviceRecord,
  DeviceRole,
  GoalListItem,
  GoalRecord,
  GoalStatus,
  GoalQuestionContext,
  GoalQuestionTask,
  GoalView,
  MessageRecord,
  MessageRole,
  MessageWithRun,
  ProgressEntry,
  ProgressKind,
  RunLease,
  RunRecord,
  TaskRecord,
  TaskStatus,
  TaskView,
} from './types.ts'

const DEVICE_COLUMNS = `id, name, role, token_hash AS tokenHash,
  created_at AS createdAt, last_seen_at AS lastSeenAt, revoked_at AS revokedAt`
const CONVERSATION_COLUMNS = `id, owner_id AS ownerId, title,
  created_at AS createdAt, updated_at AS updatedAt`
const MESSAGE_COLUMNS = `id, conversation_id AS conversationId, role, text,
  client_request_id AS clientRequestId, seq, created_at AS createdAt`
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
    goal_id TEXT,
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

  CREATE TABLE IF NOT EXISTS goals (
    id TEXT PRIMARY KEY NOT NULL,
    owner_id TEXT NOT NULL,
    title TEXT NOT NULL,
    description TEXT,
    success_criteria TEXT,
    target_date TEXT,
    status TEXT NOT NULL CHECK (status IN ('active', 'completed', 'archived')),
    archived_from_status TEXT CHECK (archived_from_status IS NULL OR archived_from_status IN ('active', 'completed')),
    revision INTEGER NOT NULL CHECK (revision > 0),
    view_revision INTEGER NOT NULL CHECK (view_revision > 0),
    created_at TEXT NOT NULL,
    updated_at TEXT NOT NULL
  ) STRICT;

  CREATE TABLE IF NOT EXISTS tasks (
    id TEXT PRIMARY KEY NOT NULL,
    owner_id TEXT NOT NULL,
    goal_id TEXT NOT NULL REFERENCES goals(id),
    title TEXT NOT NULL,
    description TEXT,
    due_date TEXT,
    status TEXT NOT NULL CHECK (status IN ('todo', 'in_progress', 'blocked', 'completed', 'canceled')),
    blocked_reason TEXT,
    result_note TEXT,
    revision INTEGER NOT NULL CHECK (revision > 0),
    created_at TEXT NOT NULL,
    updated_at TEXT NOT NULL
  ) STRICT;

  CREATE TABLE IF NOT EXISTS progress_entries (
    id TEXT PRIMARY KEY NOT NULL,
    task_id TEXT NOT NULL REFERENCES tasks(id),
    actor_device_id TEXT NOT NULL,
    kind TEXT NOT NULL CHECK (kind IN ('status', 'note', 'result')),
    note TEXT,
    from_status TEXT CHECK (from_status IS NULL OR from_status IN ('todo', 'in_progress', 'blocked', 'completed', 'canceled')),
    to_status TEXT CHECK (to_status IS NULL OR to_status IN ('todo', 'in_progress', 'blocked', 'completed', 'canceled')),
    created_at TEXT NOT NULL
  ) STRICT;

  CREATE TABLE IF NOT EXISTS goal_contexts (
    run_id TEXT PRIMARY KEY NOT NULL REFERENCES runs(id),
    goal_id TEXT NOT NULL REFERENCES goals(id),
    context_json TEXT NOT NULL,
    created_at TEXT NOT NULL
  ) STRICT;

  CREATE TABLE IF NOT EXISTS command_receipts (
    device_id TEXT NOT NULL,
    command_id TEXT NOT NULL,
    operation TEXT NOT NULL,
    payload_hash TEXT NOT NULL,
    result_json TEXT NOT NULL,
    created_at TEXT NOT NULL,
    PRIMARY KEY (device_id, command_id)
  ) STRICT;

  CREATE INDEX IF NOT EXISTS goals_status_updated ON goals(status, updated_at DESC);
  CREATE INDEX IF NOT EXISTS tasks_goal_created ON tasks(goal_id, created_at, id);
  CREATE INDEX IF NOT EXISTS progress_task_created ON progress_entries(task_id, created_at, id);
  CREATE INDEX IF NOT EXISTS command_receipts_created ON command_receipts(created_at);

  CREATE INDEX IF NOT EXISTS conversations_updated ON conversations(updated_at);
  CREATE INDEX IF NOT EXISTS runs_queue ON runs(status, created_at);
  CREATE UNIQUE INDEX IF NOT EXISTS runs_single_running ON runs(status)
    WHERE status = 'running';
`

const RUN_COLUMNS = `id, conversation_id AS conversationId, message_id AS messageId,
  goal_id AS goalId, status, lease_token AS leaseToken, leased_until AS leasedUntil,
  created_at AS createdAt, started_at AS startedAt, finished_at AS finishedAt,
  result_text AS resultText, error`
const GOAL_COLUMNS = `id, owner_id AS ownerId, title, description,
  success_criteria AS successCriteria, target_date AS targetDate, status,
  archived_from_status AS archivedFromStatus, revision,
  created_at AS createdAt, updated_at AS updatedAt`
const TASK_COLUMNS = `id, owner_id AS ownerId, goal_id AS goalId, title, description,
  due_date AS dueDate, status, blocked_reason AS blockedReason, result_note AS resultNote,
  revision, created_at AS createdAt, updated_at AS updatedAt`
const PROGRESS_COLUMNS = `id, task_id AS taskId, actor_device_id AS actorDeviceId,
  kind, note, from_status AS fromStatus, to_status AS toStatus, created_at AS createdAt`

function canonicalJson(value: unknown): string {
  if (Array.isArray(value)) return `[${value.map(canonicalJson).join(',')}]`
  if (value !== null && typeof value === 'object') {
    const record = value as Record<string, unknown>
    return `{${Object.keys(record).sort().map(key => `${JSON.stringify(key)}:${canonicalJson(record[key])}`).join(',')}}`
  }
  return JSON.stringify(value)
}

function isNaturalDate(value: string | null | undefined): boolean {
  if (value == null) return true
  if (!/^\d{4}-\d{2}-\d{2}$/.test(value)) return false
  const parsed = new Date(`${value}T00:00:00.000Z`)
  return !Number.isNaN(parsed.getTime()) && parsed.toISOString().slice(0, 10) === value
}

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
      const runColumns = this.#all<{ name: string }>('PRAGMA table_info(runs)')
      if (!runColumns.some(column => column.name === 'goal_id')) {
        this.#db.exec('ALTER TABLE runs ADD COLUMN goal_id TEXT')
      }
      this.#db.exec(`UPDATE runs SET goal_id = (
        SELECT goal_id FROM goal_contexts WHERE goal_contexts.run_id = runs.id
      ) WHERE goal_id IS NULL AND EXISTS (
        SELECT 1 FROM goal_contexts WHERE goal_contexts.run_id = runs.id
      )`)
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
          if (run.goalId !== (input.goalId ?? null)) {
            throw new GoalCommandError('goal_question_conflict', 'The client request is already bound to a different intent.')
          }
          if (input.goalId != null) {
            if (message.text !== input.text) {
              throw new GoalCommandError('goal_question_conflict', 'The goal question key was reused with different text.')
            }
            const context = this.#one<{ goalId: string }>(
              'SELECT goal_id AS goalId FROM goal_contexts WHERE run_id = ?', run.id,
            )
            if (!context || context.goalId !== input.goalId) {
              throw new GoalCommandError('goal_question_conflict', 'The goal question snapshot is missing or mismatched.')
            }
          }
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
        goalId: input.goalId ?? null,
      }
      this.#db.prepare(`INSERT INTO runs
        (id, conversation_id, message_id, goal_id, status, created_at)
        VALUES (?, ?, ?, ?, 'queued', ?)`).run(
        run.id, run.conversationId, run.messageId, run.goalId ?? null, now,
      )
      if (input.goalId !== undefined && input.goalId !== null) {
        this.#insertGoalContext(run.id, input.goalId, now)
      }
      return { message, run, created: true }
    })
  }

  goalContextForRun(runId: string): GoalQuestionContext | null {
    const run = this.getRun(runId)
    if (!run) return null
    if (run.goalId == null) return null
    const row = this.#one<{ contextJson: string }>(
      'SELECT context_json AS contextJson FROM goal_contexts WHERE run_id = ?', runId,
    )
    if (!row) throw new GoalCommandError('goal_context_unavailable', 'The goal-question snapshot is unavailable.')
    try { return JSON.parse(row.contextJson) as GoalQuestionContext }
    catch { throw new GoalCommandError('goal_context_unavailable', 'The goal-question snapshot is invalid.') }
  }

  listGoals(status?: GoalStatus, after = 0, limit = 50): { goals: GoalListItem[]; nextCursor: number | null } {
    if (!Number.isSafeInteger(after) || after < 0) throw new RangeError('after must be a non-negative safe integer')
    if (!Number.isSafeInteger(limit) || limit < 1) throw new RangeError('limit must be a positive safe integer')
    const boundedLimit = Math.min(limit, 100)
    return this.#transaction(() => {
      const total = this.#one<{ count: number }>(`SELECT COUNT(*) AS count FROM goals
        ${status === undefined ? '' : 'WHERE status = ?'}`,
      ...(status === undefined ? [] : [status]))?.count ?? 0
      const goals = this.#all<GoalRecord>(`SELECT ${GOAL_COLUMNS} FROM goals
        ${status === undefined ? '' : 'WHERE status = ?'}
        ORDER BY updated_at DESC, id ASC LIMIT ? OFFSET ?`,
      ...(status === undefined ? [boundedLimit, after] : [status, boundedLimit, after]))
      const items = goals.map(goal => ({
        ...goal,
        summary: this.#goalSummary(goal.id, goal.updatedAt),
        viewRevision: this.#viewRevision(goal.id),
      }))
      const next = after + items.length
      return { goals: items, nextCursor: next < Number(total) ? next : null }
    })
  }

  getGoalView(id: string): GoalView | null {
    return this.#transaction(() => {
      const goal = this.#one<GoalRecord>(`SELECT ${GOAL_COLUMNS} FROM goals WHERE id = ?`, id)
      if (!goal) return null
      const tasks = this.#all<TaskRecord>(`SELECT ${TASK_COLUMNS} FROM tasks
        WHERE goal_id = ? ORDER BY CASE status
          WHEN 'blocked' THEN 0 WHEN 'in_progress' THEN 1 WHEN 'todo' THEN 2
          WHEN 'completed' THEN 3 ELSE 4 END, created_at ASC, id ASC`, id)
      return {
        goal,
        tasks,
        summary: this.#goalSummary(goal.id, goal.updatedAt),
        viewRevision: this.#viewRevision(goal.id),
        asOf: this.#clock().toISOString(),
      }
    })
  }

  createGoal(input: CreateGoalInput): CommandResult<GoalRecord> {
    if (!input.title.trim()) throw new TypeError('title must be non-empty')
    if (!isNaturalDate(input.targetDate)) throw new TypeError('targetDate must be YYYY-MM-DD')
    return this.#executeCommand(input.deviceId, input.commandId, 'create_goal', input, () => {
      const now = this.#clock().toISOString()
      const goal: GoalRecord = {
        id: randomUUID(), ownerId: OWNER_ID, title: input.title,
        description: input.description ?? null,
        successCriteria: input.successCriteria ?? null,
        targetDate: input.targetDate ?? null, status: 'active', archivedFromStatus: null,
        revision: 1, createdAt: now, updatedAt: now,
      }
      this.#db.prepare(`INSERT INTO goals
        (id, owner_id, title, description, success_criteria, target_date, status,
         archived_from_status, revision, view_revision, created_at, updated_at)
        VALUES (?, ?, ?, ?, ?, ?, 'active', NULL, 1, 1, ?, ?)`).run(
        goal.id, OWNER_ID, goal.title, goal.description, goal.successCriteria,
        goal.targetDate, now, now,
      )
      return goal
    })!
  }

  updateGoal(id: string, input: GoalCommandInput): CommandResult<GoalRecord> | null {
    return this.#executeCommand(input.deviceId, input.commandId, `goal:${id}`, input, () => {
      const goal = this.#one<GoalRecord>(`SELECT ${GOAL_COLUMNS} FROM goals WHERE id = ?`, id)
      if (!goal) return null
      if (input.expectedRevision !== goal.revision) {
        throw new GoalCommandError('revision_conflict', 'Goal has changed; reload before saving.')
      }
      let status = goal.status
      let archivedFromStatus = goal.archivedFromStatus
      let title = goal.title
      let description = goal.description
      let successCriteria = goal.successCriteria
      let targetDate = goal.targetDate

      if (input.action === 'update') {
        if (goal.status !== 'active') throw new GoalCommandError('goal_read_only', 'Restore or reopen the goal before editing.')
        if (input.title !== undefined) {
          if (!input.title.trim()) throw new TypeError('title must be non-empty')
          title = input.title
        }
        if (input.description !== undefined) description = input.description
        if (input.successCriteria !== undefined) successCriteria = input.successCriteria
        if (input.targetDate !== undefined) {
          if (!isNaturalDate(input.targetDate)) throw new TypeError('targetDate must be YYYY-MM-DD')
          targetDate = input.targetDate
        }
      } else if (input.action === 'complete') {
        if (goal.status !== 'active') throw new GoalCommandError('invalid_transition', 'Only an active goal can be completed.')
        const open = this.#one<{ count: number }>(`SELECT COUNT(*) AS count FROM tasks
          WHERE goal_id = ? AND status NOT IN ('completed', 'canceled')`, id)?.count ?? 0
        if (open > 0) throw new GoalCommandError('goal_has_open_tasks', 'Resolve unfinished tasks before completing this goal.')
        status = 'completed'
      } else if (input.action === 'archive') {
        if (goal.status === 'archived') throw new GoalCommandError('invalid_transition', 'Goal is already archived.')
        archivedFromStatus = goal.status
        status = 'archived'
      } else if (input.action === 'restore') {
        if (goal.status !== 'archived') throw new GoalCommandError('invalid_transition', 'Only an archived goal can be restored.')
        status = goal.archivedFromStatus ?? 'active'
        archivedFromStatus = null
      } else {
        if (goal.status !== 'completed') throw new GoalCommandError('invalid_transition', 'Only a completed goal can be reopened.')
        status = 'active'
      }

      const now = this.#clock().toISOString()
      this.#db.prepare(`UPDATE goals SET title = ?, description = ?, success_criteria = ?,
        target_date = ?, status = ?, archived_from_status = ?, revision = revision + 1,
        view_revision = view_revision + 1, updated_at = ? WHERE id = ?`).run(
        title, description, successCriteria, targetDate, status, archivedFromStatus, now, id,
      )
      return this.#one<GoalRecord>(`SELECT ${GOAL_COLUMNS} FROM goals WHERE id = ?`, id)!
    })
  }

  createTask(goalId: string, input: CreateTaskInput): CommandResult<TaskRecord> | null {
    if (!input.title.trim()) throw new TypeError('title must be non-empty')
    if (!isNaturalDate(input.dueDate)) throw new TypeError('dueDate must be YYYY-MM-DD')
    return this.#executeCommand(input.deviceId, input.commandId, `create_task:${goalId}`, input, () => {
      const goal = this.#one<GoalRecord>(`SELECT ${GOAL_COLUMNS} FROM goals WHERE id = ?`, goalId)
      if (!goal) return null
      if (goal.status !== 'active') throw new GoalCommandError('goal_read_only', 'Restore or reopen the goal before adding tasks.')
      const count = this.#one<{ count: number }>('SELECT COUNT(*) AS count FROM tasks WHERE goal_id = ?', goalId)?.count ?? 0
      if (count >= 100) throw new GoalCommandError('task_limit', 'A goal can contain at most 100 tasks.')
      const now = this.#clock().toISOString()
      const task: TaskRecord = {
        id: randomUUID(), ownerId: OWNER_ID, goalId, title: input.title,
        description: input.description ?? null, dueDate: input.dueDate ?? null,
        status: 'todo', blockedReason: null, resultNote: null, revision: 1,
        createdAt: now, updatedAt: now,
      }
      this.#db.prepare(`INSERT INTO tasks
        (id, owner_id, goal_id, title, description, due_date, status,
         blocked_reason, result_note, revision, created_at, updated_at)
        VALUES (?, ?, ?, ?, ?, ?, 'todo', NULL, NULL, 1, ?, ?)`).run(
        task.id, OWNER_ID, goalId, task.title, task.description, task.dueDate, now, now,
      )
      this.#insertProgress(task.id, input.deviceId, 'status', null, null, 'todo', now)
      this.#touchGoal(goalId, now)
      return task
    })
  }

  getTask(id: string, page: { after?: number; limit?: number; revision?: number } = {}): TaskView | null {
    return this.#transaction(() => {
      const task = this.#one<TaskRecord>(`SELECT ${TASK_COLUMNS} FROM tasks WHERE id = ?`, id)
      if (!task) return null
      const after = page.after ?? 0
      const limit = Math.min(page.limit ?? 50, 100)
      if (!Number.isSafeInteger(after) || after < 0 || !Number.isSafeInteger(limit) || limit < 1) {
        throw new RangeError('Progress pagination values are invalid.')
      }
      if (page.revision !== undefined && page.revision !== task.revision) {
        throw new GoalCommandError('progress_revision_conflict', 'Task progress changed; reload before continuing pagination.')
      }
      const total = Number(this.#one<{ count: number }>(
        'SELECT COUNT(*) AS count FROM progress_entries WHERE task_id = ?', id,
      )?.count ?? 0)
      const progressEntries = this.#all<ProgressEntry>(`SELECT ${PROGRESS_COLUMNS}
        FROM progress_entries WHERE task_id = ? ORDER BY created_at ASC, id ASC LIMIT ? OFFSET ?`,
      id, limit, after)
      const next = after + progressEntries.length
      return { task, progressEntries, nextCursor: next < total ? next : null, progressRevision: task.revision }
    })
  }

  updateTask(id: string, input: TaskCommandInput): CommandResult<TaskRecord> | null {
    return this.#executeCommand(input.deviceId, input.commandId, `task:${id}`, input, () => {
      const task = this.#one<TaskRecord>(`SELECT ${TASK_COLUMNS} FROM tasks WHERE id = ?`, id)
      if (!task) return null
      if (input.expectedRevision !== task.revision) {
        throw new GoalCommandError('revision_conflict', 'Task has changed; reload before saving.')
      }
      const goal = this.#one<{ status: GoalStatus }>('SELECT status FROM goals WHERE id = ?', task.goalId)
      if (!goal) return null
      if (goal.status !== 'active') throw new GoalCommandError('goal_read_only', 'Restore or reopen the goal before editing its tasks.')
      const now = this.#clock().toISOString()
      let title = task.title
      let description = task.description
      let dueDate = task.dueDate
      let status = task.status
      let blockedReason = task.blockedReason
      let resultNote = task.resultNote

      if (input.action === 'update') {
        if (input.title !== undefined) {
          if (!input.title.trim()) throw new TypeError('title must be non-empty')
          title = input.title
        }
        if (input.description !== undefined) description = input.description
        if (input.dueDate !== undefined) {
          if (!isNaturalDate(input.dueDate)) throw new TypeError('dueDate must be YYYY-MM-DD')
          dueDate = input.dueDate
        }
        if (title === task.title && description === task.description && dueDate === task.dueDate) {
          throw new GoalCommandError('empty_command', 'Task update contains no changes.')
        }
      } else if (input.action === 'progress') {
        if (!input.note.trim()) throw new TypeError('note must be non-empty')
        this.#insertProgress(id, input.deviceId, 'note', input.note, null, null, now)
      } else {
        if (input.status === task.status || !this.#canTransitionTask(task.status, input.status)) {
          throw new GoalCommandError('invalid_transition', `Cannot change task status from ${task.status} to ${input.status}.`)
        }
        if (input.status === 'blocked' && !(input.note ?? '').trim()) {
          throw new GoalCommandError('blocked_reason_required', 'A reason is required when a task is blocked.')
        }
        status = input.status
        blockedReason = status === 'blocked' ? input.note!.trim() : null
        resultNote = status === 'completed' ? (input.resultNote?.trim() || null) : null
        this.#insertProgress(id, input.deviceId, 'status',
          status === 'blocked' ? blockedReason : (input.note ?? null), task.status, status, now)
        if (status === 'completed' && resultNote) {
          this.#insertProgress(id, input.deviceId, 'result', resultNote, task.status, status, now)
        }
      }

      this.#db.prepare(`UPDATE tasks SET title = ?, description = ?, due_date = ?, status = ?,
        blocked_reason = ?, result_note = ?, revision = revision + 1, updated_at = ? WHERE id = ?`).run(
        title, description, dueDate, status, blockedReason, resultNote, now, id,
      )
      this.#touchGoal(task.goalId, now)
      return this.#one<TaskRecord>(`SELECT ${TASK_COLUMNS} FROM tasks WHERE id = ?`, id)!
    })
  }

  getRun(id: string): RunRecord | null {
    return this.#one<RunRecord>(`SELECT ${RUN_COLUMNS} FROM runs WHERE id = ?`, id)
  }

  leaseRun(input: { leaseMs: number; goalQuestionsVersion?: number }): RunLease | null {
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
        WHERE status = 'queued' AND (goal_id IS NULL OR ? = 1)
        ORDER BY created_at ASC, rowid ASC LIMIT 1`, input.goalQuestionsVersion === 1 ? 1 : 0)
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

  #executeCommand<T>(
    deviceId: string,
    commandId: string,
    operation: string,
    payload: unknown,
    work: () => T | null,
  ): CommandResult<T> | null {
    if (!deviceId.trim() || !commandId.trim()) throw new TypeError('deviceId and commandId are required')
    const payloadHash = createHash('sha256').update(canonicalJson({ operation, payload })).digest('hex')
    return this.#transaction(() => {
      const receipt = this.#one<{ operation: string; payloadHash: string; resultJson: string }>(
        `SELECT operation, payload_hash AS payloadHash, result_json AS resultJson
         FROM command_receipts WHERE device_id = ? AND command_id = ?`, deviceId, commandId,
      )
      if (receipt) {
        if (receipt.operation !== operation || receipt.payloadHash !== payloadHash) {
          throw new GoalCommandError('command_id_conflict', 'commandId was already used for a different operation or payload.')
        }
        return { value: JSON.parse(receipt.resultJson) as T, created: false }
      }
      const value = work()
      if (value === null) return null
      this.#db.prepare(`INSERT INTO command_receipts
        (device_id, command_id, operation, payload_hash, result_json, created_at)
        VALUES (?, ?, ?, ?, ?, ?)`).run(
        deviceId, commandId, operation, payloadHash, JSON.stringify(value), this.#clock().toISOString(),
      )
      return { value, created: true }
    })
  }

  #insertGoalContext(runId: string, goalId: string, asOf: string): void {
    const goal = this.#one<GoalRecord>(`SELECT ${GOAL_COLUMNS} FROM goals WHERE id = ?`, goalId)
    if (!goal) throw new GoalCommandError('goal_not_found', 'Goal not found.')
    const tasks = this.#all<TaskRecord>(`SELECT ${TASK_COLUMNS} FROM tasks
      WHERE goal_id = ? ORDER BY CASE status
        WHEN 'blocked' THEN 0 WHEN 'in_progress' THEN 1 WHEN 'todo' THEN 2
        WHEN 'completed' THEN 3 ELSE 4 END, created_at ASC, id ASC`, goalId)
    const truncatedFields = new Set<string>()
    const clip = (value: string | null, limit: number, field: string): string | null => {
      if (value === null || value.length <= limit) return value
      truncatedFields.add(field)
      return value.slice(0, limit)
    }
    const boundedGoal: GoalRecord = {
      ...goal,
      title: clip(goal.title, 500, 'goal.title')!,
      description: clip(goal.description, 1_500, 'goal.description'),
      successCriteria: clip(goal.successCriteria, 1_500, 'goal.successCriteria'),
    }
    const totalProgress = new Map<string, number>()
    const includedTasks: GoalQuestionTask[] = []
    const reasons = new Set<string>()
    for (const task of tasks) {
      const count = Number(this.#one<{ count: number }>(
        'SELECT COUNT(*) AS count FROM progress_entries WHERE task_id = ?', task.id,
      )?.count ?? 0)
      totalProgress.set(task.id, count)
      if (includedTasks.length >= 30) continue
      const history = this.#all<ProgressEntry>(`SELECT ${PROGRESS_COLUMNS}
        FROM progress_entries WHERE task_id = ? ORDER BY created_at DESC, id DESC LIMIT 3`, task.id).reverse()
      const safeTask: TaskRecord = {
        ...task,
        title: clip(task.title, 400, `tasks.${task.id}.title`)!,
        description: clip(task.description, 800, `tasks.${task.id}.description`),
        blockedReason: clip(task.blockedReason, 500, `tasks.${task.id}.blockedReason`),
        resultNote: clip(task.resultNote, 500, `tasks.${task.id}.resultNote`),
      }
      const safeHistory = history.map(entry => ({
        ...entry, note: clip(entry.note, 400, `tasks.${task.id}.progress.${entry.id}.note`),
      }))
      includedTasks.push({ task: safeTask, progressEntries: safeHistory })
    }
    if (tasks.length > 30) reasons.add('task_limit')
    if ([...totalProgress.values()].some(count => count > 3)) reasons.add('progress_limit')
    if (truncatedFields.size > 0) reasons.add('text_truncated')

    const summary = this.#goalSummary(goalId, goal.updatedAt)
    const makeContext = (): GoalQuestionContext => {
      const omittedTasks = tasks.length - includedTasks.length
      let omittedProgress = 0
      for (const task of tasks) {
        const available = includedTasks.find(item => item.task.id === task.id)?.progressEntries.length ?? 0
        omittedProgress += Math.max(0, (totalProgress.get(task.id) ?? 0) - available)
      }
      const finalTruncatedFields = [...truncatedFields].filter(field =>
        field.startsWith('goal.') || includedTasks.some(item => field.startsWith(`tasks.${item.task.id}.`)))
      const finalReasons = new Set(reasons)
      if (finalTruncatedFields.length === 0) finalReasons.delete('text_truncated')
      return {
        runId, goalId, goal: boundedGoal, viewRevision: this.#viewRevision(goalId), asOf,
        summary, includedTasks,
        omissions: {
          taskCount: omittedTasks,
          progressEntryCount: omittedProgress,
          truncatedFields: finalTruncatedFields.sort(),
          reasons: [...finalReasons].sort(),
        },
      }
    }
    let context = makeContext()
    while (JSON.stringify(context).length > 16_000 && includedTasks.length > 0) {
      includedTasks.pop()!
      reasons.add('context_size')
      context = makeContext()
    }
    if (JSON.stringify(context).length > 16_000) {
      throw new GoalCommandError('goal_context_too_large', 'Goal context cannot fit the bounded snapshot limit.')
    }
    this.#db.prepare(`INSERT INTO goal_contexts (run_id, goal_id, context_json, created_at)
      VALUES (?, ?, ?, ?)`).run(runId, goalId, JSON.stringify(context), asOf)
  }

  #goalSummary(goalId: string, goalUpdatedAt: string): import('./types.ts').GoalSummary {
    const counts = this.#one<{
      completed: number
      total: number
      blocked: number
      todo: number
      inProgress: number
      canceled: number
      latestUpdatedAt: string | null
    }>(`SELECT
        SUM(CASE WHEN status = 'completed' THEN 1 ELSE 0 END) AS completed,
        SUM(CASE WHEN status = 'todo' THEN 1 ELSE 0 END) AS todo,
        SUM(CASE WHEN status = 'in_progress' THEN 1 ELSE 0 END) AS inProgress,
        SUM(CASE WHEN status <> 'canceled' THEN 1 ELSE 0 END) AS total,
        SUM(CASE WHEN status = 'blocked' THEN 1 ELSE 0 END) AS blocked,
        SUM(CASE WHEN status = 'canceled' THEN 1 ELSE 0 END) AS canceled,
        MAX(updated_at) AS latestUpdatedAt
      FROM tasks WHERE goal_id = ?`, goalId)!
    return {
      completedTasks: Number(counts.completed ?? 0),
      todoTasks: Number(counts.todo ?? 0),
      inProgressTasks: Number(counts.inProgress ?? 0),
      activeTasks: Number(counts.total ?? 0),
      blockedTasks: Number(counts.blocked ?? 0),
      canceledTasks: Number(counts.canceled ?? 0),
      completionPercent: Number(counts.total ?? 0) === 0
        ? null
        : Math.round(Number(counts.completed ?? 0) / Number(counts.total) * 100),
      latestUpdatedAt: counts.latestUpdatedAt && counts.latestUpdatedAt > goalUpdatedAt
        ? counts.latestUpdatedAt : goalUpdatedAt,
    }
  }

  #viewRevision(goalId: string): number {
    return this.#one<{ viewRevision: number }>(
      'SELECT view_revision AS viewRevision FROM goals WHERE id = ?', goalId,
    )!.viewRevision
  }

  #canTransitionTask(from: TaskStatus, to: TaskStatus): boolean {
    if (from === 'completed' || from === 'canceled') return to === 'todo'
    return ['todo', 'in_progress', 'blocked', 'completed', 'canceled'].includes(to) && from !== to
  }

  #insertProgress(
    taskId: string,
    actorDeviceId: string,
    kind: ProgressKind,
    note: string | null,
    fromStatus: TaskStatus | null,
    toStatus: TaskStatus | null,
    createdAt: string,
  ): ProgressEntry {
    const entry: ProgressEntry = {
      id: randomUUID(), taskId, actorDeviceId, kind, note, fromStatus, toStatus, createdAt,
    }
    this.#db.prepare(`INSERT INTO progress_entries
      (id, task_id, actor_device_id, kind, note, from_status, to_status, created_at)
      VALUES (?, ?, ?, ?, ?, ?, ?, ?)`).run(
      entry.id, taskId, actorDeviceId, kind, note, fromStatus, toStatus, createdAt,
    )
    return entry
  }

  #touchGoal(goalId: string, now: string): void {
    this.#db.prepare(`UPDATE goals SET view_revision = view_revision + 1, updated_at = ? WHERE id = ?`)
      .run(now, goalId)
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
