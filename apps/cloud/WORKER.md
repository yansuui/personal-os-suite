# 云端聊天 Worker

独立 worker 是与 v2 HTTP API 分开的进程；云端 API server 自身不连接或调用模型。Worker 通过冻结的 `/v2` HTTP agent 接口领取任务，调用显式配置的 OpenAI 兼容 Chat Completions 或 Responses 模型端点，再提交完成结果。

## 显式配置

运行前必须明确提供以下环境变量；缺少 API 地址、agent 凭据、模型地址或模型名时启动失败，不会使用内置的生产凭据或默认模型。

| 变量 | 必填 | 默认/说明 |
|---|---:|---|
| `POS_API_BASE_URL` | 是 | Cloud v2 API base URL。只允许 HTTPS；HTTP 仅限 localhost、127.0.0.1 或 ::1。 |
| `POS_AGENT_TOKEN` 或 `POS_AGENT_TOKEN_FILE` | 是 | 已配对且 role 为 `agent` 的设备凭据。不能与模型 API key 混用。 |
| `POS_MODEL_ENDPOINT` | 是 | 完整 chat/completions URL；只允许 HTTPS 或 loopback HTTP。 |
| `POS_MODEL` | 是 | 上游模型名。 |
| `POS_MODEL_API` | 否 | `chat-completions`（默认）或 `responses`；必须与完整模型 URL 匹配。Responses 使用 `input`、`max_output_tokens`、`store:false` 和按会话稳定的 `prompt_cache_key`，只提交 `status:completed` 中的 assistant `output_text`；不将 reasoning、工具调用或 incomplete 响应作为回复。 |
| `POS_MODEL_API_KEY` 或 `POS_MODEL_API_KEY_FILE` | 否 | 只发给模型端点的 Bearer 凭据，绝不会用作 agent token。 |
| `POS_WORKER_LEASE_MS` | 否 | 120000 ms。 |
| `POS_WORKER_REQUEST_TIMEOUT_MS` | 否 | 10000 ms。 |
| `POS_WORKER_MODEL_TIMEOUT_MS` | 否 | 60000 ms。 |
| `POS_WORKER_CANCEL_POLL_MS` | 否 | 1000 ms。 |
| `POS_WORKER_POLL_MS` | 否 | 1000 ms。 |
| `POS_WORKER_CONTEXT_MESSAGES` | 否 | 60 条消息。 |
| `POS_WORKER_CONTEXT_CHARS` | 否 | 60000 字符；这是字符上限，不是 tokenizer 计算的 token 数。 |
| `POS_WORKER_OUTPUT_TOKENS` | 否 | 2048，按模型协议作为 `max_tokens` 或 `max_output_tokens` 传给模型；响应文本另有 200000 字符上限。 |

URL 不接受 userinfo、query 或 fragment。密钥可直接通过环境变量提供，也可用对应的 `_FILE` 变量从文件读取；同一凭据的两种来源不能同时设置。不要把密钥写入日志、代码库或命令历史。

租约需覆盖模型超时、上下文/轮询所用请求和完成请求的余量。配置校验保证 `modelTimeoutMs + 2 * requestTimeoutMs + 250 < leaseMs`。生成阶段在总租约结束前预留 `requestTimeoutMs + 250`；生成完成后，提交可使用预留的请求预算，仍受原租约起点计算的总截止（提前 250ms）、父级取消和单请求超时限制。每个 HTTP 请求均有超时；不自动续租。超时/取消/租约丢失后 worker 停止上游请求，不提交迟到结果。完成请求遇到 409 时视为已失效并丢弃结果，不重试生成。关闭进程会 abort 当前请求且不伪造完成状态，过期租约可由服务恢复。

## 启动与安全边界

由 `apps/cloud/package.json` 的 worker 脚本启动独立进程。生产环境必须由部署环境安全注入所有必需配置。进程启动时检查 `/v2/health` 的协议版本和 `/v2/me` 的 agent 角色；模型 HTTP redirect 被拒绝，模型响应体最多 1 MiB，Cloud API 响应体最多 8 MiB。上游错误正文、提示词、模型 API key 和 agent token不会写入 run 错误或日志；错误只保留安全类别。

Worker 仅通过 v2 HTTP API 访问云服务，不直接读写 SQLite 或其他 store。上下文按消息分页读取，严格截止被领取 run 的 `messageId`，后续消息不进入旧任务提示；消息数、字符数和输出均有限制。Worker 每次最多处理一个 run。

单元与端到端测试只使用 mock transport 或 loopback 本地服务，不会呼叫真实模型。
