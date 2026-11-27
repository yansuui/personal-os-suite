# Personal OS P2-A 本地验证与后续验收记录

日期：2026-11-26，Asia/Shanghai。接续会话：`session-b0a5f198-7686-4608-ac19-f265359340be`。

本轮已修复原会话最后到达的云端审查问题，并补充修复 iPhone 连续异步刷新中的身份隔离缺口。云端本地限定回归 **83/83 通过**，TypeScript 类型检查通过。iPhone 仅完成本地静态验证；Swift 编译、XCTest、IPA、生产和真机验收仍未完成。此记录不表示 P2-A 整体已验收或已发布。

## 1. 源码与范围

- 工作目录：`C:\Users\QUIZ\Desktop\project\personal-os`。
- 分支：`main`；基础提交：`27abb9baa55a28d47949d61380f8e5095d51fdb2`。本轮变更尚未提交、推送。
- iPhone 工程当前配置为 0.1.0 (3)，见[工程配置](../apps/iphone/project.yml#L41)。这不是已构建产物的版本证明。
- 原工作区已有云端、iPhone、桌面及说明等改动。本轮源码写入仅涉及下表五个文件；另新增本记录。没有修改桌面实现、DSH profile、生产配置或用户数据。

| 文件 | 本轮变更 |
| --- | --- |
| [store.ts](../apps/cloud/src/store.ts#L607) | 保存非 blocked 状态备注，同时保留 blocked 历史备注的原有 trim 语义；按最终保留任务重算快照裁切元数据 |
| [goals-tasks.test.ts](../apps/cloud/test/goals-tasks.test.ts#L23) | 状态备注、受阻原因、16,000 字符快照裁切、30 项任务/每项 3 条进展限额及非法开关启动测试 |
| [store.test.ts](../apps/cloud/test/store.test.ts#L464) | 旧 runs 表升级、普通记录保留及目标 marker 回填后的旧 worker 隔离 |
| [AppModel.swift](../apps/iphone/Sources/POSFeatures/AppModel.swift#L666) | rebase、保存成功后刷新、冲突恢复的每个连续 await 之间检查身份 generation |
| [AppModelGoalTests.swift](../apps/iphone/Tests/POSFeaturesTests/AppModelGoalTests.swift#L145) | 三项挂起旧读取、换身份、释放旧读取的定向回归源码 |

## 2. 问题与修复

### 2.1 状态备注丢失及受阻原因空白边界

原实现只把 blocked 的 note 写入状态进展，其他状态提供的 note 被静默丢弃。现在非 blocked 状态保留其 note；完成结果仍单独存为 result 记录。blocked 状态继续把去除首尾空白后的 blockedReason 写入状态历史，避免大量前导空白占满快照裁切上限后，真正原因消失。

失败测试已确认后再修复：`set_status persists supplied non-blocked notes separately from result notes`；复审补充的 `blocked status history preserves trimmed reason in the fixed snapshot` 也真实得到 1 fail，再修复得到 1 pass。

### 2.2 快照遗漏报告与最终任务不一致

原快照在文字裁切时收集字段路径，随后因总大小超限移除任务，却仍报告已移除任务的文字字段。现在每次生成上下文时，只保留目标本身及最终 includedTasks 对应的 truncatedFields；没有剩余裁切字段时去掉 text_truncated。任务和进展遗漏数仍按最终纳入明细计算。

两项失败回归在修复前确认失败，修复后通过：

- `goal context size omissions describe only final included task truncations`
- `goal context reports no text truncation when only clipped tasks are size-omitted`

### 2.3 iPhone 跨身份异步续体

旧身份的任务草稿恢复或保存后，第一步目标读取可以正确丢弃迟到响应，但续体会继续调用任务读取，并重新捕获新身份的 API/session。新服务器可能收到旧任务 ID，404 又污染新身份的 goalsOnline/goalsError。

现在三条路径在每个 await 返回后、下一次读取之前核对原 generation；身份改变立即退出。新增源码测试：

- `testRebaseStopsAfterOldGoalReadWhenIdentityChangesBeforeTaskRefresh`
- `testConflictRecoveryStopsAfterOldGoalReadWhenIdentityChangesBeforeTaskRefresh`
- `testSuccessfulSubmitStopsAfterOldGoalReadWhenIdentityChangesBeforeTaskRefresh`

测试使用 continuation 挂起旧目标读取，重新配对后恢复；断言新 API 没收到旧任务请求，在线/错误状态及草稿保持新身份状态。**这些 XCTest 尚未在 macOS 执行，不能标为通过。**

## 3. 实际运行的云端验证

执行目录为仓库根，使用本机提供的 Node 与 pnpm：

```powershell
$node = 'C:\Users\QUIZ\.dsh\dsh-runtimes\dsh-primary-runtime\dependencies\node\bin\node.exe'
$pnpm = 'C:\Users\QUIZ\.dsh\dsh-runtimes\dsh-primary-runtime\dependencies\pnpm\bin\pnpm.mjs'
& $node $pnpm --dir apps/cloud typecheck
& $node $pnpm --dir apps/cloud test
```

结果：两命令 exit 0。类型检查执行 `tsc --noEmit`。测试 **83 pass、0 fail、0 skip、0 cancelled**。

| 限定测试文件 | 通过数 |
| --- | ---: |
| [api.test.ts](../apps/cloud/test/api.test.ts) | 19 |
| [store.test.ts](../apps/cloud/test/store.test.ts) | 27 |
| [goals-tasks.test.ts](../apps/cloud/test/goals-tasks.test.ts) | 8 |
| [integration.test.ts](../apps/cloud/test/integration.test.ts) | 3 |
| [contract-e2e.test.ts](../apps/cloud/test/contract-e2e.test.ts) | 1 |
| [worker.test.ts](../apps/cloud/test/worker.test.ts) | 13 |
| [worker-e2e.test.ts](../apps/cloud/test/worker-e2e.test.ts) | 12 |

测试使用隔离内存/临时 SQLite、环回 HTTP 及模型替身。非法环境开关覆盖空字符串、true、false、2、带空白的 1、01；都在创建数据库/监听端口前拒绝启动。迁移测试覆盖普通历史和目标快照回填，不接触生产数据库。

本轮没有运行桌面端 E2E 或仓库全量测试，也没有真实 provider 的目标问答兼容验收。

## 4. iPhone 实际验证层级

实际运行：

```powershell
& $node apps/iphone/scripts/validate-minimal-v2.cjs
```

结果：**12/12 静态组通过**；扫描 39 个 Swift 源文件、15 个 XCTest 源文件、101 个测试方法声明，解析 34 个字面 JSON 夹具。该脚本主要使用字符串/正则和 JSON.parse，不能证明 Swift 编译、XCTest 或界面运行正确。

另使用系统 Python `C:\Users\QUIZ\AppData\Local\Programs\Python\Python313\python.exe` 中已有的 tree_sitter / tree_sitter_swift，对 Sources 和 Tests 下合计 **54 个 Swift 文件**解析语法树，并遍历 ERROR / missing 节点；结果为 **0 个语法错误**。这是语法解析，不是 Swift 类型检查或 XCTest 执行。内置 bundled Python 没有这些模块，不应据此误判系统 Python 同样不可用。

本机未发现 swift、swiftc、xcodebuild、xcodegen。已有[CI 流程](../.github/workflows/ios-ipa.yml#L108)包含 xcodebuild test、无签名 Release 和 IPA 打包；[工程 scheme](../apps/iphone/project.yml#L174)已包含两组测试 target。本轮未触发 CI，也没有生成或安装新 IPA。

本轮五个源码文件的 `git diff --check` exit 0，仅出现既有 CRLF 转 LF 提示。

独立审阅最终云端修复、迁移回归及 iPhone 三条异步路径/测试后，在本次改动范围内未发现仍未解决的严重或中等问题；原始身份续体与 blocked trim 问题均已闭环。该结论是源码审阅，不代替未运行的 XCTest。

## 5. 后续验收与发布边界

1. 保持原会话的不推送、不直接写生产数据约束。本轮未 commit、push、运行外网 CI、SSH 部署或生产验收脚本。
2. 下一步需让本次精确源码进入实际 macOS 验证：编译、执行 XCTest、无签名 Release、IPA 结构检查。已有旧提交/旧 build 的成功结果不适用于本次未提交源码。
3. 生产发布必须遵守[冻结扩展契约](../packages/contracts/PHASE-2-GOALS-TASKS.md#L40)：兼容 API 先保持目标问答关闭；新 worker 支持 lease capability/固定快照；验证后才开启目标问答，最后更新 iPhone。关闭 gate 不等于可把已有目标 run 当普通聊天处理。
4. 真机仍需确认创建/修改/离线草稿、冲突恢复、切身份、关联目标问答和固定依据，并回归已验收普通聊天、多轮、取消、前后台/强退恢复。
5. 原会话准备的构建/发布脚本本轮没有执行；任何后续 source snapshot、release manifest、CI/IPA 都必须从最终源码重新生成，不能用旧快照替代本次代码。

2026-11-27 接续：当前源码与验证总数已有后续变化；精确源码包、当前 92 项云端回归和 macOS 原生验证交接见 [接续记录](P2-A-SOURCE-HANDOFF-20261127.md)。本历史记录中的 83 项、12 组和 build 3 不代表后续工作树状态。
