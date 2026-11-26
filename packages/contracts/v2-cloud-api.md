# 云端 v2 会话服务契约（v0.1）

> 目标：把「会话 / 消息 / 运行队列」从桌面插件搬到一个独立进程。桌面只做镜像视图，
> 手机直接读写云端；Agent 进程通过租约领取运行、回写结果。
> 本文件是 `apps/cloud` 的实现契约；`packages/contracts/openapi.yaml` 是机器可读版本。

## 1. 进程与依赖

| 项 | 值 |
|---|---|
| 运行时 | Node.js ≥ 24（直接跑 TypeScript，无需构建） |
| 存储 | `node:sqlite` 单文件数据库 |
| 入口 | `node src/main.ts`（`PORT`、`DB_PATH`、`V2_ADMIN_SECRET` 环境变量） |
| 鉴权 | `Authorization: Bearer <device token>`；配对用 `x-pair-secret` |
| 版本 | `/v2/health` 返回 `protocolVersion: 2` |

## 2. 身份

| 概念 | 说明 |
|---|---|
| `ownerId` | 单用户阶段固定 `default`，写入会话；消息和运行通过 `conversationId` 关联归属。设备 token 只面向该单用户实例，尚非多租户鉴权 |
| `deviceId` | 每台设备一对（token 只存 sha256） |
| `role` | `client`（手机/桌面）或 `agent`（领取运行的云端 Agent） |

`POST /v2/pair` 用管理密钥换设备 token；token 只在响应里出现一次。

## 3. 端点

| 方法 | 路径 | 鉴权 | 说明 |
|---|---|---|---|
| GET | `/v2/health` | 无 | `{ok, service, protocolVersion, dbPath?}`（不回显密钥） |
| POST | `/v2/pair` | `x-pair-secret` | `{name, role}` → 201 `{device, token}` |
| GET | `/v2/me` | Bearer | `{device}` |
| POST | `/v2/conversations` | Bearer | `{title?}` → 201 `{conversation}` |
| GET | `/v2/conversations` | Bearer | `{conversations}` |
| GET | `/v2/conversations/:id/messages?after=<seq>&wait=<0-25>` | Bearer | `{messages, nextCursor}`，`wait>0` 时最多挂起这么久 |
| POST | `/v2/conversations/:id/messages` | Bearer | `{clientRequestId, text}` → 201（幂等命中 200）`{message, run, created}` |
| GET | `/v2/runs/:id` | Bearer | `{run}` |
| POST | `/v2/runs/:id/cancel` | Bearer | `{run}` |
| POST | `/v2/runs/lease` | Bearer(agent) | `{leaseMs}` → `{run, leaseToken}` 或 `{run:null, leaseToken:null}` |
| POST | `/v2/runs/:id/complete` | Bearer(agent) | `{leaseToken, status, resultText?, error?}` → `{run}` |

## 4. 语义

1. **幂等**：`(conversationId, clientRequestId)` 唯一；重放返回原消息与原运行，`created:false`。
2. **seq**：每个会话内单调递增，从 1 开始；消息按 seq 排序，客户端用 `after` 增量拉取。
3. **长轮询**：`wait` 上限 25 秒；有消息立即返回；超时返回空数组，`nextCursor` 保持客户端游标。
4. **运行**：用户消息写入时创建 `queued` 运行；Agent 用 `lease` 领取（租约内 `running`），
   `complete` 落 `completed`/`failed`，`cancel` 可取消 queued/running。
5. **租约**：同一时刻最多一条运行被租；过期租约由 `requeueExpiredLeases()` 放回队列。
6. **错误**：`{error:{code,message}}`；401 未认证、403 角色不符、404 不存在、409 冲突、400 参数。
7. **回复可见性**：Agent 以 `status=completed` 且提供非空 `resultText` 完成运行时，服务端必须在同一事务中追加一条 `role=assistant` 消息、分配下一个会话 `seq` 并更新会话 `updatedAt`；手机通过同一消息长轮询读到回复。无结果文本的完成不追加消息；失败运行只记录失败状态与错误。
8. **完成状态**：`complete` 只接受 `completed` 或 `failed`；取消只通过 cancel 端点完成。租约过期或 fencing token 不匹配不得落结果或追加回复。

## 5. 本轮不做

- 模型调用（Agent 进程下一轮接）；记忆/计划/任务接口（v1 网关仍在跑，迁移时再并）。
- 多用户租户隔离（`ownerId` 已留位，但未做鉴权到用户）。
- 附件、推送、审批。
