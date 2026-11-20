# Personal OS · 三端工程（新）

个人助手的独立仓库：**云端服务 / DSH 桌面插件 / iPhone 原生客户端**共用一套协议，
与旧的 `dsh-plugins/dsh-personal-os` 插件仓库**完全隔离**（旧仓库不再承接新功能）。

> 当前状态：**iPhone 客户端已可构建（待首次 CI 编译验收）**；云端与插件目录为占位，
> 迁移在 R1 阶段按 `docs/split/00-decision.md` 的结论推进。

## 目录

```
.
├── apps/
│   ├── iphone/        原生客户端（SwiftUI + XcodeGen，Windows 上可开发）
│   ├── cloud/         云端服务（占位，未开始）
│   └── dsh-plugin/    DSH 插件（占位，旧实现待迁入）
├── packages/
│   └── contracts/     三端共享协议（占位，待冻结）
└── .github/workflows/ CI：测试 + 无签名 IPA
```

## iPhone 客户端

- 工程入口：`apps/iphone/project.yml`（XcodeGen 生成，不提交 `.xcodeproj`）
- 接口契约：`apps/iphone/CONTRACT.md`
- 构建与装机：`apps/iphone/README.md`
- 本机（Windows）没有 Swift 工具链，**编译与单测以 CI 为准**

最短路径：

1. push 到 `main` → Actions 自动跑 `ios-ipa`；
2. 下载 `POSApp-unsigned-ipa`；
3. 用 Sideloadly 装到 iPhone（免费账号 7 天签名）。

## 与旧仓库的边界

| 内容 | 位置 |
|---|---|
| 旧插件（只读，冻结） | `C:\Users\QUIZ\Desktop\project\dsh-plugins\dsh-personal-os` |
| 拆分判断与四份审计 | 旧仓库 `docs/split/` |
| 新功能与新代码 | 本仓库，`apps/**` |

旧仓库不再新增功能；需要迁移的部分按审计报告（`01`~`04`）逐块搬入本仓库。
