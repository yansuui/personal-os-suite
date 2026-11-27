# P2-A 精确源码验证与 macOS 交接记录

日期：2026-11-27（本地会话时间）；开发与云端基线测试开始于 2026-11-26。本轮承接 [上一轮记录](P2-A-LOCAL-VERIFICATION-20261126.md)，只完成本地验证和原生构建交接，不代表 P2-A 已发布或真机已验收。

## 1. 接续事实与本轮范围

当前仓库为 `C:\Users\QUIZ\Desktop\project\personal-os`，分支 `main`，HEAD `27abb9baa55a28d47949d61380f8e5095d51fdb2`；P2-A 大量改动仍未提交。旧个人助手仓库已冻结，新功能不写回旧插件。

当前 [project.yml](../apps/iphone/project.yml#L41) 为 0.1.0 (4)，不是上一轮记录中的 build 3。这只是源码配置，尚无本轮原生 IPA。云端当前限定测试为 92 项，不能沿用旧记录的 83 项作为当前验证总数。

本轮新增文件：

- [ios_source.py](../apps/iphone/scripts/ios_source.py)：`pack` 固定当前工作树白名单输入并生成 ZIP/清单；`check` 校验精确字节；`macos` 在独立副本执行原生测试、Release 构建和 IPA 结构检查，记录 sourceHash 与各步骤回执。
- [test_ios_source.py](../apps/iphone/scripts/test_ios_source.py)：源码包一致性、失败边界和构建驱动的隔离单测。
- [P2-A-MACOS-VALIDATION.md](P2-A-MACOS-VALIDATION.md)：Windows 打包与受信任 Mac 上的执行入口。
- 本记录；另在上一轮记录末尾增加接续链接。

没有修改本轮既有云端/Swift 产品实现、工程版本、桌面插件或 DSH 本体；没有 commit、push、触发远程 CI、操作 profile、部署云端、启用目标问答 gate 或写入生产数据。

## 2. 实际验证

使用本机提供的运行时：

```powershell
$node = 'C:\Users\QUIZ\.dsh\dsh-runtimes\dsh-primary-runtime\dependencies\node\bin\node.exe'
$pnpm = 'C:\Users\QUIZ\.dsh\dsh-runtimes\dsh-primary-runtime\dependencies\pnpm\bin\pnpm.mjs'
$python = 'C:\Users\QUIZ\.dsh\dsh-runtimes\dsh-primary-runtime\dependencies\python\python.exe'
```

所有命令执行目录为新仓库根。

| 验证 | 实际命令 | 结果与边界 |
| --- | --- | --- |
| 云端类型检查 | `& $node $pnpm --dir apps/cloud typecheck` | exit 0，`tsc --noEmit` |
| 云端限定 7 文件 | `& $node $pnpm --dir apps/cloud test` | 92 pass / 0 fail / 0 skip；隔离 SQLite、loopback HTTP 与模型替身 |
| iPhone 静态契约 | `& $node apps/iphone/scripts/validate-minimal-v2.cjs` | 13 组通过；39 Swift 源文件、15 XCTest 源文件、104 测试方法声明、34 个 JSON 夹具；不是 Swift 编译或 XCTest 执行 |
| 新验证入口单测 | `& $python -B apps/iphone/scripts/test_ios_source.py -v` | 13 项：12 pass / 1 skip / 0 fail；包括替身原生工具驱动测试，不是原生构建 |
| 真实源码 ZIP | `& $python -B apps/iphone/scripts/ios_source.py pack --output '..\dsh-plugins\artifacts\personal-os-p2a-20261127\ios-source.zip'` | 75 个输入文件 + 1 个清单，ZIP CRC 校验通过 |
| 解压后入口 | 对真实 ZIP 在独占临时目录解压，运行包内 `ios_source.py check` | `SOURCE_VERIFIED_ONLY`；逐一与当前工作树比较 75 项 SHA-256 均一致；临时目录测试后自动清理 |
| 平台失败守卫 | 在 Windows 对真实解压包调用 `macos` | 按预期 exit 1，明确要求 macOS；未创建原生输出目录 |

云端 92 项分布：api 19、store 27、goals-tasks 8、integration 3、contract-e2e 1、worker 13、worker-e2e 21。没有运行桌面 E2E 或仓库全量测试。云端与 Swift 产品源码在基线通过后未由本轮修改。

唯一 skip 为真实文件系统符号链接测试：本机创建符号链接返回 Windows 1314 权限错误。目录解析越界守卫另有替身定向测试通过；不能把它写成真实 Windows junction 或 macOS 文件系统验证通过。

新增入口的三项边界回归均先确认失败再修复：非对象清单原先抛 AttributeError；解析后越出源码根的目录原先未拒绝；失败回执原先缺少原因。最终分别返回明确错误、拒绝目录越界，并在失败回执中保存 `error`。相关失败用例为：

- `test_check_rejects_non_object_manifests_cleanly`
- `test_safe_path_rejects_resolved_directory_escape`
- `test_failed_native_tests_stop_before_release_and_leave_failed_receipt`

## 3. 本轮真实产物

源码 ZIP：`C:\Users\QUIZ\Desktop\project\dsh-plugins\artifacts\personal-os-p2a-20261127\ios-source.zip`。

- 输入文件数：75；ZIP 条目数：76。
- `sourceHash`：`4f23af794a2bc574bb2a5d214806c1aea5d7246ad640982e91bcc51dc5a43708`。
- ZIP SHA-256：`df98f3044cd34183caa0a6e5dbb33a14e1c49b376d4eda18e0d98f303264bddb`。
- 包内清单另导出到同目录 `IOS-SOURCE.json`，内容与 ZIP 内清单相同。
- 解压验证确认没有 cloud/dsh-plugin 目录、SQLite、`.env`、设备 token 文件或旧 IPA；白名单之外的运行数据未入包。

哈希用于匹配本次精确输入，不是签名或可信来源认证。后续只要修改白名单中的任一源码、配置、测试或说明，就必须生成新的源码包；不能继续引用本次哈希代表新工作树。

## 4. 未验收项与下一动作

本机没有 Xcode。此次未执行真实 Swift 类型检查、XCTest、模拟器、iPhoneOS Release、真实 provider 目标问答、设备安装或 P2-A 真机验收；没有生成本轮可安装的 IPA。

下一动作是将上述 ZIP 交给已授权且可用的受信任 Mac，按 [macOS 验证入口](P2-A-MACOS-VALIDATION.md#L20) 执行，取回相同 sourceHash 的原生日志、`Tests.xcresult`、`validation-result.json` 和通过结构检查的 IPA。原生成功前不能标记本批 iPhone 改动已验收，也不能据此开启生产能力。

后续生产兼容发布顺序继续遵循 [冻结契约](../packages/contracts/PHASE-2-GOALS-TASKS.md#L40)，真实手机场景继续遵循 [P2-A 验收清单](PHASE-2-GOALS-TASKS-PLAN.md#L180)。本轮没有扩展到 P2-B。

## 5. 独立复核

独立审查先复核既有 P2-A Swift/网络/草稿/固定依据路径，未发现本轮可确认的产品缺陷；再对新增的两个脚本与执行说明做稳定版限定审查，未发现可证实的严重、中等或轻微缺陷，并独立重跑脚本单测得到 12 pass / 1 skip / 0 fail。审查没有修改源码、联网或运行原生构建，其结论不替代本记录明确未执行的 macOS 验证。
