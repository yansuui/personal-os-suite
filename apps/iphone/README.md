# POSApp（iOS 客户端）

Windows 上写代码 → GitHub Actions 出无签名 IPA → Sideloadly 装到 iPhone。
跨端协议事实源是 [`MINIMAL-V2-CONTRACT.md`](../../packages/contracts/MINIMAL-V2-CONTRACT.md)，iPhone 内部装配及缓存兼容见 [`CONTRACT.md`](CONTRACT.md)。

## 1. 先说结论与限制

- **本机（Windows）没有 Mac、没有 Swift 工具链**，不能本地 `xcodebuild`、不能跑 XcodeGen。
  因此：**Swift 编译与 XCTest 由 GitHub macOS CI 执行，每次交付以对应提交的构建记录为准**。
- 本地能做的：改 Swift / 改工程配置 / 改 workflow、按 `CONTRACT.md` 自检接口。
- 交付物是 **未签名 IPA**，安装时由 Sideloadly 用你自己的 Apple ID 重签。

## v2 最小聊天与本地验证

- 只调用 v2：health、client 配对、me、创建/列出会话、按会话发送与增量读取消息、查询/取消运行；assistant 回复从云端消息流读取。
- 发送回执中的运行按会话持久化，独立轮询排队/生成/完成/失败/取消状态；取消以服务器响应为准。切后台暂停轮询，回前台验证连接后恢复；终态停止查询。
- 服务器已接受正文但运行回执丢失时，保留原请求键；点击“恢复状态”可幂等重放取得原运行并继续查询或取消，不创建第二条消息。v2 没有运行列表接口，其他设备的未知运行不能仅凭消息记录恢复。
- 主界面仅“聊天 / 我的”，聊天页可创建/选择会话。任务、审批、验收、计划、记忆和 presence 未接入，“我的”页明确标注。
- 待发消息在请求前写入快照，自动重试、手动重试、重启后重试复用同一个 `clientRequestId`。会话独立保存游标，空页不归零，发送 ack 不跳过尚未读取的消息。
- 保留原 Keychain service/account、快照文件和身份目录。旧全局时间线与任务/上下文只保留在快照中，不混入 v2 会话；v2 离线首屏恢复选中会话的消息与待发项。

在 `apps/iphone` 目录离线执行：

```powershell
node --check scripts/validate-minimal-v2.cjs
node scripts/validate-minimal-v2.cjs
```

当前本地静态结果：12 组检查通过；扫描 34 个 Swift 源文件，发现 13 个 XCTest 源文件、65 个 test 方法声明，解析 25 个字面 JSON 夹具。**这些是源码静态检查；实际 Swift 编译与 XCTest 结果以当次 macOS CI 日志为准。**

## 2. 目录与职责

| 路径 | 职责 | 归属 |
|---|---|---|
| `CONTRACT.md` | iPhone 内部 v2 接口与缓存兼容说明 | 与跨端冻结契约一致 |
| `project.yml` | XcodeGen 工程定义（不提交 `.xcodeproj`） | A |
| `Config/{Debug,Staging,Release}.xcconfig` | `BUNDLE_ID` / `POS_SERVER_URL` | A |
| `Sources/POSApp/` | `POSApp.swift`（@main）、`AppConfig.swift` | A |
| `.github/workflows/ios-ipa.yml` | CI：测试 + 无签名 Release + 打包 IPA | A |
| `Sources/POSCore/` | 核心层（网络/凭据/同步） | B |
| `Tests/POSCoreTests/` | 单元测试 | B |
| `Sources/POSFeatures/` | SwiftUI 界面层（`AppModel` / `RootView`） | C |

## 3. 工程配置要点（`project.yml`）

- 5 个 target：`POSCore`（framework）、`POSFeatures`（framework，链接 POSCore）、
  `POSApp`（app，嵌入两个 framework）、`POSCoreTests` 和 `POSFeaturesTests`（`bundle.unit-test`，无 TEST_HOST）。
- 3 个 configuration：`Debug: debug`、`Staging: release`、`Release: release`，
  通过 `configFiles` 分别绑定 `Config/*.xcconfig`。
- 平台：iOS 17.0、`TARGETED_DEVICE_FAMILY=1`（仅 iPhone）、`SWIFT_VERSION=5.0`、
  `SUPPORTED_PLATFORMS="iphoneos iphonesimulator"`。
- framework 用 `GENERATE_INFOPLIST_FILE=YES`；**app 的 Info.plist 由内联 `info:` 生成**
  （`Sources/POSApp/Info.plist`，已在 `.gitignore` 里），内容含 `CFBundleDisplayName`、
  `UILaunchScreen`、竖屏 `UISupportedInterfaceOrientations`、`POSServerURL=$(POS_SERVER_URL)`、
  以及 ATS 本地网络例外（`NSAllowsLocalNetworking` + `localhost` 例外域，
  `NSAllowsArbitraryLoads` 保持 `false`）。
- scheme `POSApp`：build 含 `POSApp`、`POSCoreTests`、`POSFeaturesTests`，test 同时运行两组测试（Debug）。

### 服务器地址怎么改

改 `POS_SERVER_URL`，**不要**直接写 `http://…`，因为 xcconfig 把 `//` 当行注释：

```
// 正确
POS_SERVER_URL = http:/$()/127.0.0.1:3080
POS_SERVER_URL = http:/$()/192.168.1.10:3080     // 真机连本机服务
POS_SERVER_URL = https:/$()/api.example.com      // 线上
```

构建时它被注入 Info.plist 的 `POSServerURL`；`AppConfig.serverURL` 读取它，
缺失或非法（不是 http/https、没有 host、或残留 `$(POS_SERVER_URL)` 占位符）
就回落到 `http://127.0.0.1:3080`。

## 4. 日常流程：改代码 → push → CI 出 IPA

1. 在本机（Windows）改 Swift 代码 / 工程配置。
2. 提交并推送到 GitHub（本机不跑 git 命令的话，用 GitHub Desktop 或你惯用工具）。
3. CI 自动跑 `.github/workflows/ios-ipa.yml`：
   - `brew install xcodegen`（已预装则跳过）→ `xcodegen generate` → `xcodebuild -list`；
   - 打印 `xcrun simctl list devices available`，按 `iPhone 16` → `iPhone 15` → … 选模拟器，
     跑 `xcodebuild test -project POSApp.xcodeproj -scheme POSApp -destination 'platform=iOS Simulator,name=…'`；
   - 无签名 Release 构建（`-sdk iphoneos`，`CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY=""`）；
   - `Payload/POSApp.app` → `POSApp-unsigned.ipa`，上传 artifact（保留 14 天）；
   - 失败时额外打印 `xcodebuild -version`、可用 SDK 列表、日志尾部。
4. 下载 IPA：网页 Actions → 目标 run → Artifacts → `POSApp-unsigned-ipa`；
   或 `gh run download -n POSApp-unsigned-ipa`。

手动触发（不 push 也能出包）：Actions 页面选 `ios-ipa` → `Run workflow`；
或 `gh workflow run ios-ipa.yml`。

> **workflow 位置**：已在 monorepo 根 `personal-os/.github/workflows/ios-ipa.yml`。
> 若你把 `apps/iphone` 单独做成一个仓库，把该文件放到仓库根 `.github/workflows/` 即可 ——
> 脚本会自动定位 `project.yml`（先在仓库根找，再退到 `apps/iphone/`）。

## 5. 装到 iPhone（Sideloadly，Windows）

1. 装 [iTunes / Apple 设备驱动](https://support.apple.com/downloads) 与 [Sideloadly](https://sideloadly.io/)。
2. iPhone 用 USB 连电脑，解锁并「信任此电脑」；iOS 16+ 还要在
   设置 → 隐私与安全性 → **开发者模式** 打开（会重启一次）。
3. 打开 Sideloadly，选择已连接的 iPhone，把 `POSApp-unsigned.ipa` 拖进去，
   按提示输入 Apple ID 与二次验证码（只在 Sideloadly 界面里输入，不要写进仓库、脚本或聊天记录）。
4. 点 Start，等它重签 + 安装；首次安装后在 iPhone
   设置 → 通用 → VPN 与设备管理 里信任你的开发者描述文件。
5. 更新版本：**同一个 Apple ID + 同一个 bundle id（`com.personalos.ios`）** 重新装，
   app 数据一般能保留；装前建议先备份关键数据。

### 7 天签名与 3 台设备限制

- 免费 Apple ID 签名 **7 天到期**，到期后 app 打不开，需要重新签一次
  （重下最新 IPA 再走一遍上面第 3–5 步，或让 Sideloadly 的自动刷新守护进程
  `Sideloadly Daemon` 在后台续签，但它要求电脑开机、联网、能连到手机）。
- 免费个人账号一年内最多绑定 **3 台 iOS 设备**（用满要等额度重置），
  别在多台机器上反复试装。
- 付费账号可延长到 1 年签名，但本项目目前按免费账号路线走。

## 6. 常见问题

| 现象 | 原因 / 处理 |
|---|---|
| CI 报找不到 `project.yml` | workflow 不在仓库根，或工程目录不是 `apps/iphone`（见第 4 节） |
| `xcodebuild: error: destination ... not found` | 选模拟器那步的日志里看实际可用名字；脚本已回退到 iPhone 15 及其它 iPhone |
| app 内 `POSServerURL` 显示成 `$(POS_SERVER_URL)` | `Config/*.xcconfig` 没被绑定，或配置名改动后没同步 `project.yml` 的 `configFiles` |
| 请求被 ATS 拦（真机连 http 局域网） | 真机连 `http://192.168.x.x` 属于本地网络，已在 ATS 例外内；若换成公网 http 会被拦，请改用 https |
| 编译错在 POSCore / POSFeatures | 那是 B / C 的代码，先看 `CONTRACT.md` 对不上再说，A 侧不改 |

## 7. 本轮验收状态

| 项 | 状态 |
|---|---|
| v2 静态契约检查 | `node scripts/validate-minimal-v2.cjs`：12 组通过；34 个 Swift 源文件、13 个 XCTest 源文件、65 个 test 方法声明、25 个字面 JSON 夹具 |
| 验证脚本语法 | `node --check scripts/validate-minimal-v2.cjs`：通过 |
| Swift 编译 / 两组 XCTest | 由对应提交的 `ios-ipa` macOS CI 实际执行；Windows 静态检查不能替代 |
| IPA / iPhone 真机 | 对应提交、构建记录、IPA 和验包报告见当次交付记录；重签安装与真机运行另行验收 |
