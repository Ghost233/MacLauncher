import 'dart:async';

import 'package:maclauncher_sdk/maclauncher_sdk.dart';

import 'registry.dart';
import 'preferences.dart';
import 'server.dart';

/// 统一入口接管状态。
enum EntryHandoffStatus {
  /// 应用未声明 setEntryManaged 能力：服务协作仍可用，应用保留自己的入口。
  notManageable,

  /// 初始或应用未连接。
  unmanaged,

  /// 正在请求应用采用当前许可。
  applying,

  /// 应用已接受许可，由自身设置决定入口是否可见。
  allowed,

  /// 应用拒绝、超时或状态查询失败；保留许可供用户重试。
  failed,

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
/// managed 或 allowed，失败保留用户许可。按项目串行请求，旧会话或旧选择的
/// 确认不能覆盖最新选择；真正的断连归还由应用/SDK 侧执行。
class EntryHandoffCoordinator {
  EntryHandoffCoordinator({
    required this._server,
    required this._preferences,
    required this._statusQuery,
    this._requestTimeout = const Duration(seconds: 30),
    this._releaseTimeout = const Duration(milliseconds: 500),
  }) {
    _subscription = _server.registry.changes.listen(_onRegistryChange);
    for (final project in _server.registry.connected) {
      _onConnected(project);
    }
  }

  final LauncherServer _server;
  final PreferenceStore _preferences;
  final Future<bool> Function(String projectId) _statusQuery;
  final Duration _requestTimeout;
  final Duration _releaseTimeout;

  final _states = StreamController<HandoffState>.broadcast();
  final _statusByProject = <String, EntryHandoffStatus>{};

  /// Includes pending/failed hides: a lost acknowledgement can still hide entry.
  final _sessions = <String, String>{};
  final _revisions = <String, int>{};
  final _pendingRequests = <String, Future<void>>{};
  late final StreamSubscription<ConnectedProject?> _subscription;
  var _disposed = false;
  var _shuttingDown = false;

  /// 状态流，供 UI 集成。
  Stream<HandoffState> get states => _states.stream;

  EntryHandoffStatus statusOf(String projectId) =>
      _statusByProject[projectId] ?? EntryHandoffStatus.unmanaged;

  void _onRegistryChange(ConnectedProject? project) {
    if (_disposed) return;
    // 先对账：已断开或会话已替换的项目清除 managed（归还由应用侧执行）。
    final gone = <String>[];
    _sessions.forEach((projectId, sessionId) {
      final current = _server.registry.byProject(projectId);
      if (current == null || current.launcherSessionId != sessionId) {
        gone.add(projectId);
      }
    });
    for (final projectId in gone) {
      _sessions.remove(projectId);
      _invalidate(projectId);
      _emit(projectId, EntryHandoffStatus.unmanaged);
    }
    if (project != null) _onConnected(project);
  }

  void _onConnected(ConnectedProject project) {
    if (_shuttingDown) return;
    final projectId = project.projectId;
    if (_sessions[projectId] == project.launcherSessionId) return;
    _sessions[projectId] = project.launcherSessionId;
    unawaited(retry(projectId));
  }

  int _invalidate(String projectId) =>
      _revisions[projectId] = (_revisions[projectId] ?? 0) + 1;

  /// Save first, then apply online; an offline selection is applied on reconnect.
  Future<void> setMenuBarAllowed(String projectId, bool allowed) async {
    final revision = _invalidate(projectId);
    try {
      final save = _preferences.setMenuBarAllowed(projectId, allowed);
      _emit(
        projectId,
        _server.registry.isActive(projectId)
            ? EntryHandoffStatus.applying
            : EntryHandoffStatus.unmanaged,
      );
      await save;
    } catch (_) {
      if (_revisions[projectId] == revision) {
        _emit(projectId, EntryHandoffStatus.failed);
      }
      rethrow;
    }
    if (_revisions[projectId] == revision && !_disposed) {
      await _queueApply(projectId, revision);
    }
  }

  Future<void> retry(String projectId) =>
      _queueApply(projectId, _invalidate(projectId));

  Future<void> _queueApply(String projectId, int revision) {
    final project = _server.registry.byProject(projectId);
    if (project == null) {
      _emit(projectId, EntryHandoffStatus.unmanaged);
      return Future.value();
    }
    if (!project.capabilities.supportsApp(kMethodSetEntryManaged)) {
      _emit(projectId, EntryHandoffStatus.notManageable);
      return Future.value();
    }
    _emit(projectId, EntryHandoffStatus.applying);
    final previous = _pendingRequests[projectId] ?? Future.value();
    final request = previous.then((_) => _apply(project, revision));
    _pendingRequests[projectId] = request;
    unawaited(
      request.whenComplete(() {
        if (identical(_pendingRequests[projectId], request)) {
          _pendingRequests.remove(projectId);
        }
      }),
    );
    return request;
  }

  Future<void> _apply(ConnectedProject project, int revision) async {
    final projectId = project.projectId;
    final sessionId = project.launcherSessionId;

    bool current() {
      final now = _server.registry.byProject(projectId);
      return !_disposed &&
          _sessions[projectId] == sessionId &&
          _revisions[projectId] == revision &&
          now != null &&
          now.launcherSessionId == sessionId;
    }

    if (!current()) return;
    try {
      // 先完成登记后的初始状态查询，再请求接管。
      final ready = await _statusQuery(projectId);
      if (!current()) return;
      if (!ready) {
        _emit(projectId, EntryHandoffStatus.failed);
        return;
      }

      final session = _server.sessionFor(projectId);
      if (session == null || session.launcherSessionId != sessionId) return;

      final allowed = _preferences.isMenuBarAllowed(projectId);
      final response = await session.sendRequest(
        kMethodSetEntryManaged,
        params: {'managed': !allowed},
        timeout: _requestTimeout,
      );
      // 旧会话的应答不能标记新会话。
      if (!current()) return;
      final result = response['result'];
      if (result is Map<String, Object?> && result['confirmed'] == true) {
        _emit(
          projectId,
          allowed ? EntryHandoffStatus.allowed : EntryHandoffStatus.managed,
        );
      } else {
        // 确认失败：保留/恢复原入口，允许短暂双入口。
        _emit(projectId, EntryHandoffStatus.failed);
      }
    } catch (_) {
      // 保留选择，只有用户重试或重连才重发。
      if (current()) {
        _emit(projectId, EntryHandoffStatus.failed);
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

  /// 正常退出路径：并行归还在线入口，包含可能已经隐藏的未确认请求。
  ///
  /// 失败被吞掉——应用/SDK 侧心跳归还是兜底。永不发送 recycle。
  Future<void> releaseAll() async {
    _shuttingDown = true;
    await Future.wait(_sessions.keys.toList().map(release));
  }

  /// 解除绑定路径：尽力归还单个项目的统一入口。
  ///
  /// 只触碰当前支持入口协作的会话；项目不在线时是 no-op。失败被吞掉，
  /// 不阻塞解绑——应用/SDK 侧心跳归还是兜底。永不发送 recycle。
  Future<void> release(String projectId) async {
    _invalidate(projectId);
    final sessionId = _sessions.remove(projectId);
    if (sessionId == null) return;
    await _release(projectId, sessionId);
  }

  Future<void> _release(String projectId, String sessionId) async {
    _emit(projectId, EntryHandoffStatus.unmanaged);
    final session = _server.sessionFor(projectId);
    if (session == null || session.launcherSessionId != sessionId) {
      return;
    }
    if (!session.project!.capabilities.supportsApp(kMethodSetEntryManaged)) {
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
