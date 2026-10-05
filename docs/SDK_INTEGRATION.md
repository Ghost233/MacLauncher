# MacLauncher SDK 接入指南

`maclauncher_sdk` 是让独立应用接入 MacLauncher 的 Dart SDK。纯 Dart 实现，
不依赖 Flutter，可用于任何 macOS 进程（Flutter 应用、命令行守护进程、
编译型可执行文件）。

## 依赖

SDK 目前随 MacLauncher 仓库分发，以 git 依赖引用子目录：

```yaml
dependencies:
  maclauncher_sdk:
    git:
      url: https://github.com/Ghost233/MacLauncher.git
      path: packages/maclauncher_sdk
      ref: main   # 建议锁定到具体 tag 或 commit
```

同仓库内开发时可用 path 依赖：`path: ../../packages/maclauncher_sdk`。

## 快速开始

```dart
import 'package:maclauncher_sdk/maclauncher_sdk.dart';

final sdk = MacLauncherSdk.connect(
  projectId: 'your-project-id',   // 必须与 maclauncher.json 的 project.id 一致
  services: {
    'web': ServiceCallbacks(
      name: 'Web 服务',
      onStart: () async { /* 启动业务 */ },
      onRecycle: () async { /* 回收业务（释放端口/进程/连接） */ },
      onStatus: () async => ServiceStatus(
        state: ServiceState.running,
        observedAt: DateTime.now().toUtc(),
      ),
    ),
  },
);

sdk.states.listen((s) => print('sdk: ${s.state.name} ${s.reason ?? ''}'));

// 退出前：
await sdk.dispose();
```

完整可参考实现见 `example/minimal_app/`（`bin/minimal_app.dart` +
`lib/fake_business.dart`），可直接 `dart run` 配合启动器联调。

## 前提：项目关联

SDK 连接成功不等于被接受。启动器只接受**已关联项目**的连接：

1. 项目目录放置 `maclauncher.json`（schemaVersion 1，见
   [PROJECT_ASSOCIATION.md](PROJECT_ASSOCIATION.md)）；
2. 在启动器中「关联项目」选择该文件；
3. SDK 的 `projectId` 必须与配置里的 `project.id` 一致，`services` 的键
   必须与配置里的服务 id 一致——不一致会在握手时被拒绝
   （`SdkConnectionState.rejected`，reason 说明原因）。

## 能力声明

`ServiceCallbacks` 中**非 null 的回调即声明能力**。只提供 `onStatus` 的
服务在启动器里只显示状态，不会出现启动/回收按钮。方法常量：
`kMethodStart`、`kMethodRecycle`、`kMethodStatus`、`kMethodLogs`。

应用级能力通过 `AppCallbacks` 声明（见下文「窗口与入口协作」）。

## 回调契约

### onStatus —— 如实回报

启动器 UI **只展示应用回报的快照**，点击按钮不会改变显示状态；状态超过
15 秒未更新会被标记为失效（stale）。因此 `onStatus` 必须返回真实状态，
不要返回"期望状态"。`observedAt` 用 UTC 当前时间。

### onRecycle —— 回收不是退出

回收业务资源（端口、子进程、连接），**不要退出应用进程本身**。

### onLogs —— 日志批次

```dart
onLogs: (LogQuery query) async => LogBatch(
  entries: [...],                    // List<LogEntry>，最多返回 query.limit 条
  truncated: false,                  // 有未送达的更早日志时置 true
),
```

`LogEntry` 的 `timestamp` 可空（UI 显示「无原始时间」）、`stream` 可传
`LogStream.unknown`（UI 显示「分流未知」）。UI 逐字渲染日志内容，不做
加工。详见 [LOGS.md](LOGS.md)。

## 窗口与入口协作

```dart
AppCallbacks(
  onOpenWindow: () async { /* 用户点「打开窗口」：激活/新建主窗口 */ },
  onSetEntryManaged: (managed) async {
    // 启动器请求暂时隐藏（true）或归还（false）你的菜单栏入口。
    // 完成后返回 true 确认；返回 false 表示无法配合。
    return true;
  },
)
```

约定：接管期间你的入口应隐藏；启动器退出时会尽力 `managed: false` 归还，
**绝不替你回收业务**。详见 [ENTRY_HANDOFF.md](ENTRY_HANDOFF.md)。

## 连接生命周期

- `MacLauncherSdk.connect(...)` 立即返回，内部自动连接与重连
  （默认 `retryInterval: 5s`）；启动器未运行时静默等待，无需自己重试。
- `states` 广播流：`disconnected / connecting / connected / rejected`
  （`rejected` 带拒绝原因，如未关联、身份冲突）。
- 内置 ping/pong 看门狗（5s 心跳，15s 超时判定死亡并触发重连）。
- `dispose()`：停止重连、销毁在途连接；可中断重试中的等待，调用后
  实例不可复用。
- 单实例约束：同一 `projectId` 只允许一个活跃连接，第二个连接会被
  拒绝（不抢占）。

## 请求语义（SDK 已内置，无需自己实现）

- **去重**：同一连接上参数相同的并发请求复用同一在途调用；已完成的
  结果按 LRU（128 条）缓存回放。
- **busy**：同一服务的 start/recycle 串行化，并发变更立即以
  `ProtocolError.busy` 快速失败——回调里不需要自己做互斥，但要能容忍
  收到 busy（此时应如实回报当前状态）。

## 测试建议

SDK 客户端由 `packages/launcher_core/test/` 下的真实 socket 往返测试
覆盖（握手、重连、请求路由、busy/去重规则，共 123 项）。你的应用侧
建议：`onStatus` 返回值的快照测试 + 用 minimal_app 模式起一个假业务
与真实启动器联调。
