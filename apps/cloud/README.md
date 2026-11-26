# 云端 v2 会话服务

`apps/cloud` 是独立运行的 Node.js 24 服务，使用内置 `node:sqlite` 保存会话、消息和运行队列。Node 直接执行 TypeScript，无需构建或运行时第三方依赖。HTTP 契约见 [v2-cloud-api.md](../../packages/contracts/v2-cloud-api.md)，机器可读定义见 [openapi.yaml](../../packages/contracts/openapi.yaml)。

## 启动与验证

要求 Node.js **24 或更新版本**。在仓库根目录的 Bash 中运行：

```bash
export PORT=8787
export DB_PATH=./data/cloud.sqlite
# 隐藏输入管理密钥；生产环境通过部署平台的 secret 注入。
read -r -s -p 'V2_ADMIN_SECRET: ' V2_ADMIN_SECRET; printf '\n'
export V2_ADMIN_SECRET
cd apps/cloud
node src/main.ts
```

也可以在 `apps/cloud` 下运行 `npm start` 或 `pnpm start`，它们都执行 `node src/main.ts`。`DB_PATH` 相对进程工作目录解析；保持启动目录一致以复用同一个数据库文件。服务需要可以写入数据库目录。

| 环境变量 | 默认值 | 含义 |
| --- | --- | --- |
| `PORT` | `8787` | HTTP 监听端口 |
| `DB_PATH` | `./data/cloud.sqlite` | SQLite 文件路径；父目录由服务创建 |
| `V2_ADMIN_SECRET` | 无，必填 | 配对用管理密钥，客户端请求头为 `x-pair-secret` |

在 `apps/cloud` 下运行云端限定检查：

```bash
pnpm install --frozen-lockfile --ignore-scripts
pnpm test
pnpm typecheck
```

包固定 pnpm 11.28.5、TypeScript 5.9.3 和 Node 24 类型；锁文件可复现安装。生产 API 与 worker 仍然只使用 Node 内置模块，无运行时第三方依赖。类型检查必须通过，不再因为缺少编译器而跳过。独立的 `cloud-worker` CI 使用相同锁文件和命令。

默认测试覆盖 API、SQLite、冻结 wire shape，以及独立 worker 的本地模型 HTTP 端到端流程。`worker-e2e.test.ts` 使用随机 loopback 端口、独占临时数据库和本地模型服务，不调用外部模型或生产 API。桌面联调保留为单独的 `node --test test/desktop-e2e.test.ts`，在桌面实现可用的工作区中显式运行；它不属于当前优先开发范围，也不验证真实 DSH profile 激活、浏览器或 iOS App 运行。

Node 24 将显式目录参数 `node --test test/` 当成模块解析，会报 `MODULE_NOT_FOUND`，所以测试脚本显式列出 `.test.ts` 文件。Node 直接执行 TypeScript 不能替代 `pnpm typecheck`。

## curl 示例：客户端与 Agent 闭环

下面的 Bash 示例针对**已启动的服务**，需要 `curl` 与 Node 24。使用一次性本地测试数据库；示例会创建两个设备、一个会话和一条消息。密钥与 token 只保存在变量中，不打印配对响应；不要启用 `set -x`，也不要使用 `curl -v`。

```bash
set +x
BASE_URL=http://127.0.0.1:8787
# 若在另一个终端执行，先隐藏输入与服务一致的管理密钥。
read -r -s -p 'V2_ADMIN_SECRET: ' V2_ADMIN_SECRET; printf '\n'
export V2_ADMIN_SECRET
json_field() {
  node --input-type=module -e '
    let data = "";
    for await (const chunk of process.stdin) data += chunk;
    let value = JSON.parse(data);
    for (const key of process.argv[1].split(".")) value = value[key];
    if (value === undefined || value === null) process.exit(1);
    process.stdout.write(String(value));
  ' "$1"
}

curl --fail --silent --show-error "$BASE_URL/v2/health"

PAIR_JSON=$(curl --fail --silent --show-error \
  -X POST "$BASE_URL/v2/pair" \
  -H "x-pair-secret: $V2_ADMIN_SECRET" -H 'Content-Type: application/json' \
  --data '{"name":"example-client","role":"client"}')
CLIENT_TOKEN=$(printf '%s' "$PAIR_JSON" | json_field token)
unset PAIR_JSON

PAIR_JSON=$(curl --fail --silent --show-error \
  -X POST "$BASE_URL/v2/pair" \
  -H "x-pair-secret: $V2_ADMIN_SECRET" -H 'Content-Type: application/json' \
  --data '{"name":"example-agent","role":"agent"}')
AGENT_TOKEN=$(printf '%s' "$PAIR_JSON" | json_field token)
unset PAIR_JSON

CONVERSATION_JSON=$(curl --fail --silent --show-error \
  -X POST "$BASE_URL/v2/conversations" \
  -H "Authorization: Bearer $CLIENT_TOKEN" -H 'Content-Type: application/json' \
  --data '{"title":"Cloud example"}')
CONVERSATION_ID=$(printf '%s' "$CONVERSATION_JSON" | json_field conversation.id)

MESSAGE_JSON=$(curl --fail --silent --show-error \
  -X POST "$BASE_URL/v2/conversations/$CONVERSATION_ID/messages" \
  -H "Authorization: Bearer $CLIENT_TOKEN" -H 'Content-Type: application/json' \
  --data '{"clientRequestId":"example-message-1","text":"Hello"}')
RUN_ID=$(printf '%s' "$MESSAGE_JSON" | json_field run.id)
CURSOR=$(printf '%s' "$MESSAGE_JSON" | json_field message.seq)
```

相同会话内重复提交 `clientRequestId` 会返回原消息和运行，HTTP 200、`created:false`；首次创建为 HTTP 201、`created:true`。客户端必须为新的用户消息使用新的幂等键。`seq` 从 1 开始在每个会话中递增。

Agent 领取全局最早的一条 queued 运行。下面假定是干净的测试数据库，没有其他待执行运行或 Agent；如 `run:null` 则当前无可领取工作，应稍后重试。生产 Agent 应使用租约响应的 `run.id`，不能假定它与某个刚创建的消息对应。

```bash
LEASE_JSON=$(curl --fail --silent --show-error \
  -X POST "$BASE_URL/v2/runs/lease" \
  -H "Authorization: Bearer $AGENT_TOKEN" -H 'Content-Type: application/json' \
  --data '{"leaseMs":30000}')
LEASED_RUN_ID=$(printf '%s' "$LEASE_JSON" | json_field run.id)
LEASE_TOKEN=$(printf '%s' "$LEASE_JSON" | json_field leaseToken)
unset LEASE_JSON

# 在内存中构造 JSON，不把租约 token 打印到终端。
COMPLETE_JSON=$(LEASE_TOKEN="$LEASE_TOKEN" node --input-type=module -e '
  process.stdout.write(JSON.stringify({
    leaseToken: process.env.LEASE_TOKEN,
    status: "completed",
    resultText: "Hello from the agent"
  }));
')
curl --fail --silent --show-error \
  -X POST "$BASE_URL/v2/runs/$LEASED_RUN_ID/complete" \
  -H "Authorization: Bearer $AGENT_TOKEN" -H 'Content-Type: application/json' \
  --data "$COMPLETE_JSON"
unset COMPLETE_JSON LEASE_TOKEN

# 收到 assistant 消息后保存 nextCursor，下次以 after=nextCursor 增量拉取。
curl --fail --silent --show-error \
  "$BASE_URL/v2/conversations/$CONVERSATION_ID/messages?after=$CURSOR&wait=25" \
  -H "Authorization: Bearer $CLIENT_TOKEN"

```

`complete` 仅接受 `completed` 或 `failed`。`completed` 且有非空 `resultText` 时，在**同一个数据库事务**中更新运行、追加 assistant 消息并推进会话 `seq`；客户端仍从 messages 长轮询取得回复。失败不会追加 assistant 回复。租约无效或过期返回 409，运行不存在返回 404。

`leaseMs` 默认为 30000，必须是 1–86400000 的整数（最长 24 小时）；同一时刻全局最多一条 running 租约。过期租约会重新排队。`after` 默认为 0，必须是非负安全整数；`wait` 默认为 0，范围 0–25 秒，允许小数。有消息时立即返回，超时则返回空数组且 `nextCursor` 保持请求游标。

其他常用请求如下。可在同一终端继续执行，最后清理 token 变量：

```bash
curl --fail --silent --show-error "$BASE_URL/v2/me" \
  -H "Authorization: Bearer $CLIENT_TOKEN"
curl --fail --silent --show-error "$BASE_URL/v2/conversations" \
  -H "Authorization: Bearer $CLIENT_TOKEN"
curl --fail --silent --show-error "$BASE_URL/v2/runs/$RUN_ID" \
  -H "Authorization: Bearer $CLIENT_TOKEN"
curl --fail --silent --show-error -X POST "$BASE_URL/v2/runs/$RUN_ID/cancel" \
  -H "Authorization: Bearer $CLIENT_TOKEN"

unset CLIENT_TOKEN AGENT_TOKEN V2_ADMIN_SECRET
```

取消 queued/running 运行将其变为 `canceled`；已终态的运行原样返回。lease/complete 要求 `agent` 角色，其他 v2 数据端点接受有效的设备 bearer token。错误统一为 `{"error":{"code":"...","message":"..."}}`：400 参数或 JSON、401 鉴权、403 角色、404 不存在、409 租约冲突、413 请求体过大、500 服务错误。请求体上限 1 MiB；不要向请求体或查询串加入契约外字段。

## Smoke 与 CI

在仓库根目录，用 Bash 对已运行的、可写且没有并发 Agent 的测试实例执行：

```bash
export BASE_URL=http://127.0.0.1:8787
read -r -s -p 'V2_ADMIN_SECRET: ' V2_ADMIN_SECRET; printf '\n'
export V2_ADMIN_SECRET
bash apps/cloud/scripts/smoke.sh
unset V2_ADMIN_SECRET
```

脚本不会启动或停止服务，会新增一个设备、一个会话和一条用户消息，验证 health、配对、创建会话、消息幂等、实际等待的长轮询超时与运行取消。测试数据保留在目标数据库中。输出只有步骤结果，不输出管理密钥、设备 token 或租约 token。CI 在 cloud/contracts 相关路径变更时使用 Node 24 直接运行 cloud 测试，并检查 Bash 语法；不启动替代服务、不安装运行时依赖。

## 当前范围与 v1 迁移

当前仅支持单 owner（固定 `default`），所有已配对设备共享该 owner 的数据；`ownerId` 是未来租户化的预留字段，尚未提供多用户隔离。设备 token 只存 SHA-256 摘要，配对响应仅签发一次；丢失后重新配对。

HTTP 服务只管理会话、消息与租约队列，**API 进程不调用模型**。第一阶段新增的独立 [聊天 worker](WORKER.md) 作为 v2 agent 领取运行，调用显式配置的 OpenAI 兼容 Chat Completions 接口并回写 complete；不会随 API 自动启动。没有已配置且运行中的 worker/agent 时，消息对应运行会停留在 queued。没有推送、附件、审批、设备撤销接口或租约续期接口，消息仍通过长轮询刷新，iOS 另行查询已知运行状态。冻结 v2 HTTP 字段、路由和数据表不因 worker 扩展而改变。

现有 v1 网关及其记忆、计划、任务功能继续运行，v2 不会代理或自动迁移这些接口、旧会话或旧凭据。迁移期间分别配置 v1/v2 地址与凭据，新会话接入 v2，逐项迁移并验证消费者后再停用对应 v1 能力。不要在未完成迁移前移除 v1 网关。
