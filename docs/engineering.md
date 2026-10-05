# 工程规范

适用于 MacLauncher 的 Dart、Flutter、原生桥接及检查脚本。**必须**是验收要求；**建议**可按具体问题调整并说明原因；**按需**在出现对应复杂度或实测问题时采用。

产品行为以来源工单、[应用生命周期 ADR](adr/0001-application-owned-lifecycle.md) 和相关接入文档为准，术语以 [CONTEXT.md](../CONTEXT.md) 为准。本文记录工程选择，界面规则见 [设计规范](design.md)。遇到冲突先指出具体条目，再作范围明确的决定。

## 编码与模块边界

| 规则 | 强度 | 要求与核验方式 |
| --- | --- | --- |
| E01 语言基线 | 必须 | 命名与导入遵循 Effective Dart；格式交给 `dart format`，纯 Dart 模块使用根 `analysis_options.yaml` 的推荐规则，Flutter 应用沿用 `launcher/analysis_options.yaml` 的 flutter_lints 基线。通过格式与分析检查。 |
| E02 类型与外部数据 | 必须 | 接口声明明确类型；项目配置、SDK 消息和应用返回的状态/日志在 I/O 边界校验后形成有类型的数据。核对非法输入测试，避免将 `dynamic` 传播到业务逻辑。 |
| E03 异步归属 | 必须 | 调用方等待需要完成的工作；有意后台执行用 `unawaited` 表达，并落实错误处理和生命周期归属。核对失败、取消及晚到结果的行为。 |
| E04 资源所有权 | 必须 | 进程、连接、订阅和临时文件有明确创建者与释放入口。自动释放处理本应用拥有的运行资源；项目资产与目标应用资源的处理遵循生命周期 ADR。核对重复关闭及外部资源保留。 |
| E05 界面边界 | 必须 | Widget 处理展示、输入、布局、焦点与局部交互状态；项目绑定、SDK 通信、状态观察和操作编排由业务模块负责。审查调用路径。 |
| E06 应用拥有生命周期 | 必须 | 启动器通过 SDK 或应用控制入口发送请求；目标应用执行操作并报告实际状态。`launcher_core` 与 `maclauncher_sdk` 保持纯 Dart，Flutter 负责呈现和原生桥接。核对退出、失联、重连与已有运行实例保留。 |
| E07 状态归属 | 必须 | 每种业务状态有一个权威来源，界面观察它并提交操作。局部输入可用 `State`；可观察状态可用现有 `Listenable`/流。新增状态管理库需说明现有方案解决不了的问题。 |
| E08 依赖传入 | 建议 | 从应用组装入口通过构造参数传入业务依赖。共享状态由明确的所有者维护，便于测试和生命周期管理。 |
| E09 按职责拆分 | 建议 | UI 按页面或功能聚合，共享业务与 I/O 模块按职责组织。按修改需要拆分现有文件；目录迁移作为独立改动评估。 |
| E10 增加抽象 | 按需 | 重复业务逻辑或过大的界面状态处理出现后，再提取领域模块或 use-case；外部边界及实际需要替换的实现使用接口。说明抽象服务的具体调用方。 |
| E11 性能措施 | 按需 | 大列表使用惰性构建；CPU 工作、重绘或状态更新影响交互时，先测量，再选择 isolate、重绘隔离等措施，并用相同场景对比。 |
| E12 依赖变更 | 必须 | 说明新增包解决的问题及 SDK/平台兼容性，在选定的检查环境解析依赖并保留统一 lockfile。实验性 API 先验证固定 SDK 与平台支持，再决定是否采用。 |

Flutter 应用位于 `launcher/`，纯 Dart 核心与 SDK 位于 `packages/`，受控示例位于 `example/`。状态管理与目录结构服务于这些边界。MVVM 是组织 UI 与状态处理的参考；无需为每个功能复制一套三层目录。

## 修改与检查流程

1. 确认本次行为、适用规则及可观察的成功标准；涉及领域行为时按 `docs/agents/domain.md` 读取术语与相关 ADR。
2. 在现有业务入口实现修改。缺陷先复现，行为变更补充相应测试；文档或纯视觉调整使用链接、截图和交互检查验证。
3. 运行下列检查，逐项报告通过、失败或未执行。失败时给出位置，并区分本次新增与原有问题；仅在零诊断时报告静态分析通过。

```sh
./scripts/check-flutter.sh format
./scripts/check-flutter.sh analyze
./scripts/check-flutter.sh test
```

先从仓库根目录运行 `~/flutter/bin/flutter pub get --enforce-lockfile`。检查脚本默认使用本机 `~/flutter/bin/flutter` 与同一 SDK 的 `~/flutter/bin/dart`，在其他 SDK 环境可用 `FLUTTER_BIN` 与 `DART_BIN` 指定命令，其中 Dart 使用 Flutter 的 `bin/dart` 入口以保留 SDK 上下文；两者的 Dart 版本应一致。`format` 使用 `--output=none`，只检查源码，不改写文件。

根 workspace 包含 Flutter 成员，因此 Dart 测试使用 Flutter 自带的 Dart 入口，以传递 SDK 上下文。检查涵盖 SDK、核心、受控示例和 Flutter 应用；`test` 分别运行核心/SDK 的真实 socket 测试与 Flutter widget 测试。依赖与通用测试按所选本机或容器流程运行；Mac 构建、菜单栏、登录项和原生桥接另做 Mac 联调。

**不要在 packages/ 或 example/ 下直接调 `flutter test`**：它用 frontend_server 编译路径，`dart:isolate` 的部分 API（如 `Isolate.resolvePackageUriSync`）在其中不受支持，测试会在加载期失败或挂起。所有测试统一经 `./scripts/check-flutter.sh test`（核心/SDK 走 dart test，launcher 走 flutter test）。

## 测试与完成证据

- **必须**从公开业务入口验证输入、输出、状态与资源变化；SDK 和核心沿用真实 socket 往返测试，应用侧接缝遵循 [SDK 接入文档](SDK_INTEGRATION.md#测试建议)。
- **必须**给并发、超时、取消和生命周期修改提供确定性的行为证据。菜单栏接管/归还、登录启动和窗口操作需要各自的 Mac 原生验收；通用测试不能替代。
- **必须**在结果中说明检查范围与限制。新增 lint 暴露已有问题时保留诊断，修复按明确范围进行；规则抑制需在对应位置解释必要性。
- **建议**为重要架构取舍按需记录 ADR，包含问题、选择、代价和验证。小型实现选择留在代码或变更说明中。

## 依据

查阅日期：2026-10-05。官方建议提供依据；本项目的要求强度由本文确定。

- [Effective Dart](https://dart.dev/effective-dart)：语言约定。
- [flutter_lints](https://pub.dev/packages/flutter_lints)：官方应用 lint 基线，具体版本由 `pubspec.yaml` 与 lockfile 固定。
- [Flutter 架构建议](https://docs.flutter.dev/app-architecture/recommendations)：职责分离、数据流和条件性建议。
- [Flutter 架构示例](https://docs.flutter.dev/app-architecture/case-study)：UI 按功能与数据按职责组织的示例。
- [Flutter 仓库风格指南](https://github.com/flutter/flutter/blob/master/docs/contributing/Style-guide-for-Flutter-repo.md)：按需参考；框架仓库的特殊政策不自动成为应用要求。
