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
  projectId: 'your-project-id',   // 稳定唯一的项目身份；配置文件路径下须与 maclauncher.json 的 project.id 一致
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

SDK 连接成功不等于被接受。关联有两条路径：

1. **运行时发现（免配置，推荐）**：SDK 握手时自报 `projectName` 与可选
   `entry`（见下文「自报项目信息」），项目出现在启动器的待批准列表，
   用户点一次「批准」即完成关联，全程无需配置文件。批准前握手按
   `pending-approval` 拒绝，SDK 自动重连重试属正常。
2. **配置文件（可选增强）**：项目目录放置 `maclauncher.json`（schemaVersion 1，
   见 [PROJECT_ASSOCIATION.md](PROJECT_ASSOCIATION.md)），在启动器中
   「关联项目」选择该文件。SDK 的 `projectId` 必须与配置里的
   `project.id` 一致，`services` 的键必须与配置里的服务 id 一致——
   不一致会在握手时被拒绝（`SdkConnectionState.rejected`，reason 说明
   原因）。配置文件提供稳定的服务清单、完整拉起命令与配置刷新。

被用户加入忽略列表的项目，握手静默拒绝且不出现在待批准；在启动器
设置页移除后恢复。

## 能力声明

`ServiceCallbacks` 中**非 null 的回调即声明能力**。只提供 `onStatus` 的
服务在启动器里只显示状态，不会出现启动/回收按钮。方法常量：
`kMethodStart`、`kMethodRecycle`、`kMethodStatus`、`kMethodLogs`。

应用级能力通过 `AppCallbacks` 声明（见下文「窗口与入口协作」与
「版本状况查询」），方法常量：`kMethodOpenWindow`、`kMethodSetEntryManaged`、
`kMethodVersionStatus`。

## 自报项目信息（运行时发现）

```dart
final sdk = MacLauncherSdk.connect(
  projectId: 'your-project-id',
  projectName: '我的应用',             // 可选：待批准卡片与绑定的显示名
  entry: SdkEntry.currentAppBundle(),  // 可选：自报拉起入口
  services: { /* ... */ },
);
```

- `SdkEntry.appBundle(path)` / `SdkEntry.executable(path, args:, workingDirectory:)`
  显式指定入口；`SdkEntry.currentAppBundle()` /
  `SdkEntry.currentExecutable()` 从当前进程路径推断。入口允许完整启动
  命令（args、工作目录），批准后即可被启动器拉起。
- 未自报 `entry` 也能被批准：启动器仅观察与回收，不能拉起该应用。
- 运行时绑定的服务清单由握手自报驱动：下次连接增删服务自动同步
  （被删除的声明在启动器中保留只读记录）。
- 入口路径失效（应用被移动/删除）时，启动器卡片显示「入口失效」；
  应用重新运行并连接后，自报自动修复绑定里的入口。

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

## 版本状况查询

启动器可以询问应用的「版本状况」（当前版本、是否有新版本、最新版本号、
下载地址、查询结果）。注册 `onVersionStatus` 即声明该能力。如何查询
更新源由你的应用自己决定（SDK 不含下载能力）。

可运行的参照实现见 `example/minimal_app/`（#35）：它按固定假数据应答，
接入方可直接照抄 `lib/fake_version_status.dart` 的注册方式。联调时用
`--version-status=success|failure|unsupported` 命令行参数或
`MACLAUNCHER_VERSION_STATUS` 环境变量（参数优先）切换三态：
成功（含新版本号、下载地址与 sha256）、失败（附原因）、不支持更新
（不注册回调，验证 SDK 自动应答）。

```dart
// 摘自 example/minimal_app/lib/fake_version_status.dart：
AppCallbacks(
  onVersionStatus: () async => VersionStatus(
    state: VersionQueryState.success,
    currentVersion: '1.0.0',
    hasUpdate: true,
    latestVersion: '1.1.0',
    downloadUrl: 'https://example.invalid/minimal_app/minimal_app-1.1.0.dmg',
    sha256: kDemoSha256,   // 可选，供后续下载校验
  ),
)
```

约定：

- **如实回报查询结果**：查询失败返回 `state: VersionQueryState.failure`
  并附 `failureReason`；没有更新渠道返回
  `state: VersionQueryState.unsupported`（或 `VersionStatus.unsupported()`）
  ——「不支持更新」是正常应答，不是错误。
- **未注册回调不是错误**：SDK 会自动应答「不支持更新」。旧版 SDK 没有
  该能力位，启动器不会向它发送查询。
- **回调可以抛异常**：SDK 会兜底成 `state: VersionQueryState.failure`
  （`failureReason` 带异常摘要）的正常应答，不会让启动器把应用内的
  查询失败误当成超时或断连。
- 字段按应用回报原样展示，缺失的字段保持缺失，UI 会标注「未提供」。

## 连接生命周期

- `MacLauncherSdk.connect(...)` 立即返回，内部自动连接与重连
  （默认 `retryInterval: 5s`）；启动器未运行时静默等待，无需自己重试。
- `states` 广播流：`disconnected / connecting / connected / rejected`。
  `rejected` 的常见原因：`pending-approval`（等待用户在启动器里批准，
  持续重试属正常，不要提示用户）、未关联（绑定不存在）、身份冲突。
- **解除绑定的表现**：用户在启动器里解除绑定后，在线应用会先收到
  `setEntryManaged(false)` 归还入口，随后会话被主动关闭；SDK 的自动重连
  会重新进入待批准，以 `pending-approval` 被拒（除非用户已把项目加入
  忽略列表，则为静默拒绝）。用户再次「批准」即可恢复关联。接入方应将
  **持续 rejected 视为绑定已解除**：提示用户到启动器里处理（批准、忽略
  或重新关联配置），或停止等待并退回独立运行，不要无限静默重试。
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
覆盖（握手、重连、请求路由、busy/去重规则、版本状况查询，共 138 项）。你的应用侧
建议：`onStatus` 返回值的快照测试 + 用 minimal_app 模式起一个假业务
与真实启动器联调。
