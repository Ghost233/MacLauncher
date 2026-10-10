import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:launcher_core/launcher_core.dart';
import 'package:maclauncher_sdk/maclauncher_sdk.dart';

import 'live_debug.dart';
import 'pending_section.dart';
import 'project_card.dart';
import 'self_update_dialog.dart';
import 'self_update_flow.dart';
import 'settings_page.dart';
import 'theme.dart';

/// Resolves the launcher's own version from the existing build channel: the
/// macOS bundle's Info.plist, which `flutter build` populates from the
/// pubspec `version` (CFBundleShortVersionString/CFBundleVersion). An
/// `--dart-define=APP_VERSION=…` override wins for development builds.
/// Returns null when neither channel is available (e.g. tests).
Future<String?> _resolveCurrentVersion() async {
  const override = String.fromEnvironment('APP_VERSION');
  if (override.isNotEmpty) return override;
  try {
    return await const MethodChannel('maclauncher/native')
        .invokeMethod<String>('appVersion');
  } catch (_) {
    return null;
  }
}

/// Relaunches the launcher through the native channel: macOS `open -n` on
/// the bundle, then terminate this process. Returns null once initiated.
Future<String?> _relaunchViaNativeChannel() async {
  try {
    await const MethodChannel('maclauncher/native')
        .invokeMethod<void>('relaunch');
    return null;
  } on PlatformException catch (e) {
    return e.message ?? '重启失败。';
  } catch (e) {
    return '$e';
  }
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  registerLiveDebugExtensions();
  final layout = EndpointLayout.forUser();
  final bindings = await BindingStore.load('${layout.directory}/bindings.json');
  final prefs = await PreferenceStore.load(
    '${layout.directory}/preferences.json',
  );
  final refresher = await ConfigRefresher.load(
    bindings,
    '${layout.directory}/config_state.json',
    prunePreferences: (projectId, removedServiceIds) async {
      for (final serviceId in removedServiceIds) {
        await prefs.setLoginStartEnabled(projectId, serviceId, false);
      }
    },
  );

  LauncherServer? server;
  ServiceOperations? operations;
  EntryHandoffCoordinator? handoff;
  UnbindFlow? unbindFlow;
  Object? error;
  // Runtime self-discovery (#45): unknown handshakes land in this in-memory
  // registry as 待批准 unless the project is bound or ignored.
  final pending = PendingRegistry();
  final approval = DiscoveryApproval(bindings: bindings, pending: pending);
  try {
    server = await LauncherServer.start(
      layout: layout,
      bindings: bindings,
      discovery: DiscoveryConfig(
        pending: pending,
        isIgnored: prefs.ignoredDiscoveryProjects.contains,
        peerProbe: () => probePeerProcessPath(layout.socketPath),
      ),
      runtimeSync: RuntimeBindingSync(bindings: bindings, refresher: refresher),
    );
    final orchestrator = LaunchOrchestrator(server: server, store: bindings);
    operations = ServiceOperations(
      server: server,
      scope: BindingServiceScope(bindings),
      launcher: orchestrator,
    );
    final ops = operations;
    handoff = EntryHandoffCoordinator(
      server: server,
      preferences: prefs,
      statusQuery: (projectId) async {
        final project = server!.registry.byProject(projectId);
        if (project != null) {
          for (final service in project.capabilities.services) {
            if (service.supports(kMethodStatus)) {
              await ops.status(projectId, service.id);
            }
          }
        }
        return true;
      },
    );
    await refresher.refreshAll();
    unbindFlow = UnbindFlow(
      bindings: bindings,
      preferences: prefs,
      refresher: refresher,
      handoff: handoff,
      server: server,
    );
    await AutostartNotifier(preferences: prefs)
        .runOnce(bindings: bindings, startService: operations.start);
  } catch (e) {
    error = e;
  }

  final selfUpdateFlow = SelfUpdateFlow(
    preferences: prefs,
    service: SelfUpdateService(
      layout: layout,
      versionResolver: _resolveCurrentVersion,
    ),
    relauncher: _relaunchViaNativeChannel,
  );

  // Damage found while loading the three local stores, aggregated so the
  // page can surface one startup notice (#42).
  final corruptionReports = [
    bindings.corruptionReport,
    prefs.corruptionReport,
    refresher.corruptionReport,
  ].whereType<StorageCorruptionReport>().toList();

  const MethodChannel('maclauncher/native').setMethodCallHandler((call) async {
    if (call.method != 'prepareToQuit') throw MissingPluginException();
    try {
      await handoff?.releaseAll();
    } finally {
      await server?.close();
    }
    return null;
  });

  runApp(
    MacLauncherApp(
      server: server,
      serverError: error,
      bindings: bindings,
      preferences: prefs,
      refresher: refresher,
      operations: operations,
      handoff: handoff,
      unbindFlow: unbindFlow,
      pending: pending,
      approval: approval,
      updateService: AppUpdateService(layout: layout),
      selfUpdateFlow: selfUpdateFlow,
      corruptionReports: corruptionReports,
    ),
  );
}

class MacLauncherApp extends StatelessWidget {
  const MacLauncherApp({
    super.key,
    required this.bindings,
    required this.preferences,
    required this.refresher,
    this.server,
    this.serverError,
    this.operations,
    this.handoff,
    this.unbindFlow,
    this.pending,
    this.approval,
    this.updateService,
    this.selfUpdateFlow,
    this.corruptionReports = const [],
  });

  final LauncherServer? server;
  final Object? serverError;
  final BindingStore bindings;
  final PreferenceStore preferences;
  final ConfigRefresher refresher;
  final ServiceOperations? operations;
  final EntryHandoffCoordinator? handoff;
  final UnbindFlow? unbindFlow;

  /// 待批准注册表与批准编排（#45 运行时发现）；缺省（测试）时待批准区
  /// 不渲染。
  final PendingRegistry? pending;
  final DiscoveryApproval? approval;
  final AppUpdateService? updateService;
  final SelfUpdateFlow? selfUpdateFlow;

  /// Damage found while loading the local stores; surfaced once at startup.
  final List<StorageCorruptionReport> corruptionReports;

  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'Ghost Launcher',
    debugShowCheckedModeBanner: false,
    theme: AppTheme.material(),
    home: ManagementPage(
      server: server,
      serverError: serverError,
      bindings: bindings,
      preferences: preferences,
      refresher: refresher,
      operations: operations,
      handoff: handoff,
      unbindFlow: unbindFlow,
      pending: pending,
      approval: approval,
      updateService: updateService,
      selfUpdateFlow: selfUpdateFlow,
      corruptionReports: corruptionReports,
    ),
  );
}

/// The optional management window: project bindings, live connections,
/// per-service operations, handoff state and configuration health.
class ManagementPage extends StatefulWidget {
  const ManagementPage({
    super.key,
    required this.bindings,
    required this.preferences,
    required this.refresher,
    this.server,
    this.serverError,
    this.operations,
    this.handoff,
    this.unbindFlow,
    this.pending,
    this.approval,
    this.updateService,
    this.selfUpdateFlow,
    this.corruptionReports = const [],
  });

  final LauncherServer? server;
  final Object? serverError;
  final BindingStore bindings;
  final PreferenceStore preferences;
  final ConfigRefresher refresher;
  final ServiceOperations? operations;
  final EntryHandoffCoordinator? handoff;
  final UnbindFlow? unbindFlow;
  final PendingRegistry? pending;
  final DiscoveryApproval? approval;
  final AppUpdateService? updateService;
  final SelfUpdateFlow? selfUpdateFlow;
  final List<StorageCorruptionReport> corruptionReports;

  @override
  State<ManagementPage> createState() => _ManagementPageState();
}

class _ManagementPageState extends State<ManagementPage> {
  static const _native = MethodChannel('maclauncher/native');

  StreamSubscription<ConnectedProject?>? _registrySub;
  StreamSubscription<HandoffState>? _handoffSub;
  StreamSubscription<List<PendingProject>>? _pendingSub;
  final Map<String, EntryHandoffStatus> _handoffStatus = {};
  String _loginItemStatus = 'unknown';
  bool _corruptionNoticeShown = false;

  @override
  void initState() {
    super.initState();
    // One aggregated notice per launch for damaged local storage (#42).
    if (widget.corruptionReports.isNotEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && !_corruptionNoticeShown) {
          _corruptionNoticeShown = true;
          _showCorruptionNotice();
        }
      });
    }
    _registrySub = widget.server?.registry.changes.listen((_) {
      if (mounted) setState(() {});
    });
    final pending = widget.pending;
    if (pending != null) {
      _pendingSub = pending.changes.listen((_) {
        if (mounted) setState(() {});
        _syncPendingMenuHint();
      });
      _syncPendingMenuHint();
    }
    final handoff = widget.handoff;
    if (handoff != null) {
      _handoffSub = handoff.states.listen((state) {
        if (mounted) {
          setState(() => _handoffStatus[state.projectId] = state.status);
        }
      });
    }
    _loadLoginItemStatus();
    final flow = widget.selfUpdateFlow;
    if (flow != null) {
      flow.addListener(_syncSelfUpdateDialog);
      // Silent launch-time check (「启动时检查」偏好控制); failures stay
      // silent by design (issue #31).
      unawaited(flow.checkOnLaunch());
    }
  }

  bool _selfUpdateDialogOpen = false;

  /// Opens the self-update dialog when the flow leaves idle; the dialog
  /// itself follows state transitions and pops when the flow settles.
  void _syncSelfUpdateDialog() {
    final flow = widget.selfUpdateFlow;
    if (flow == null || _selfUpdateDialogOpen || !mounted) return;
    if (flow.state is SelfUpdateIdle) return;
    _selfUpdateDialogOpen = true;
    unawaited(
      showSelfUpdateDialog(context, flow).whenComplete(() {
        _selfUpdateDialogOpen = false;
        // A new state may have arrived while the dialog was closing.
        _syncSelfUpdateDialog();
      }),
    );
  }

  @override
  void dispose() {
    widget.selfUpdateFlow?.removeListener(_syncSelfUpdateDialog);
    _registrySub?.cancel();
    _handoffSub?.cancel();
    _pendingSub?.cancel();
    super.dispose();
  }

  /// 菜单栏最小提示（#49）：有待批准时托盘菜单顶部出现一行说明。
  /// 通道缺失（测试）时静默。
  void _syncPendingMenuHint() {
    final count = widget.pending?.projects.length ?? 0;
    unawaited(
      _native
          .invokeMethod<void>('setPendingDiscoveryCount', count)
          .catchError((_) {}),
    );
  }

  EntryHandoffStatus handoffStatusOf(String projectId) =>
      _handoffStatus[projectId] ??
      widget.handoff?.statusOf(projectId) ??
      EntryHandoffStatus.unmanaged;

  Future<void> _setMenuBarAllowed(String projectId, bool allowed) async {
    try {
      final handoff = widget.handoff;
      if (handoff == null) {
        await widget.preferences.setMenuBarAllowed(projectId, allowed);
      } else {
        await handoff.setMenuBarAllowed(projectId, allowed);
      }
    } catch (error) {
      if (mounted) _toast('菜单栏许可保存失败：$error');
    }
    if (mounted) setState(() {});
  }

  void _showCorruptionNotice() {
    final lines = [
      '检测到本机存储文件损坏，已按以下方式恢复：',
      for (final report in widget.corruptionReports) ...[
        if (report.backupPath != null)
          '· 「${_basename(report.filePath)}」已损坏，原文件已备份为'
              '「${_basename(report.backupPath!)}」，按空集合启动。',
        if (report.skippedRecords > 0)
          '· 「${_basename(report.filePath)}」有 ${report.skippedRecords} '
              '条无效记录，已跳过并保留其余记录。',
      ],
    ].join('\n');
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(lines), duration: const Duration(seconds: 5)),
    );
  }

  static String _basename(String path) =>
      path.replaceAll('\\', '/').split('/').last;

  Future<void> _loadLoginItemStatus() async {
    try {
      final status = await _native.invokeMethod<String>('loginItemStatus');
      if (mounted && status != null) {
        setState(() => _loginItemStatus = status);
      }
    } catch (_) {
      // Channel unavailable (tests, or before the window attaches).
    }
  }

  Future<void> _toggleLoginItem() async {
    try {
      final enable = _loginItemStatus != 'enabled';
      await _native.invokeMethod<void>('setLoginItemEnabled', enable);
    } on PlatformException catch (e) {
      if (mounted) _toast('登录项操作失败：${e.message}');
    } catch (_) {
      // Channel unavailable.
    }
    await _loadLoginItemStatus();
    if (mounted && _loginItemStatus == 'requiresApproval') {
      _toast('需要批准：系统设置 → 通用 → 登录项与扩展');
    }
  }

  String get _loginItemLabel => switch (_loginItemStatus) {
    'enabled' => '登录项：已启用',
    'requiresApproval' => '登录项：需在系统设置批准',
    'notRegistered' => '登录项：未注册',
    'notFound' => '登录项：不可用',
    _ => '登录项：状态未知',
  };

  Future<void> _associate() async {
    String? path;
    try {
      path = await _native.invokeMethod<String>('pickManifest');
    } catch (_) {
      return;
    }
    if (path == null || !mounted) return;
    try {
      final flow = AssociationFlow(widget.bindings);
      final result = await flow.associate(path);
      if (!mounted) return;
      switch (result) {
        case AssociationCreated():
          setState(() {});
        case AssociationReused():
          _toast('该配置已关联，复用原记录。');
        case AssociationConflict():
          await _resolveConflict(flow, result);
      }
    } on ManifestException catch (e) {
      if (!mounted) return;
      await _alert('无法关联项目配置', '具体原因：${e.reason}\n${e.detail}');
    }
  }

  /// Repair-oriented entry on an invalid card (issue #43): the user picks
  /// the project's configuration again. Conflicts surface with recovery
  /// wording instead of association-conflict wording.
  Future<void> _reselectConfig(String projectId) async {
    String? path;
    try {
      path = await _native.invokeMethod<String>('pickManifest');
    } catch (_) {
      return;
    }
    if (path == null || !mounted) return;
    try {
      final flow = AssociationFlow(widget.bindings);
      final result = await flow.associate(path);
      if (!mounted) return;
      switch (result) {
        case AssociationCreated():
          setState(() {});
        case AssociationReused():
          _toast('该配置已关联，复用原记录。');
        case AssociationConflict():
          await _resolveConflict(flow, result, repair: true);
      }
      // Whatever the user picked, re-check the invalid project so a
      // successful repair recovers the card immediately.
      if (mounted) await _refreshConfig(projectId);
    } on ManifestException catch (e) {
      if (!mounted) return;
      await _alert('无法找回项目配置', '具体原因：${e.reason}\n${e.detail}');
    }
  }

  Future<void> _resolveConflict(
    AssociationFlow flow,
    AssociationConflict conflict, {
    bool repair = false,
  }) async {
    final existing = conflict.existingBinding;
    // 「作为新项目」的效果只有语境差别：修复语境指向失效项目本身，关联
    // 语境指向进入的配置。
    final asNewProject = repair ? '作为新项目会为它生成新的项目身份。' : '作为新项目会为进入的配置生成新的项目身份。';
    // runtime 绑定没有配置文件路径，决策点③仍走这个冲突弹窗。
    final existingLocation = existing.manifestPath != null
        ? '另一路径：\n${existing.manifestPath}\n'
        : '（运行时自发现关联，无配置文件）\n';
    final message = switch (conflict.kind) {
      AssociationConflictKind.identityBoundToOtherPath =>
        repair
            ? '这份配置与失效的项目是同一身份（原路径：\n${existing.manifestPath}\n）。\n\n'
                  '迁移原绑定会把绑定（含偏好）移到新路径，找回配置；'
                  '$asNewProject'
            : '相同的项目身份已在$existingLocation\n'
                  '迁移会把原绑定（含偏好）移到新路径；$asNewProject',
      AssociationConflictKind.pathBoundToOtherIdentity =>
        repair
            ? '该路径已绑定到另一个项目身份：\n${existing.projectId}\n\n'
                  '所选配置无法用于找回失效的项目；$asNewProject'
            : '该路径已绑定到另一个项目身份：\n${existing.projectId}\n\n'
                  '迁移会把绑定更新为进入配置的身份；$asNewProject',
    };
    final choice = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(repair ? '找回项目配置' : '项目身份冲突'),
        content: Text(message),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop('cancel'),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop('new'),
            child: const Text('作为新项目'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop('migrate'),
            child: const Text('迁移原绑定'),
          ),
        ],
      ),
    );
    if (!mounted || choice == null || choice == 'cancel') return;
    try {
      if (choice == 'migrate') {
        await flow.migrateBinding(
          existing.projectId,
          conflict.incomingManifestPath,
        );
      } else {
        await flow.associateAsNewProject(conflict.incomingManifestPath);
      }
      setState(() {});
    } on ManifestException catch (e) {
      await _alert('无法完成操作', '具体原因：${e.reason}\n${e.detail}');
    }
  }

  Future<void> _refreshConfig(String projectId) async {
    final result = await widget.refresher.refresh(projectId);
    if (!mounted) return;
    setState(() {});
    switch (result) {
      case RefreshApplied(:final added, :final removed):
        _toast('配置已刷新：新增 ${added.length} 项，移除 ${removed.length} 项。');
      case RefreshUnchanged():
        _toast('配置无变化。');
      case RefreshInvalid(:final reason, :final detail):
        _toast('配置失效：$reason（$detail），已保留绑定并暂停新启动。');
      case RefreshIdentityMismatch(:final declaredProjectId):
        _toast('配置身份变为 $declaredProjectId，请通过关联流程迁移或新建项目。');
      case RefreshNotBound():
        _toast('该配置已解除绑定。');
    }
  }

  /// retained 只读记录的逐条清除：持久化编排在页面层（E05 界面边界），
  /// 落盘失败给出提示而不是成为未捕获异常。
  Future<void> _clearRetained(String projectId, String serviceId) async {
    try {
      await widget.refresher.removeRetained(projectId, serviceId);
    } catch (e) {
      if (!mounted) return;
      await _alert('清除保留记录失败', '$e');
      return;
    }
    if (!mounted) return;
    setState(() {});
  }

  /// 批准待批准项目（#45）：确认对话框核对身份与来源；无 entry 时注明
  /// 仅观察与回收（决策点1）。落库由 DiscoveryApproval 编排（entry 校验、
  /// 失败保留 pending），页面只给提示。
  Future<void> _approve(PendingProject project) async {
    final approval = widget.approval;
    if (approval == null) return;
    final entry = project.entry;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('批准关联'),
        content: Text(
          '批准「${project.displayName}」（${project.projectId}）与启动器关联？\n\n'
          '来源进程：${project.sourceProcessPath ?? '未知'}\n'
          '入口：${entry?.path ?? '无'}'
          '${entry == null ? '\n\n该应用未自报入口：启动器将不能拉起该应用，仅可观察与回收。' : ''}',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('批准'),
          ),
        ],
      ),
    );
    if (!mounted || confirmed != true) return;
    try {
      await approval.approve(project.projectId);
      if (!mounted) return;
      setState(() {});
      _toast('已批准关联：${project.displayName}');
    } on DiscoveryApprovalException catch (e) {
      if (!mounted) return;
      await _alert('无法批准关联', e.detail);
    } catch (e) {
      if (!mounted) return;
      await _alert('无法批准关联', '$e');
    }
  }

  /// 忽略待批准项目：加入忽略列表（持久化）并从注册表移除；此后的握手
  /// 静默拒绝，不再出现在待批准区，直到设置页恢复。
  Future<void> _ignore(PendingProject project) async {
    try {
      await widget.preferences.setDiscoveryIgnored(project.projectId, true);
    } catch (e) {
      if (!mounted) return;
      await _alert('忽略失败', '$e');
      return;
    }
    widget.pending?.remove(project.projectId);
    if (!mounted) return;
    setState(() {});
    _toast('已忽略「${project.displayName}」，可在设置中恢复。');
  }

  /// 解除绑定：确认对话框只有一个动作——「保留运行并解除绑定」。
  /// 固定说明文案 + 动态影响摘要（docs/design.md 锚点）；取消后一切不变。
  Future<void> _unbind(ProjectBinding binding) async {
    final flow = widget.unbindFlow;
    if (flow == null) return;
    final preferenceCount = widget.preferences
        .enabledServices(binding.projectId)
        .length;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('解除项目绑定'),
        content: Text(
          '取消该项目的登录启动通知，归还原菜单栏入口。\n'
          '应用已有业务和日志继续由它自己维护。\n\n'
          '将清除 $preferenceCount 项登录启动偏好。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: AppTheme.danger,
              foregroundColor: Colors.white,
            ),
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('保留运行并解除绑定'),
          ),
        ],
      ),
    );
    if (!mounted || confirmed != true) return;
    try {
      await flow.unbind(binding.projectId);
      if (!mounted) return;
      setState(() => _handoffStatus.remove(binding.projectId));
      _toast('已解除绑定。');
    } catch (e) {
      if (!mounted) return;
      await _alert('解除绑定失败', '$e');
    }
  }

  void _toast(String message) {
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }

  /// The invalid-config explainer appears once ever (flag persisted in the
  /// preference store) plus at most once per page state, so rebuilds and
  /// refreshes never nag (issue #43).
  bool _invalidGuidanceShown = false;

  void _maybeShowInvalidGuidance() {
    if (_invalidGuidanceShown || widget.preferences.invalidConfigGuidanceSeen) {
      return;
    }
    final hasInvalid = widget.bindings.bindings.any(
      (b) => widget.refresher.invalidReason(b.projectId) != null,
    );
    if (!hasInvalid) return;
    _invalidGuidanceShown = true;
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted) return;
      await showDialog<void>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('配置失效说明'),
          content: const Text(
            '配置失效指绑定记录中的配置文件缺失、不可读或内容不再合法'
            '（例如项目目录被移动、重命名或删除）。\n\n'
            '失效只暂停新的启动与通知：绑定、登录启动偏好与运行记录都会保留，'
            '数据不会丢。你可以重新选择配置完成修复，或解除绑定放弃。\n\n'
            '此说明只出现一次。',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('知道了'),
            ),
          ],
        ),
      );
      await widget.preferences.markInvalidConfigGuidanceSeen();
    });
  }

  void _openSettings() {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (context) => SettingsPage(
          preferences: widget.preferences,
          selfUpdate: widget.selfUpdateFlow,
          // Fallback when no self-update flow is wired (tests): the
          // placeholder seam from #32.
          onCheckNow: () async => _toast('更新检查将在后续版本接入。'),
        ),
      ),
    );
  }

  Future<void> _alert(String title, String message) => showDialog<void>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(title),
      content: Text(message),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('知道了'),
        ),
      ],
    ),
  );

  @override
  Widget build(BuildContext context) {
    final registry = widget.server?.registry;
    final bindings = widget.bindings.bindings;
    final pendingProjects =
        widget.pending?.projects ?? const <PendingProject>[];
    _maybeShowInvalidGuidance();
    return Scaffold(
      appBar: AppBar(
        title: const Text('Ghost Launcher 管理'),
        actions: [
          _LoginItemButton(
            label: _loginItemLabel,
            status: _loginItemStatus,
            onPressed: _toggleLoginItem,
          ),
          const SizedBox(width: AppTheme.gapMd),
          FilledButton.tonalIcon(
            onPressed: _associate,
            icon: const Icon(Icons.link, size: 16),
            label: const Text('关联项目'),
            style: FilledButton.styleFrom(
              backgroundColor: AppTheme.accentSoft,
              foregroundColor: AppTheme.accent,
              textStyle: const TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w500,
              ),
              minimumSize: const Size(0, 34),
              padding: const EdgeInsets.symmetric(horizontal: 14),
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            ),
          ),
          const SizedBox(width: AppTheme.gapMd),
          IconButton(
            tooltip: '设置',
            onPressed: _openSettings,
            icon: const Icon(Icons.settings_outlined),
          ),
          const SizedBox(width: AppTheme.gapMd),
        ],
      ),
      body: widget.serverError != null
          ? Center(
              child: Padding(
                padding: const EdgeInsets.all(AppTheme.gapXl),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(
                      Icons.error_outline_rounded,
                      size: 32,
                      color: AppTheme.danger,
                    ),
                    const SizedBox(height: AppTheme.gapMd),
                    SelectableText(
                      '监听端点启动失败：${widget.serverError}',
                      textAlign: TextAlign.center,
                      style: AppTheme.caption,
                    ),
                  ],
                ),
              ),
            )
          : bindings.isEmpty && pendingProjects.isEmpty
          ? Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(
                    Icons.link_off_rounded,
                    size: 32,
                    color: AppTheme.textTertiary,
                  ),
                  const SizedBox(height: AppTheme.gapMd),
                  const Text(
                    '尚未关联任何项目。\n点击右上角「关联项目」，选择项目目录中的 maclauncher.json。',
                    textAlign: TextAlign.center,
                    style: AppTheme.caption,
                  ),
                ],
              ),
            )
          : ListView(
              padding: AppTheme.pagePadding(context),
              children: [
                PendingSection(
                  projects: pendingProjects,
                  onApprove: _approve,
                  onIgnore: _ignore,
                ),
                for (final binding in bindings)
                  Padding(
                    padding: const EdgeInsets.only(bottom: AppTheme.gapLg),
                    child: ProjectCard(
                      binding: binding,
                      registry: registry,
                      operations: widget.operations,
                      updateService: widget.updateService,
                      preferences: widget.preferences,
                      refresher: widget.refresher,
                      handoffStatus: handoffStatusOf(binding.projectId),
                      onMenuBarAllowedChanged: (allowed) => unawaited(
                        _setMenuBarAllowed(binding.projectId, allowed),
                      ),
                      onRetryMenuBar: widget.handoff == null
                          ? null
                          : () => unawaited(
                              widget.handoff!.retry(binding.projectId),
                            ),
                      onOpenWindow: () async {
                        final handoff = widget.handoff;
                        if (handoff == null) return;
                        final outcome = await handoff.openWindow(
                          binding.projectId,
                        );
                        if (!context.mounted) return;
                        _toast(switch (outcome) {
                          HandoffRequestOutcome.acknowledged => '已请求应用打开原窗口。',
                          HandoffRequestOutcome.unsupported => '应用未提供打开窗口能力。',
                          HandoffRequestOutcome.unavailable => '应用未连接。',
                          HandoffRequestOutcome.unknown => '结果未知：等待超时。',
                        });
                      },
                      onRefreshConfig: () => _refreshConfig(binding.projectId),
                      onReselectConfig: () =>
                          _reselectConfig(binding.projectId),
                      onUnbind: widget.unbindFlow == null
                          ? null
                          : () => _unbind(binding),
                      onClearRetained: (serviceId) =>
                          _clearRetained(binding.projectId, serviceId),
                      onChanged: () => setState(() {}),
                    ),
                  ),
              ],
            ),
    );
  }
}

/// App-bar login-item control: a colored status pill that toggles the login
/// item on tap. The label text comes verbatim from the page.
class _LoginItemButton extends StatelessWidget {
  const _LoginItemButton({
    required this.label,
    required this.status,
    required this.onPressed,
  });

  final String label;
  final String status;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final (color, background) = switch (status) {
      'enabled' => (AppTheme.ok, AppTheme.okSoft),
      'requiresApproval' => (AppTheme.warn, AppTheme.warnSoft),
      _ => (AppTheme.neutral, AppTheme.neutralSoft),
    };
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: InkWell(
        onTap: onPressed,
        borderRadius: BorderRadius.circular(999),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
          decoration: BoxDecoration(
            color: background,
            borderRadius: BorderRadius.circular(999),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.login_rounded, size: 13, color: color),
              const SizedBox(width: 5),
              Text(
                label,
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w500,
                  color: color,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
