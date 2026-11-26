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
}

export interface RunLease {
  run: RunRecord
  leaseToken: string
}

/** POST /v2/conversations/:id/messages 的返回：写入的消息 + 为它创建（或复用）的运行。 */
export interface MessageWithRun {
  message: MessageRecord
  run: RunRecord
  /** false 表示命中 clientRequestId 幂等，未写入新消息。 */
  created: boolean
}
