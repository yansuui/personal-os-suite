# personal-os 三端最小一致契约 v2（冻结）

状态：冻结（2026-11-25）。本文件是 `apps/cloud`、`apps/iphone`、`apps/dsh-plugin` 本轮实现的唯一跨端事实源；三端不得在实现中扩展或改变以下字段语义。`packages/contracts/openapi.yaml` 与 `v2-cloud-api.md` 提供同一协议的机器/说明版本。

## 1. 范围与边界

本轮只闭环：**手机/桌面 client 发消息 → 云端排队 → agent 领取并完成 → 两个 client 通过消息游标读到 assistant 回复**。不纳入模型调用、记忆、计划、任务审批、推送、附件、多租户和设备撤销。云端服务是权威会话/消息/运行队列；DSH 插件是桌面镜像与本机 agent 适配层；iOS 是 v2 client。

未实现能力必须显式返回“不支持/未接入”，不得把 v1 任务或审批接口伪装成 v2 能力。

## 2. 身份与 ID

- `ownerId`：单用户固定 `default`，仅作为存储字段；本轮不做多租户隔离。
- `deviceId`：云端配对生成的设备 ID；`role` 只有 `client` / `agent`。
- `conversationId`、`messageId`、`runId`：云端生成的全局不透明字符串，仅允许 `[A-Za-z0-9_-]+`。
- `clientRequestId`：客户端为一次用户消息生成并持久复用的非空幂等键；同一会话内重复提交返回首次消息与运行。
- `seq`：每个会话从 1 开始单调递增；用户和 assistant 消息共用同一序列。
- `leaseToken`：agent 领取运行时返回的不透明 fencing token；过期或不匹配不得落结果。

## 3. 认证与错误

- 健康检查 `GET /v2/health` 无认证。
- 配对 `POST /v2/pair` 只接受 `x-pair-secret`，body `{name, role}`，其中 role 为 `client|agent`。
- 其余端点使用 `Authorization: Bearer <token>`。
- 错误体固定 `{ "error": { "code": string, "message": string } }`；主要 HTTP 映射：400 参数/JSON、401 认证、403 角色、404 不存在、409 租约冲突、413 body 超限、500 内部错误。
- token 只在配对响应出现一次，服务端只存 SHA-256；三端不得日志输出 token、pair secret 或 leaseToken。

## 4. 最小端点与 wire shape

### 健康/配对

- `GET /v2/health` → `200 {ok:true, service:"personal-os-cloud", protocolVersion:2, dbPath?:string, model?:string}`。`model` 为 2026-11-26 手机型号显示需求增加的兼容可选元数据：当前 worker 配置的请求型号，不代表每条历史回复的上游实际型号，也不代表 worker 在线。未配置时省略，客户端须兼容缺省；不返回模型端点或凭据。
- `POST /v2/pair` + `x-pair-secret` + `{name:string, role:"client"|"agent"}` → `201 {device:Device, token:string}`。
- `GET /v2/me` → `200 {device:Device}`。
- `Device` 至少含 `{id,name,role,createdAt,lastSeenAt,revokedAt}`；客户端只依赖 `id/name/role/createdAt`。

### 会话/消息

- `POST /v2/conversations` + `{title?:string|null}` → `201 {conversation:Conversation}`。
- `GET /v2/conversations` → `200 {conversations:Conversation[]}`。
- `Conversation` 为 `{id,ownerId,title,createdAt,updatedAt}`。
- `POST /v2/conversations/:conversationId/messages` + `{clientRequestId,text}` → 新建 `201` 或幂等重放 `200`，body `{message:Message,run:Run,created:boolean}`。
- `GET /v2/conversations/:conversationId/messages?after=<seq>&wait=<0..25>` → `200 {messages:Message[],nextCursor:number}`；空页保持请求 cursor；消息按 seq 升序，最多返回 200 条。
- `Message` 为 `{id,conversationId,role:"user"|"assistant"|"system",text,clientRequestId:null|string,seq,createdAt}`。

### 运行

- `POST /v2/runs/lease` + `{leaseMs?:1..86400000}`（仅 agent）→ `{run:Run|null,leaseToken:string|null}`；无任务返回两个 null。
- `GET /v2/runs/:runId` → `{run:Run}`。
- `POST /v2/runs/:runId/complete` + `{leaseToken,status:"completed"|"failed",resultText?:string|null,error?:string|null}`（仅 agent）→ `{run:Run}`。completed 且 resultText 非空时同事务追加 assistant Message。
- `POST /v2/runs/:runId/cancel` → `{run:Run}`；queued/running 变 canceled，终态幂等返回。
- `Run` 为 `{id,conversationId,messageId,status,leaseToken?,leasedUntil?,createdAt,startedAt?,finishedAt?,resultText?,error?}`；客户端至少依赖 id/status/conversationId/messageId。

## 5. 状态与一致性

- Run 状态：`queued → running → completed|failed|canceled`；租约过期 `running → queued`。
- 同一时刻最多一个 running lease；fencing 失败返回 409。
- `complete` 只接受 completed/failed；取消只能走 cancel。
- client 重试必须复用 clientRequestId；不能覆盖本地新数据，409 必须刷新。
- 长轮询最多 25 秒；客户端普通 HTTP 超时 15 秒，长轮询超时至少 `wait+10` 且不少于 30 秒。

## 6. 三端责任与本轮验收

- **Cloud**：实现本文件端点、持久化、幂等、游标、租约 fencing；不调用模型。
- **iOS**：只调用 v2 端点；保存 AuthSession；创建/选择 conversation；发送消息并用 after/wait 增量同步；离线首屏读取本地快照。
- **DSH plugin**：Host 注册 v2 client/agent 适配；Client 只提供一个“Personal OS”右栏/工具入口，不替换原生 Conversation；本地 agent 可选地 lease/complete，默认只读镜像。
- 本地验收必须覆盖：health、pair(client+agent)、conversation、message 幂等、lease、complete、assistant 长轮询；跨端代码静态遵循相同字段。
- 未部署云端、未在 iPhone 真机安装、未在用户 DSH profile 安装插件的事实必须在交付报告中标明。
