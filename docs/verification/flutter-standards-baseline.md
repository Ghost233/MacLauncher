# Flutter 规范同步检查

日期：2026-10-05。规范入口见根 AGENTS.md；工程与界面要求分别见 [工程规范](../engineering.md) 和 [设计规范](../design.md)。

## 环境与范围

- Mac 原生 Flutter 3.47.6 / Dart 3.13.5；Flutter 提交 `5fc346839b5d0eef006ed8404392afb4dfae428d`。
- 基础提交：`310a9fde67b5b09918ef791b9cf9420c366de424`，增加规范与检查配置后在临时源码副本验证。
- Flutter 应用保留已有 flutter_lints 6.0.0 配置；根纯 Dart 模块采用 lints 6.1.0。离线 `pub get --enforce-lockfile` 通过，解析后的 lockfile 与工作区一致。
- 检查覆盖 SDK、核心、受控示例及 Flutter 应用。按输入文件名排序，以“文件名 + NUL + 文件内容”计算的 SHA-256 为 `80c812ec64d452dea121093d7fa7b7639f228907243d739f56977941c4592126`；检查副本与工作区输入一致。

## 结果

| 检查 | 实际结果 |
| --- | --- |
| 文档引用与脚本语法 | 12 个本地链接/锚点通过；`bash -n` 通过 |
| 静态分析 | 未通过：37 条 info，0 warning、0 error，退出码 1 |
| 格式检查 | 未通过：47 个文件中 4 个需格式化，退出码 1 |
| SDK/核心测试 | 123 项全部通过 |
| Flutter widget 测试 | 5 项全部通过；完整测试命令退出码 0 |

待格式化文件：`launcher/lib/live_debug.dart`、`log_panel.dart`、`main.dart`、`project_card.dart`。

lint 基线为初始化参数 25 条、null-aware 元素 4 条、多余下划线 3 条、未声明测试依赖 2 条，以及注释 HTML、字符串插值括号、控制流括号各 1 条。这些是新检查发现的现有源码提示，本次保留诊断，按明确范围整改。

检查命令见工程规范。完整日志、退出码、汇总与源码归档保存在本机忽略目录 `.scratch/flutter-standards-20261005-ercvu6oh/`。格式检查使用 `--output=none`；应用与 SDK 源码保持原样。

本记录验证规范与检查入口的同步；菜单栏、登录项、窗口及入口归还的 Mac 原生交互验收按设计规范另行执行。
