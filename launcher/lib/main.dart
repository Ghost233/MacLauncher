import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:launcher_core/launcher_core.dart';
import 'package:maclauncher_sdk/maclauncher_sdk.dart';

import 'live_debug.dart';
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
  Object? error;
  try {
    server = await LauncherServer.start(layout: layout, bindings: bindings);
    final orchestrator = LaunchOrchestrator(server: server, store: bindings);
    operations = ServiceOperations(
      server: server,
      scope: BindingServiceScope(bindings),
      launcher: orchestrator,
    );
    final ops = operations;
    handoff = EntryHandoffCoordinator(
      server: server,
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

  runApp(
    MacLauncherApp(
      server: server,
      serverError: error,
      bindings: bindings,
      preferences: prefs,
      refresher: refresher,
      operations: operations,
      handoff: handoff,
      updateService: AppUpdateService(layout: layout),
      selfUpdateFlow: selfUpdateFlow,
      // Unbind entry for the invalid-config guidance (issue #43): wired to
      // UnbindFlow.unbind once issue #41 lands on the integration branch;
      // until then the card shows the entry disabled with a reason.
      onUnbindProject: null,
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
    this.updateService,
    this.selfUpdateFlow,
    this.onUnbindProject,
  });

  final LauncherServer? server;
  final Object? serverError;
  final BindingStore bindings;
  final PreferenceStore preferences;
  final ConfigRefresher refresher;
  final ServiceOperations? operations;
  final EntryHandoffCoordinator? handoff;
  final AppUpdateService? updateService;
  final SelfUpdateFlow? selfUpdateFlow;

  /// Unbind entry for the invalid-config guidance (issue #43). Null while
  /// issue #41's UnbindFlow is not wired; the UI then shows the entry
  /// disabled with a reason.
  final Future<void> Function(String projectId)? onUnbindProject;

  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'MacLauncher',
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
      updateService: updateService,
      selfUpdateFlow: selfUpdateFlow,
      onUnbindProject: onUnbindProject,
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
    this.updateService,
    this.selfUpdateFlow,
    this.onUnbindProject,
  });

  final LauncherServer? server;
  final Object? serverError;
  final BindingStore bindings;
  final PreferenceStore preferences;
  final ConfigRefresher refresher;
  final ServiceOperations? operations;
  final EntryHandoffCoordinator? handoff;
  final AppUpdateService? updateService;
  final SelfUpdateFlow? selfUpdateFlow;
  final Future<void> Function(String projectId)? onUnbindProject;

  @override
  State<ManagementPage> createState() => _ManagementPageState();
}

class _ManagementPageState extends State<ManagementPage> {
  static const _native = MethodChannel('maclauncher/native');

  StreamSubscription<ConnectedProject?>? _registrySub;
  StreamSubscription<HandoffState>? _handoffSub;
  final Map<String, EntryHandoffStatus> _handoffStatus = {};
  String _loginItemStatus = 'unknown';

  @override
  void initState() {
    super.initState();
    _registrySub = widget.server?.registry.changes.listen((_) {
      if (mounted) setState(() {});
    });
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
    super.dispose();
  }

  EntryHandoffStatus handoffStatusOf(String projectId) =>
      _handoffStatus[projectId] ??
      widget.handoff?.statusOf(projectId) ??
      EntryHandoffStatus.unmanaged;

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
    final message = switch (conflict.kind) {
      AssociationConflictKind.identityBoundToOtherPath =>
        repair
            ? '这份配置与失效的项目是同一身份（原路径：\n${existing.manifestPath}\n）。\n\n'
                  '迁移原绑定会把绑定（含偏好）移到新路径，找回配置；'
                  '作为新项目会为它生成新的项目身份。'
            : '相同的项目身份已在另一路径绑定：\n${existing.manifestPath}\n\n'
                  '迁移会把原绑定（含偏好）移到新路径；作为新项目会为进入的配置生成新的项目身份。',
      AssociationConflictKind.pathBoundToOtherIdentity =>
        repair
            ? '该路径已绑定到另一个项目身份：\n${existing.projectId}\n\n'
                  '所选配置无法用于找回失效的项目；'
                  '作为新项目会为它生成新的项目身份。'
            : '该路径已绑定到另一个项目身份：\n${existing.projectId}\n\n'
                  '迁移会把绑定更新为进入配置的身份；作为新项目会为进入的配置生成新的项目身份。',
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

  /// Confirms, then delegates to the unbind entry wired by the app (issue
  /// #41's UnbindFlow once it lands).
  Future<void> _confirmUnbind(String projectId) async {
    final onUnbind = widget.onUnbindProject;
    if (onUnbind == null) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('解除绑定'),
        content: const Text(
          '解除绑定会移除该项目的绑定与登录启动偏好；'
          '正在运行的实例继续运行，运行记录保留。'
          '该项目之后可以再次关联。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            style: FilledButton.styleFrom(
              backgroundColor: AppTheme.dangerSoft,
              foregroundColor: AppTheme.danger,
            ),
            child: const Text('解除绑定'),
          ),
        ],
      ),
    );
    if (!mounted || confirmed != true) return;
    try {
      await onUnbind(projectId);
      if (!mounted) return;
      _toast('已解除绑定。');
      setState(() {});
    } catch (e) {
      if (!mounted) return;
      _toast('解除绑定失败：$e');
    }
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
    _maybeShowInvalidGuidance();
    return Scaffold(
      appBar: AppBar(
        title: const Text('MacLauncher 管理'),
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
          : bindings.isEmpty
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
          : Align(
              alignment: Alignment.topCenter,
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 860),
                child: ListView(
                  padding: const EdgeInsets.all(AppTheme.gapLg),
                  children: [
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
                          onOpenWindow: () async {
                            final handoff = widget.handoff;
                            if (handoff == null) return;
                            final outcome = await handoff.openWindow(
                              binding.projectId,
                            );
                            if (!context.mounted) return;
                            _toast(switch (outcome) {
                              HandoffRequestOutcome.acknowledged =>
                                '已请求应用打开原窗口。',
                              HandoffRequestOutcome.unsupported =>
                                '应用未提供打开窗口能力。',
                              HandoffRequestOutcome.unavailable => '应用未连接。',
                              HandoffRequestOutcome.unknown => '结果未知：等待超时。',
                            });
                          },
                          onRefreshConfig: () =>
                              _refreshConfig(binding.projectId),
                          onReselectConfig: () =>
                              _reselectConfig(binding.projectId),
                          onUnbind: widget.onUnbindProject == null
                              ? null
                              : () => _confirmUnbind(binding.projectId),
                          onChanged: () => setState(() {}),
                        ),
                      ),
                  ],
                ),
              ),
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
