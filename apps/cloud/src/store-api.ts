/**
 * 存储层契约（store 与 HTTP 层之间的唯一接口）。
 *
 * `store.ts` 里的 `CloudStore` 必须实现本接口；`server.ts` 只依赖本接口 + types.ts。
 * 方法抛错即视为 500；「找不到」一律返回 null，由 HTTP 层映射成 404。
 */
import type {
  ConversationRecord,
  DeviceRecord,
  DeviceRole,
  GoalQuestionContext,
  GoalListItem,
  GoalStatus,
  GoalView,
  GoalRecord,
  CommandResult,
  TaskRecord,
  TaskStatus,
  TaskView,
  MessageRecord,
  MessageWithRun,
  RunLease,
  RunRecord,
  RunStatus,
} from './types.ts'

export interface StoreClock {
  (): Date
}

export interface InsertMessageInput {
  conversationId: string
  role: 'user' | 'assistant' | 'system'
  text: string
  /** 客户端幂等键；同一会话内重复提交必须复用同一条消息与同一个运行。 */
  clientRequestId: string | null
  /** 目标关联提问时由服务端绑定；普通聊天保持 null/缺省。 */
  goalId?: string | null
}
export interface CreateGoalInput {
  deviceId: string
  commandId: string
  title: string
  description?: string | null
  successCriteria?: string | null
  targetDate?: string | null
}

export type GoalCommandInput = {
  deviceId: string
  commandId: string
  expectedRevision: number
} & (
  | { action: 'update'; title?: string; description?: string | null; successCriteria?: string | null; targetDate?: string | null }
  | { action: 'complete' | 'archive' | 'restore' | 'reopen' }
)

export interface CreateTaskInput {
  deviceId: string
  commandId: string
  title: string
  description?: string | null
  dueDate?: string | null
}

export type TaskCommandInput = {
  deviceId: string
  commandId: string
  expectedRevision: number
} & (
  | { action: 'update'; title?: string; description?: string | null; dueDate?: string | null }
  | { action: 'progress'; note: string }
  | { action: 'set_status'; status: TaskStatus; note?: string | null; resultNote?: string | null }
)

export class GoalCommandError extends Error {
  readonly code: string
  constructor(code: string, message: string) {
    super(message)
    this.name = 'GoalCommandError'
    this.code = code
  }
}

export interface CompleteRunInput {
  status: Exclude<RunStatus, 'queued' | 'running'>
  resultText?: string | null
  error?: string | null
}

export interface CloudStoreApi {
  readonly dbPath: string

  close(): void

  // --- 设备 ---
  pairDevice(input: { name: string; role: DeviceRole; tokenHash: string }): DeviceRecord
  deviceByTokenHash(tokenHash: string): DeviceRecord | null
  deviceById(id: string): DeviceRecord | null
  touchDevice(id: string, at?: Date): void

  // --- 会话 ---
  createConversation(input: { title?: string | null }): ConversationRecord
  listConversations(): ConversationRecord[]
  getConversation(id: string): ConversationRecord | null

  // --- 消息 ---
  /** 按 seq 升序返回 after 之后的消息；limit 默认 200，最大 500。 */
  listMessages(conversationId: string, afterSeq: number, limit?: number): MessageRecord[]
  /**
   * 追加一条用户消息并为它创建 queued 运行。
   * - clientRequestId 命中（同会话）时返回原记录，`created: false`；
   * - seq 在事务内递增，不允许重复；
   * - 同时把会话 updatedAt 推到 now。
   */
  appendUserMessage(input: InsertMessageInput): MessageWithRun
  /** 读取某次运行实际绑定的目标快照；普通聊天返回 null。 */
  goalContextForRun(runId: string): GoalQuestionContext | null

  // --- 运行 ---
  getRun(id: string): RunRecord | null
  /** Take the earliest eligible queued run. Old workers cannot lease goal runs. */
  leaseRun(input: { leaseMs: number; goalQuestionsVersion?: number }): RunLease | null
  /** 校验 leaseToken；成功后按 status 落终态并写 resultText/error。租约失效返回 null。 */
  completeRun(id: string, leaseToken: string, input: CompleteRunInput): RunRecord | null
  /** 取消 queued 或 running 的运行；已终态返回原记录（幂等）。 */
  cancelRun(id: string): RunRecord | null

  // --- 目标与业务任务 ---
  listGoals(status?: GoalStatus, after?: number, limit?: number): {
    goals: GoalListItem[]
    nextCursor: number | null
  }
  getGoalView(id: string): GoalView | null
  createGoal(input: CreateGoalInput): CommandResult<GoalRecord>
  updateGoal(id: string, input: GoalCommandInput): CommandResult<GoalRecord> | null
  createTask(goalId: string, input: CreateTaskInput): CommandResult<TaskRecord> | null
  getTask(id: string, page?: { after?: number; limit?: number; revision?: number }): TaskView | null
  updateTask(id: string, input: TaskCommandInput): CommandResult<TaskRecord> | null

  // --- 维护 ---
  /** 测试与运维用：把过期租约的 running 运行放回 queued。返回放回条数。 */
  requeueExpiredLeases(): number
}
