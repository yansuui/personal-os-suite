# iPhone 客户端内部契约 v0（并行开发用）

> 本文件是三个子智能体并行开发时的唯一接口事实源。**改签名必须先改本文件**。
> 服务端事实源在旧仓库 `C:\Users\QUIZ\Desktop\project\dsh-plugins\dsh-personal-os`
> （`src/remote/server.ts` 路由、`src/remote/protocol.ts` wire 类型、`src/remote/pwa/client-js.ts` 行为）。
> 本轮只做 iOS 端，不修改旧仓库任何文件。

---

## 1. 工程与目标

| 项 | 值 |
|---|---|
| 根目录 | `C:\Users\QUIZ\Desktop\project\personal-os\apps\iphone` |
| 工程生成 | XcodeGen（`project.yml`，不提交 `.xcodeproj`） |
| Targets | `POSCore`（framework）、`POSFeatures`（framework，依赖 POSCore）、`POSApp`（app，依赖两者）、`POSCoreTests`（单元测试，依赖 POSCore） |
| 最低系统 | iOS 17.0 |
| Swift | 5.10 语言模式（Xcode 16 默认工具链） |
| 第三方依赖 | 无。只用 Foundation / SwiftUI / Security / os |
| Bundle ID | `$(BUNDLE_ID)`，xcconfig 默认 `com.personalos.ios` |
| 版本 | `0.1.0`（build 1） |
| 并发 | Swift Concurrency；核心层 `Sendable`；UI 层 `@MainActor` |

目标平台设置：`SUPPORTED_PLATFORMS=iphoneos iphonesimulator`、`TARGETED_DEVICE_FAMILY=1`、
`SWIFT_VERSION=5.0`（对应 5.x 语言模式）、`IPHONEOS_DEPLOYMENT_TARGET=17.0`。

---

## 2. 文件所有权（并行开发，严禁越界）

| 角色 | 只允许写 |
|---|---|
| A 工程/交付 | `project.yml`、`Config/*.xcconfig`、`Sources/POSApp/**`、`.github/workflows/**`、`scripts/**`、`README.md`、`.gitignore`、`Info.plist` 相关配置 |
| B 核心层 | `Sources/POSCore/**`、`Tests/POSCoreTests/**` |
| C 界面层 | `Sources/POSFeatures/**` |

任何人不得修改其他角色的文件，也不得改 `CONTRACT.md`。

---

## 3. POSCore 公开 API（B 实现 / A、C 只消费）

签名必须逐字一致（属性名、标签、可选性）。B 可以增加 internal 实现细节，但不得改下列公开面。

```swift
// MARK: 配置与错误

public struct ServerConfig: Sendable, Equatable {
    public var baseURL: URL
    public init(baseURL: URL)
}

public enum POSAPIError: Error, Sendable, Equatable {
    case transport(String)        // 网络不可达 / 超时
    case unauthorized             // 401/403
    case conflict(String)         // 409：版本冲突，调用方必须刷新而不是覆盖
    case server(status: Int, code: String, message: String)
    case decoding(String)
}

// MARK: 身份

public struct DeviceInfo: Sendable, Codable, Equatable {
    public let id: String
    public let name: String
    public let role: String        // "client" | "worker"
    public let kind: String?       // "desktop" | "cloud-agent" | nil
    public let createdAt: String
}

public struct AuthSession: Sendable, Codable, Equatable {
    public let token: String
    public let device: DeviceInfo
}

public struct PairRequest: Sendable, Codable, Equatable {
    public var name: String
    public var role: String        // 手机固定 "client"
    public var kind: String?       // 手机固定 nil
    public var capabilities: [String]
}

// MARK: 会话与时间线

public struct ChatMessage: Sendable, Codable, Equatable, Identifiable {
    public let id: String
    public let seq: Int
    public let role: String        // "user" | "assistant" | "system"
    public let text: String
    public let createdAt: String
}

public struct TimelinePage: Sendable, Codable, Equatable {
    public let events: [ChatMessage]
    public let nextCursor: Int?
}

public struct SendMessageRequest: Sendable, Codable, Equatable {
    public var clientRequestID: String   // 幂等键，重试必须复用
    public var text: String
    public var conversationID: String?
}

public struct SendMessageAck: Sendable, Codable, Equatable {
    public let messageID: String
    public let runID: String?
}

// MARK: 任务 / 审批 / 验收

public struct TaskSummary: Sendable, Codable, Equatable, Identifiable {
    public let id: String
    public let title: String
    public let status: String      // queued|running|waiting-device|waiting-approval|completed|failed|canceled|unknown
    public let updatedAt: String
    public let requiresApproval: Bool
    public let approvedAt: String?
    public let verdict: String?    // "accepted" | "rejected" | nil
    public let outputTail: String?
    public let errorText: String?
}

public struct TaskList: Sendable, Codable, Equatable {
    public let tasks: [TaskSummary]
    public let counts: [String: Int]
}

// MARK: 只读上下文

public struct PlanItem: Sendable, Codable, Equatable, Identifiable {
    public let id: String
    public let planDate: String
    public let title: String
    public let owner: String       // "me" | "ai"
    public let startTime: String?
    public let endTime: String?
    public let minutes: Int?
    public let status: String      // "todo" | "done" | "skipped"
    public let progress: Int
}

public struct MemoryHit: Sendable, Codable, Equatable, Identifiable {
    public let id: String
    public let content: String
    public let kind: String
    public let tags: [String]
    public let scope: String
    public let importance: Int
    public let updatedAt: String
}

public struct ContextSnapshot: Sendable, Codable, Equatable {
    public let available: Bool
    public let plan: [PlanItem]
    public let memory: [MemoryHit]
    public let asOf: String?
}

// MARK: 在线状态

public struct Presence: Sendable, Codable, Equatable {
    public let desktopOnline: Bool
    public let cloudAgentOnline: Bool
    public let queuedChat: Int
}

// MARK: 网络接口

public protocol POSAPI: Sendable {
    func pair(secret: String, _ request: PairRequest) async throws -> AuthSession
    func me(_ session: AuthSession) async throws -> DeviceInfo
    func timeline(_ session: AuthSession, after: Int, waitSeconds: Int) async throws -> TimelinePage
    func sendMessage(_ session: AuthSession, _ request: SendMessageRequest) async throws -> SendMessageAck
    func tasks(_ session: AuthSession) async throws -> TaskList
    func approve(_ session: AuthSession, taskID: String, approved: Bool, note: String?) async throws
    func submitVerdict(_ session: AuthSession, taskID: String, verdict: String, note: String?) async throws
    func context(_ session: AuthSession) async throws -> ContextSnapshot
    func presence(_ session: AuthSession) async throws -> Presence
}

// MARK: 凭据与缓存

public protocol CredentialStore: Sendable {
    func load() throws -> AuthSession?
    func save(_ session: AuthSession) throws
    func clear() throws
}

public struct KeychainCredentialStore: CredentialStore {
    public init(service: String = "com.personalos.ios.session")
    // load/save/clear
}

public protocol SnapshotStore: Sendable {
    func loadSnapshot() throws -> CachedSnapshot?
    func saveSnapshot(_ snapshot: CachedSnapshot) throws
}

/// 默认实现：Application Support 下的 JSON 文件，按「服务器地址 + 设备 id」分目录。
public struct FileSnapshotStore: SnapshotStore {
    public init(directory: URL? = nil)
}

public struct CachedSnapshot: Sendable, Codable, Equatable {
    public let savedAt: String
    public let timeline: [ChatMessage]
    public let cursor: Int
    public let tasks: [TaskSummary]
    public let context: ContextSnapshot?
}

// MARK: 同步

public enum SyncEvent: Sendable {
    case connected
    case disconnected(POSAPIError)
    case messages([ChatMessage])
    case cursor(Int)
}

public actor SyncEngine {
    public init(api: POSAPI, session: AuthSession, store: SnapshotStore, waitSeconds: Int)  // waitSeconds 默认 20
    public func start() -> AsyncStream<SyncEvent>
    public func stop()
    public func resendPending() async
}
```

行为要求（B 必须实现，C 依赖）：
1. **分档超时**：普通请求 15s；长轮询按 `waitSeconds + 10` 秒计算（至少 30s）。
2. **幂等**：`SendMessageRequest.clientRequestID` 由调用方生成；重试复用同一个值。
3. **409 不覆盖**：`POSAPIError.conflict` 一律向上抛，由 UI 刷新；不得自动合并。
4. **游标**：`timeline(after:)` 用上次 `nextCursor`；拿不到就保留旧游标，不重置为 0。
5. **断线重连**：指数退避 1s→30s，封顶 30s；`stop()` 后不再发起请求。
6. **Keychain**：`kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`；错误不得带 token 正文。

---

## 4. POSFeatures 公开 API（C 实现 / A 只消费）

```swift
@MainActor
public final class AppModel: ObservableObject {
    public init(serverURL: URL,
                api: POSAPI? = nil,
                apiFactory: ((URL) -> (any POSAPI))? = nil,
                credentials: CredentialStore = KeychainCredentialStore(),
                store: SnapshotStore? = nil)

    @Published public private(set) var phase: AppPhase      // .signedOut / .pairing / .ready / .failed(String)
    @Published public private(set) var messages: [ChatMessage]
    @Published public private(set) var tasks: [TaskSummary]
    @Published public private(set) var context: ContextSnapshot?
    @Published public private(set) var presence: Presence?
    @Published public private(set) var lastSyncedAt: Date?

    public func bootstrap() async
    public func pair(serverURL: URL, secret: String, deviceName: String) async
    public func signOut()
    public func refresh() async
    public func send(_ text: String) async
    public func approve(taskID: String) async
    public func reject(taskID: String, note: String?) async
    public func accept(taskID: String) async
    public func requestRework(taskID: String, note: String?) async
}

public struct RootView: View {
    public init(model: AppModel)
    public var body: some View
}

public enum AppPhase: Equatable, Sendable {
    case signedOut
    case pairing
    case ready
    case failed(String)
}
```

`RootView` 内含底部五个 Tab：`TodayView`、`AssistantView`、`TasksView`、`MemoryView`、`MeView`。
`AppModel` 内部用 `SyncEngine` + `SnapshotStore`，不得直接 new 网络栈。

---

## 5. POSApp（A 实现）

```swift
@main
struct POSApp: App {
    @StateObject private var model: AppModel
    init() {
        let url = AppConfig.serverURL
        let api = URLSessionPOSAPI(config: ServerConfig(baseURL: url))
        _model = StateObject(wrappedValue: AppModel(serverURL: url, api: api))
    }
    var body: some Scene { WindowGroup { RootView(model: model) } }
}
```

`AppConfig.serverURL` 从 `Info.plist` 的 `POSServerURL`（xcconfig 注入）读取；缺省
`http://127.0.0.1:3080`（Debug）。ATS：Debug 允许明文到 localhost，Release 不允许。

---

## 6. 服务端契约（只读事实源）

端点（均需 `Authorization: Bearer <token>`，除 `/v1/pair` 与 `/v1/health`）：

| 方法 | 路径 | 用途 |
|---|---|---|
| POST | `/v1/pair` | 配对：需请求头 `x-pair-secret: <配对密钥>`，返回 `{ device, token }` |
| GET | `/v1/me` | 当前设备 |
| GET | `/v1/health` | 健康检查（无鉴权） |
| GET | `/v1/timeline/events?after=<int>&wait=<int>` | 长轮询事件流 |
| POST | `/v1/chat/messages` | 发消息（带幂等键） |
| GET | `/v1/tasks` | 任务列表 |
| GET | `/v1/tasks/:id` | 单任务 |
| POST | `/v1/tasks/:id/approve` | 审批 |
| POST | `/v1/tasks/:id/verdict` | 验收 |
| GET | `/v1/context` | 计划/记忆快照 |
| GET | `/v1/presence` | 在线状态 |

B 必须对照 `src/remote/server.ts`（各 handler 的字段读取）与 `src/remote/protocol.ts` 修正
Codable 字段名，**以服务端实际读取的字段为准**，与本文第 3 节类型名保持一一对应（可用
`CodingKeys` 适配）。发现契约冲突时，在实现处加 `// CONTRACT-DEVIATION:` 注释并在 PR 说明中列出。

---

## 7. 验收（本轮）

CI（`.github/workflows/ios-ipa.yml`）必须能：
1. `brew install xcodegen` → `xcodegen generate`；
2. 模拟器上跑 `POSCoreTests`（至少覆盖：分档超时、幂等键复用、409 冲突、游标不重置、Keychain 读写 mock）；
3. 无签名构建 Release：`CODE_SIGNING_ALLOWED=NO`，打包 `Payload/POSApp.app` → `POSApp-unsigned.ipa`；
4. 上传 artifact。

本机（Windows）无法编译 Swift，因此**本轮代码未经编译验收**，以 CI 结果为准。

---

## 8. 实现期间登记的偏差（v0.1）

| # | 偏差 | 原因 | 后续 |
|---|---|---|---|
| D-1 | `approve(approved: false)` 改打 `POST /v1/tasks/:id/cancel` | v1 的 `/approve` 无条件批准、没有拒绝分支；照打会让「拒绝」静默变成「批准」 | 云端 `ApprovalService` 落地后补 reject 端点并改回 |
| D-2 | `POSApp` 显式注入 `URLSessionPOSAPI` | 契约只声明协议，无法在 Features 层实例化实现（避免反向依赖） | 保持不变，装配点固定在 App 层 |
| D-3 | `FileSnapshotStore(directory:)` 由调用方传入身份目录 | 契约初始化器只有目录参数，拿不到 baseURL/设备 id | `AppModel` 用 FNV-1a 派生 `serverURL+deviceId` 目录 |
| D-4 | 为 `PairRequest`/`ChatMessage`/`SendMessageRequest`/`CachedSnapshot` 补 `public init` | Swift 隐式 memberwise init 是 internal，跨模块无法构造 | 保留（纯加法） |
| D-5 | `TaskList.counts` 缺失时退化为 `[:]`；`ContextSnapshot` 从 `snapshots[]` 摊平 | 服务端 `/v1/tasks` 只返回 `{tasks}`，`/v1/context` 返回快照数组 | 云端改契约后收紧 |
| D-6 | `AppPhase` 定义在 POSFeatures | 契约 §4 引用了它但 §3 未定义 | 若迁入 POSCore，删除 Features 内定义即可 |
| D-7 | ATS 放开 `NSAllowsArbitraryLoads` | 真机需连局域网 http 网关，XcodeGen 单份 Info.plist 无法按配置区分 | 发布前拆 Debug/Release plist |
| D-8 | `AppModel` 增加 `apiFactory` 参数，并持久化已配对服务器地址 | 否则配对页填的地址不参与请求、重启回到默认地址 | 保持；契约 §4 已同步 |
