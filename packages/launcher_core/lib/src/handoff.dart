import 'dart:async';

import 'package:maclauncher_sdk/maclauncher_sdk.dart';

import 'registry.dart';
import 'server.dart';

/// 统一入口接管状态。
enum EntryHandoffStatus {
  /// 应用未声明 setEntryManaged 能力：服务协作仍可用，应用保留自己的入口。
  notManageable,

  /// 未接管（初始、确认失败或会话丢失后）。
  unmanaged,

  /// 应用已确认收起自身菜单栏入口，接管完成。
  managed,
}

class HandoffState {
  const HandoffState(this.projectId, this.status);

  final String projectId;
  final EntryHandoffStatus status;
}

/// openWindow 请求结果。
enum HandoffRequestOutcome {
  /// 应用已接收。
  acknowledged,

  /// 应用未声明 openWindow 能力。
  unsupported,

  /// 应用未连接。
  unavailable,

  /// 等待结果超时：结果未知，不重发。
  unknown,
}

/// 入口接管协调器（启动器侧）。
///
/// 顺序契约：先完成项目登记与初始状态查询，再请求接管；应用确认后才宣告
/// managed，确认失败保持 unmanaged（允许短暂双入口）。会话丢失只反映现实地
/// 清除 managed——真正的入口归还由应用/SDK 侧心跳兜底执行。旧会话的确认
/// 永远不能标记新会话（按 launcherSessionId 守卫）。
class EntryHandoffCoordinator {
  EntryHandoffCoordinator({
    required this._server,
    required this._statusQuery,
    this._requestTimeout = const Duration(seconds: 30),
    this._releaseTimeout = const Duration(seconds: 3),
  }) {
    _subscription = _server.registry.changes.listen(_onRegistryChange);
    for (final project in _server.registry.connected) {
      _onConnected(project);
    }
  }

  final LauncherServer _server;
  final Future<bool> Function(String projectId) _statusQuery;
  final Duration _requestTimeout;
  final Duration _releaseTimeout;

  final _states = StreamController<HandoffState>.broadcast();
  final _statusByProject = <String, EntryHandoffStatus>{};

  /// projectId → 当前 managed 所属会话。
  final _managedSession = <String, String>{};
  late final StreamSubscription<ConnectedProject?> _subscription;
  var _disposed = false;

  /// 状态流，供 UI 集成。
  Stream<HandoffState> get states => _states.stream;

  EntryHandoffStatus statusOf(String projectId) =>
      _statusByProject[projectId] ?? EntryHandoffStatus.unmanaged;

  void _onRegistryChange(ConnectedProject? project) {
    if (_disposed) return;
    // 先对账：已断开或会话已替换的项目清除 managed（归还由应用侧执行）。
    final gone = <String>[];
    _managedSession.forEach((projectId, sessionId) {
      final current = _server.registry.byProject(projectId);
      if (current == null || current.launcherSessionId != sessionId) {
        gone.add(projectId);
      }
    });
    for (final projectId in gone) {
      _managedSession.remove(projectId);
      _emit(projectId, EntryHandoffStatus.unmanaged);
    }
    if (project != null) _onConnected(project);
  }

  void _onConnected(ConnectedProject project) {
    final projectId = project.projectId;
    if (!project.capabilities.supportsApp(kMethodSetEntryManaged)) {
      _emit(projectId, EntryHandoffStatus.notManageable);
      return;
    }
    if (_managedSession.containsKey(projectId)) return;
    _emit(projectId, EntryHandoffStatus.unmanaged);
    unawaited(_takeover(project));
  }

  Future<void> _takeover(ConnectedProject project) async {
    final projectId = project.projectId;
    final sessionId = project.launcherSessionId;

    bool current() {
      final now = _server.registry.byProject(projectId);
      return now != null && now.launcherSessionId == sessionId;
    }

    try {
      // 先完成登记后的初始状态查询，再请求接管。
      final ready = await _statusQuery(projectId);
      if (!ready || !current() || _disposed) return;

      final session = _server.sessionFor(projectId);
      if (session == null || session.launcherSessionId != sessionId) return;

      final response = await session.sendRequest(
        kMethodSetEntryManaged,
        params: {'managed': true},
        timeout: _requestTimeout,
      );
      // 旧会话的应答不能标记新会话。
      if (!current() || _disposed) return;
      final result = (response['result'] as Map?)?.cast<String, Object?>();
      if (result?['confirmed'] == true) {
        _managedSession[projectId] = sessionId;
        _emit(projectId, EntryHandoffStatus.managed);
      } else {
        // 确认失败：保留/恢复原入口，允许短暂双入口。
        _emit(projectId, EntryHandoffStatus.unmanaged);
      }
    } catch (_) {
      // 超时、断连或协议错误：保持 unmanaged，不自动重发。
      if (current() && !_disposed) {
        _emit(projectId, EntryHandoffStatus.unmanaged);
      }
    }
  }

  /// 打开应用原窗口；只有已声明能力时才发送。
  Future<HandoffRequestOutcome> openWindow(String projectId) async {
    final project = _server.registry.byProject(projectId);
    if (project == null) return HandoffRequestOutcome.unavailable;
    if (!project.capabilities.supportsApp(kMethodOpenWindow)) {
      return HandoffRequestOutcome.unsupported;
    }
    final session = _server.sessionFor(projectId);
    if (session == null) return HandoffRequestOutcome.unavailable;
    try {
      final response = await session.sendRequest(
        kMethodOpenWindow,
        timeout: _requestTimeout,
      );
      if (response['error'] != null) return HandoffRequestOutcome.unsupported;
      return HandoffRequestOutcome.acknowledged;
    } on TimeoutException {
      return HandoffRequestOutcome.unknown;
    } catch (_) {
      return HandoffRequestOutcome.unavailable;
    }
  }

  /// 正常退出/解绑路径：尽力向当前 managed 会话发送 managed:false。
  ///
  /// 失败被吞掉——应用/SDK 侧心跳归还是兜底。永不发送 recycle。
  Future<void> releaseAll() async {
    final entries = _managedSession.entries.toList();
    _managedSession.clear();
    for (final entry in entries) {
      await _release(entry.key, entry.value);
    }
  }

  /// 解除绑定路径：尽力归还单个项目的统一入口。
  ///
  /// 只触碰当前 managed 会话；项目未受管或不在线时是 no-op。失败被吞掉，
  /// 不阻塞解绑——应用/SDK 侧心跳归还是兜底。永不发送 recycle。
  Future<void> release(String projectId) async {
    final sessionId = _managedSession.remove(projectId);
    if (sessionId == null) return;
    await _release(projectId, sessionId);
  }

  Future<void> _release(String projectId, String sessionId) async {
    _emit(projectId, EntryHandoffStatus.unmanaged);
    final session = _server.sessionFor(projectId);
    if (session == null || session.launcherSessionId != sessionId) {
      return;
    }
    try {
      await session.sendRequest(
        kMethodSetEntryManaged,
        params: {'managed': false},
        timeout: _releaseTimeout,
      );
    } catch (_) {
      // 尽力而为；应用侧会按心跳超时自行归还。
    }
  }

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    await _subscription.cancel();
    await _states.close();
  }

  void _emit(String projectId, EntryHandoffStatus status) {
    if (_disposed) return;
    _statusByProject[projectId] = status;
    _states.add(HandoffState(projectId, status));
  }
}
