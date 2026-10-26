# Changelog

本项目的所有显著变更都会记录在此文件。

格式基于 [Keep a Changelog](https://keepachangelog.com/zh-CN/1.1.0/)，
版本号遵循 [语义化版本](https://semver.org/lang/zh-CN/)。

## [1.1.5] - 2026-10-26

### Added

- SDK 新增 `dart run maclauncher_sdk:codegen` 命令：把 maclauncher.json（schemaVersion 1）直译为入库的 Dart 常量（项目 ID、服务 id 与显示名），接入方 `connect(...)` 直接引用生成常量，配置与握手自报在结构上不可能漂移（ADR 0005，规格 #53 / 工单 #54）。
- example/minimal_app 提供完整接入示范：maclauncher.json + 生成产物 `lib/maclauncher_manifest.g.dart` 入库（#55）。
- SDK_INTEGRATION.md 新增「打包发布」章节，PROJECT_ASSOCIATION.md 补充 `@` 保留前缀规则与 ADR 0005 交叉引用。

### Changed

- maclauncher.json 的角色由「运行时绑定配置」降级为「构建输入」：开发期仍可用于配置绑定联调，打包发布的 app 走 codegen + `SdkEntry.currentAppBundle()`，不再依赖访问配置文件（ADR 0005）。
- example/minimal_app 的 projectId 位置参数改为可选，缺省取生成常量。

## [1.1.4] - 2026-10-13

### Fixed

- 启动器启动期间渲染加载界面（2c4dc72）。

## [1.1.3] - 2026-10-13

### Fixed

- 通过 TextTheme 统一启动器排版（4d7c7f6）。

## [1.1.2] - 2026-10-10

### Added

- 界面布局自适应管理窗口尺寸（e38dd68）。

## [1.1.1] - 2026-10-08

### Added

- 管理窗口打开期间显示 Dock 图标（084ae90）。

## [1.1.0] - 2026-10-08

### Fixed

- 管理窗口关闭后隐藏 Dock 驻留（3893890）。
