# P2-A 精确源码包与 macOS 原生验证

本入口用于将**当前工作树中的 iPhone 源码**交给一台受信任的 Mac 验证；不要求 commit 或 push，不调用 GitHub、不部署云端、不操作 DSH profile，也不携带设备配对凭据。

源码打包、哈希校验与驱动单测可在 Windows 完成。Swift 编译、XCTest 和 Release 构建必须在真实 macOS 上运行。驱动单测中的替身构建不属于原生验证。源码包不是 IPA，不能安装到手机。

## 1. Windows 固定源码

在仓库根目录使用 Python 3.9 或更高版本运行（输出路径须不存在）：

```powershell
python -B apps/iphone/scripts/test_ios_source.py -v
python -B apps/iphone/scripts/ios_source.py pack --output ../personal-os-p2a-ios-source.zip
```

打包白名单为工程配置、三份 xcconfig、Swift Sources/Tests、Assets 资源、两份冻结契约、本说明及验证脚本。不包含云端/桌面代码、数据库、`.env`、profile、已有 IPA、构建目录或生成的 Info.plist。白名单目录出现非预期类型、符号链接或目录联接时拒绝打包；打包期间输入变化也拒绝输出。未提交和新增的 Swift 文件会被纳入。

ZIP 内 `IOS-SOURCE.json` 记录每个输入文件的相对路径、字节数和 SHA-256，`sourceHash` 由有序记录计算，精确区分换行。它用于一致性核对，**不是数字签名或可信来源认证**。传送源码包时应使用受信任渠道；不要向未知构建服务上传个人源码。

## 2. 在 Mac 上校验后构建

将源码 ZIP 解压到一个新目录，在该目录运行。Mac 需事先安装完整 Xcode、对应 iOS SDK/可用模拟器和 XcodeGen；脚本不会联网安装依赖或请求签名凭据。

```sh
python3 apps/iphone/scripts/ios_source.py check
xcrun simctl list devices available
```

从输出选定一个真实可用的 iPhone 模拟器，将其 UDID 用作下列命令中的 `SIMULATOR_UDID` 环境变量：

```sh
python3 apps/iphone/scripts/ios_source.py macos \
  --output ../p2a-native-result \
  --destination "platform=iOS Simulator,id=${SIMULATOR_UDID:?set an available simulator UDID}"
```

输出目录须不存在。脚本先核对源码哈希，再将已校验的输入复制到独立构建目录，然后依次执行：

1. 记录 `xcodebuild -version` 和 `xcodegen --version`。
2. 由 `project.yml` 生成 `POSApp.xcodeproj`。
3. 对 `POSApp` scheme 执行 `xcodebuild test`，包含 POSCoreTests 和 POSFeaturesTests，并保存 `Tests.xcresult`。
4. 进行关闭代码签名的 iPhoneOS Release 构建。
5. 再次核对输入、打包 `POSApp-unsigned.ipa`，检查应用 ID、版本、arm64 Mach-O 主程序和两个嵌入框架。

任一步返回非零立即停止；XCTest 失败不会继续 Release 打包。原工程工作树不会被 XcodeGen 改写。非 macOS 调用会明确失败，不能生成原生通过结论。

## 3. 取回证据与后续边界

成功输出目录包含原生测试/构建日志、xcresult、无签名 IPA 和 `validation-result.json`。结果中的 `sourceHash` 必须与 Windows 打包输出及 ZIP 内清单一致，IPA SHA-256 另列。`status=BUILT_NOT_INSTALLED` 只表示该源码已通过该台 Mac 的命令链和结构验包，不代表生产 API 已启用、真实 provider 兼容、手机安装或 P2-A 真机验收完成。

若失败，查看结果记录中的 `error`；若命令返回非零，再查看对应步骤日志。返回日志时先检查是否含个人信息；不要返回 Keychain、配对密钥或设备 token。未经本阶段发布授权，不执行生产部署、开启目标问答 gate 或覆盖装机。后续发布顺序和真机场景仍以 [冻结契约](../packages/contracts/PHASE-2-GOALS-TASKS.md#L40) 与 [P2-A 验收清单](PHASE-2-GOALS-TASKS-PLAN.md#L180) 为准。
