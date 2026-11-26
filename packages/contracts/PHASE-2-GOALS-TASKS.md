# P2-A 目标、任务与目标问答扩展契约（冻结）

状态：冻结，2026-11-26。本文是 `packages/contracts/MINIMAL-V2-CONTRACT.md` 的兼容增量；P2-A 只增加目标/业务任务/固定目标问答，不改变已验收普通聊天的 wire 语义。云端实现归 `apps/cloud`，客户端实现归 iPhone。单用户 `ownerId=default`。

## 1. 能力发现与安全启用

- `GET /v2/capabilities` → `{goalsTasksVersion:1, goalQuestionsVersion:0|1}`。目标/任务 API 版本为 1；目标问答仅当服务端显式启用时报告 1，否则报告 0。
- 服务端默认关闭目标问答。生产启动开关为 `POS_GOAL_QUESTIONS_ENABLED`; 仅接受 `0` 或 `1`，缺省为 `0`，其他值启动失败。开关关闭时 `POST /v2/goals/:id/questions` 返回 `409 goal_questions_disabled`，不写消息、run 或快照；客户端不得把问答请求重发到普通聊天入口。
- worker `POST /v2/runs/lease` body 可带 `goalQuestionsVersion:1`。声明支持的 worker 可领取普通 run 与目标问答 run；缺省/不支持的旧 worker 只能领取普通 run，服务端会跳过 goal-question run。目标 run 不会被旧 worker 领取后当普通聊天执行。
- 普通 run 的 `Run.goalId` 为 `null`。目标 run 的 `Run.goalId` 为其目标 ID。该字段是新增可选兼容字段：旧 server/cache 可能省略；worker 将省略视作普通 run。新客户端解码应允许缺省。

## 2. 身份、状态及字段限制

- 目标：`GoalRecord={id,ownerId,title,description,successCriteria,targetDate,status,archivedFromStatus,revision,createdAt,updatedAt}`；`status=active|completed|archived`。
- 任务：`TaskRecord={id,ownerId,goalId,title,description,dueDate,status,blockedReason,resultNote,revision,createdAt,updatedAt}`；`status=todo|in_progress|blocked|completed|canceled`。每目标最多 100 条，首版不删除、不移动、不嵌套。
- 所有可空字段更新使用 JSON `null` 清空；字段缺省表示不修改。日期是 `YYYY-MM-DD` 自然日。时间戳是 UTC ISO-8601。
- 每个写操作都带 `commandId`；编辑/状态操作还需 `expectedRevision`。同一设备、同一 commandId 与操作/正文完全相同返回首次结果；不同操作或正文返回 `409 command_id_conflict`，不产生副作用。成功回执优先于版本检查。
- Goal update: `POST /v2/goals/:id/commands` body `{commandId,expectedRevision,action:"update",title?,description?,successCriteria?,targetDate?}`；其他 action 为 `complete|archive|restore|reopen`。
- Task create: `POST /v2/goals/:id/tasks` body `{commandId,title,description?,dueDate?}`。Task command: `POST /v2/tasks/:id/commands`，action 为 `update`（`title?`,`description?`,`dueDate?`）、`progress`（`note`）或 `set_status`（`status`,`note?`,`resultNote?`）。设置 `blocked` 必须有非空 `note`；转离 blocked 后当前 `blockedReason` 清空，历史进展保留。取消状态为 `canceled`；完成/取消后继续需显式改回 `todo`。
- 主要冲突错误为 `409 revision_conflict|command_id_conflict|goal_question_conflict|progress_revision_conflict`；缺少目标/任务为 404；agent 不能写业务实体。

## 3. 目标/任务读取与有界分页

- `GET /v2/goals?status=active|completed|archived&after=0&limit=50` → `{goals:GoalListItem[],nextCursor:number|null}`。`status` 可省略；limit 默认 50、最大 100；`after` 是非负整数偏移，按 `updatedAt` 降序、ID 升序。`nextCursor` 为下一页偏移或 null。
- `GoalListItem` 是 GoalRecord 加 `{summary,viewRevision}`。
- `GET /v2/goals/:id` → `{goalView:{goal,tasks,summary,viewRevision,asOf}}`。任务详情有目标内全量但有上限（最多 100 条），同一事务读取。
- `GoalSummary={completedTasks,todoTasks,inProgressTasks,blockedTasks,canceledTasks,activeTasks,completionPercent,latestUpdatedAt}`。`activeTasks` 是有效总数，即所有非 `canceled` 任务（包含 completed）；五个状态计数均基于全量记录。`completionPercent=completedTasks/activeTasks` 四舍五入到整数；无有效任务时为 null，不能显示虚假的 100%。
- `GET /v2/tasks/:id?progressAfter=0&progressLimit=50&progressRevision=<revision>` → `{task,progressEntries,nextCursor:number|null,progressRevision:number}`。记录按创建时间和 ID 升序，以稳定整数偏移分页；limit 默认 50、最大 100。首屏返回当前 task revision；后续页必须携带首屏的 `progressRevision`。若任务 revision 已变化，返回 `409 progress_revision_conflict`，客户端刷新后从首屏重读，不能拼接不同版本的进展历史。进展日志只追加不删除。

## 4. 目标问答快照

- `POST /v2/goals/:id/questions` body `{conversationId,clientRequestId,text}` → 新建 `201` 或幂等重放 `200`，响应沿用 `{message,run,created}`。在一个数据库事务内追加 user message、run 与快照。
- 幂等键以会话为范围。目标入口同键重试必须匹配同目标、同文本且既有 run 为目标问答；否则 `409 goal_question_conflict`。目标入口与普通消息入口发生键碰撞严格冲突（即使正文相同也不可跨意图复用）。既有普通聊天语义保持不变：普通入口同键再次提交不同正文仍返回首次普通消息/run，不新建记录；但普通入口不得重放既有目标问答键。
- 每个目标 run 只绑定创建时生成并持久保存的 `GoalQuestionContext`；后续修改目标/任务不改变已存快照。普通 run 的 context 是 null。
- `GET /v2/runs/:id/goal-context` → `{goalContext:GoalQuestionContext|null}`。目标 run 的快照缺失是明确的非 404 错误；不存在 run 才是 404。仅允许经认证 client/agent 读取。
- `GoalQuestionContext={runId,goalId,goal,viewRevision,asOf,summary,includedTasks,omissions}`；`goal` 为问答时刻完整目标字段，`includedTasks` 为 `[{task,progressEntries}]`。按 blocked、in_progress、todo、completed、canceled 的顺序，再按创建时间/ID，最多纳入 30 条任务；每项最多附最近 3 条进展，保持时间升序。摘要五类计数始终从全量快照统计，不受明细裁切影响。
- 整个序列化上下文（包含目标、统计、任务、进展和 omissions）不得超过 16,000 个字符。目标正文和明细文字若需裁切，按字段固定次序裁切；被裁切的字段写入 `omissions.truncatedFields`。超出任务明细上限或总大小的任务从稳定排序尾部省略；`omissions.taskCount` 是省略任务数，`omissions.progressEntryCount` 是未纳入的全部进展记录数（包括未纳入任务及每任务超过 3 条的旧进展），`omissions.reasons` 列出 `task_limit`、`context_size`、`text_truncated` 等适用原因。`omissions` 形状为 `{taskCount:number,progressEntryCount:number,truncatedFields:string[],reasons:string[]}`，数组排序确定且去重。
- worker 仅在 `Run.goalId` 非 null 时读取 context，且必须验证 `goalContext.runId/goalId` 与该 run 一致。缺失、读取失败或响应过大时运行失败，不得降级成普通聊天。目标标题/说明/成功标准、任务正文和进展均为不可信数据，只作为资料输入；worker 不调用工具、不写业务状态。普通 run 不增加额外读取请求，保持既有模型上下文和取消/失败语义。

## 5. 回滚与验收边界

- 发布顺序：先发布兼容 API（goalQuestionsVersion 保持 0），暂停旧 worker 领取并部署支持 lease capability 与快照读取的新 worker，确认 worker 健康后才开启 `POS_GOAL_QUESTIONS_ENABLED=1`，最后发布 iPhone。关闭 gate 后不再接受新目标问答；已经排队/执行的目标 run 仍通过 run marker 防止被旧 worker 领取，也不得按普通聊天执行。
- 本契约不代表生产已启用、iPhone 已实现或云端已部署。验证仅使用本机隔离 SQLite/HTTP/模型替身，不写生产数据。
