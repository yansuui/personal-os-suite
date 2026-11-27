/**
 * 云端 v2 的共享数据类型。
 *
 * 只放「跨文件契约」：存储记录与对外 DTO。所有时间都是 ISO-8601 UTC 字符串。
 * `ownerId` 现在固定为 `default`（单用户）；引入真租户前不动这个字段的语义。
 */

export const OWNER_ID = 'default'

export type DeviceRole = 'client' | 'agent'
export type MessageRole = 'user' | 'assistant' | 'system'
export type RunStatus = 'queued' | 'running' | 'completed' | 'failed' | 'canceled'

export interface DeviceRecord {
  id: string
  name: string
  role: DeviceRole
  tokenHash: string
  createdAt: string
  lastSeenAt: string | null
  revokedAt: string | null
}

export interface ConversationRecord {
  id: string
  ownerId: string
  title: string | null
  createdAt: string
  updatedAt: string
}

export interface MessageRecord {
  id: string
  conversationId: string
  role: MessageRole
  text: string
  clientRequestId: string | null
  seq: number
  createdAt: string
}

export interface RunRecord {
  id: string
  conversationId: string
  messageId: string
  status: RunStatus
  leaseToken: string | null
  leasedUntil: string | null
  createdAt: string
  startedAt: string | null
  finishedAt: string | null
  resultText: string | null
  error: string | null
  /** Optional for decoding runs created by an older server/cache. */
  goalId?: string | null
}

export interface RunLease {
  run: RunRecord
  leaseToken: string
}

export type GoalStatus = 'active' | 'completed' | 'archived'
export type TaskStatus = 'todo' | 'in_progress' | 'blocked' | 'completed' | 'canceled'
export type ProgressKind = 'status' | 'note' | 'result'

export interface GoalRecord {
  id: string
  ownerId: string
  title: string
  description: string | null
  successCriteria: string | null
  targetDate: string | null
  status: GoalStatus
  archivedFromStatus: Exclude<GoalStatus, 'archived'> | null
  revision: number
  createdAt: string
  updatedAt: string
}

export interface TaskRecord {
  id: string
  ownerId: string
  goalId: string
  title: string
  description: string | null
  dueDate: string | null
  status: TaskStatus
  blockedReason: string | null
  resultNote: string | null
  revision: number
  createdAt: string
  updatedAt: string
}

export interface ProgressEntry {
  id: string
  taskId: string
  actorDeviceId: string
  kind: ProgressKind
  note: string | null
  fromStatus: TaskStatus | null
  toStatus: TaskStatus | null
  createdAt: string
}

export interface GoalSummary {
  completedTasks: number
  todoTasks: number
  inProgressTasks: number
  activeTasks: number
  blockedTasks: number
  canceledTasks: number
  /** Null when there are no non-canceled tasks. */
  completionPercent: number | null
  latestUpdatedAt: string
}

export interface GoalListItem extends GoalRecord {
  summary: GoalSummary
  viewRevision: number
}

export interface GoalView {
  goal: GoalRecord
  tasks: TaskRecord[]
  summary: GoalSummary
  viewRevision: number
  asOf: string
}

export interface TaskView {
  task: TaskRecord
  progressEntries: ProgressEntry[]
  nextCursor: number | null
  progressRevision: number
}

export interface GoalQuestionTask {
  task: TaskRecord
  progressEntries: ProgressEntry[]
}

export interface GoalQuestionContext {
  runId: string
  goalId: string
  goal: GoalRecord
  viewRevision: number
  asOf: string
  summary: GoalSummary
  includedTasks: GoalQuestionTask[]
  omissions: {
    taskCount: number
    progressEntryCount: number
    truncatedFields: string[]
    reasons: string[]
  }
}

export interface CommandResult<T> {
  value: T
  created: boolean
}

/** POST /v2/conversations/:id/messages 的返回：写入的消息 + 为它创建（或复用）的运行。 */
export interface MessageWithRun {
  message: MessageRecord
  run: RunRecord
  /** false 表示命中 clientRequestId 幂等，未写入新消息。 */
  created: boolean
}
