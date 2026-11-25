# iPhone v2 最小聊天契约

跨端协议事实源为 [`MINIMAL-V2-CONTRACT.md`](../../packages/contracts/MINIMAL-V2-CONTRACT.md)。本文描述 iPhone 内部装配和本地兼容行为，不扩展云端协议。

## 范围

本轮支持：v2 health、client 配对、me、创建/列出/选择会话、发送消息、增量长轮询读取 user/assistant/system 消息。

任务、审批、验收、计划、记忆、presence、附件、推送和设备撤销均未接入。主界面仅“聊天 / 我的”；“我的”明确显示能力边界。旧功能没有网络协议方法，也不会伪造成功。旧视图只保留编译兼容，不提供入口。

## 工程与装配

- 工程定义仍为 `project.yml`；POSCore / POSFeatures / POSApp / POSCoreTests 四个 target。
- iOS 17+，Swift 5.x 语言模式，无第三方运行时依赖。
- POSApp 注入 URLSessionPOSAPI 工厂；AppModel 按本次配对地址创建实现，保留原服务器地址 UserDefaults key。
- Keychain service/account、设备可访问性和快照身份目录规则保持原样；不在日志中输出 token 或配对密钥。

## POSCore 网络接口

```swift
public protocol POSAPI: Sendable {
    func health() async throws -> HealthResponse
    func pair(secret: String, _ request: PairRequest) async throws -> AuthSession
    func me(_ session: AuthSession) async throws -> DeviceInfo
    func createConversation(_ session: AuthSession, title: String?) async throws -> Conversation
    func conversations(_ session: AuthSession) async throws -> [Conversation]
    func messages(_ session: AuthSession, conversationID: String, after: Int, waitSeconds: Int) async throws -> MessagePage
    func sendMessage(_ session: AuthSession, conversationID: String, _ request: SendMessageRequest) async throws -> SendMessageAck
}
```

| 方法 | 路径 | wire shape |
|---|---|---|
| GET | `/v2/health` | `{ok,service,protocolVersion}`，无凭据 |
| POST | `/v2/pair` | body `{name,role:"client"}`，仅 `x-pair-secret`；返回 `{device,token}` |
| GET | `/v2/me` | `{device}` |
| POST | `/v2/conversations` | `{title?}` → `{conversation}` |
| GET | `/v2/conversations` | `{conversations}` |
| POST | `/v2/conversations/:conversationId/messages` | `{clientRequestId,text}` → `{message,run,created}`，201/200 均可 |
| GET | `/v2/conversations/:conversationId/messages?after=&wait=` | `{messages,nextCursor}`，游标为非可选整数 |

除 health/pair 外使用 Bearer。普通请求超时 15 秒；长轮询 wait 限定 0...25 秒，HTTP 超时 `max(30, wait + 10)`。会话 ID 按 `[A-Za-z0-9_-]+` 验证，不能拼出其它路径。

Message 使用 `id/conversationId/role/text/clientRequestId/seq/createdAt`。Swift 属性 `conversationID`、`clientRequestID` 通过 CodingKeys 映射。`conversationID` 只为读取升级前的本地快照允许 nil，v2 HTTP 响应会验证其属于请求会话。

Run 只读取 `id/status/conversationId/messageId`，不领取、不完成 agent 运行，也不保存 leaseToken。assistant 消息来自云端增量消息端点。

## 同步与幂等

- SyncEngine 每个实例绑定一个 conversationID，从 `conversationStates` 中恢复该会话的游标。不会沿用旧全局时间线的游标。
- 成功响应后才报告 connected；消息按 seq 合并后推进 nextCursor。空页保持请求 cursor。断线按 1→2→4→…→30 秒退避；stop 取消在途请求并结束事件流。
- AppModel 在选会话时保存当前会话状态并切换同步实例。旧身份和旧同步代次的迟到结果不回写新状态。
- PendingMessage 在首次网络发送前原子写入快照。键由客户端生成一次；自动重试、手动重试和重启恢复始终复用原 `clientRequestId` 与正文。
- 只有传输错误或 5xx 自动重试一次；409 保留原待发数据并刷新，不能覆盖本地新数据。其它失败保留待发项供用户明确重试。
- ack 保存服务端 message/run 的事实；不能用 ack 的 seq 推进消息轮询游标，以免跳过尚未读取的 assistant 消息。

## 本地数据兼容

- AuthSession 仍为 `{token,device}`；Keychain service `com.personalos.ios.session`、account `session`、`kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` 不变。
- FileSnapshotStore 仍在“服务器 URL + device ID”稳定摘要目录写 `snapshot.json`，使用 `.atomic`。
- CachedSnapshot 新增 conversations、selectedConversationID、conversationStates、pendingMessages。缺失新字段按空值读取。
- 升级前 timeline/cursor/tasks/context 字段保留并回写，既有文件不删除、不迁走。旧全局时间线没有可靠的 v2 conversationId，因此不混入新会话，也不把旧任务/上下文展示成已接入的能力。
- 离线首屏从快照恢复 v2 选中会话、历史消息及待发项，再发起刷新。配对失败保留原会话；退出只清凭据，保留身份目录的缓存。

## 验证

Windows 可离线执行：

```powershell
# 工作目录 apps/iphone
node --check scripts/validate-minimal-v2.cjs
node scripts/validate-minimal-v2.cjs
```

静态检查核对冻结路由、字段、认证、轮询边界、持久幂等键、会话游标隔离、未接入 UI、Keychain/原子快照设置和 XCTest 夹具。它不能证明 Swift 可以编译或测试已运行。

POSCoreTests 的定向用例覆盖：health/pair/me、创建/列出会话、201/200 幂等重放与跨重启键复用、assistant 增量读取、空页游标、会话游标隔离、断线重连/stop、25 秒等待上限、409、旧快照兼容及凭据协议。

macOS/Xcode 环境可运行（本轮未执行）：

```sh
xcodegen generate
xcodebuild test -project POSApp.xcodeproj -scheme POSApp -destination 'platform=iOS Simulator,name=iPhone 16' -only-testing:POSCoreTests CODE_SIGNING_ALLOWED=NO
```

模拟器名称需以该机器可用设备为准。本机无 Swift/Xcode/XcodeGen，**Swift 编译和 XCTest 执行未验证**；未触发云构建、未生成或安装 IPA、未进行 iPhone 真机验证。
