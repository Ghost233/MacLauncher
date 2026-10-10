import 'dart:async';

import 'package:flutter/material.dart';
import 'package:launcher_core/launcher_core.dart';
import 'package:maclauncher_sdk/maclauncher_sdk.dart';

import 'app_update_section.dart';
import 'log_panel.dart';
import 'theme.dart';

/// One bound project: connection, handoff state, configuration health and
/// its declared services.
class ProjectCard extends StatelessWidget {
  const ProjectCard({
    super.key,
    required this.binding,
    required this.preferences,
    required this.refresher,
    required this.handoffStatus,
    required this.onOpenWindow,
    required this.onRefreshConfig,
    required this.onReselectConfig,
    required this.onChanged,
    this.onClearRetained,
    this.onUnbind,
    this.registry,
    this.operations,
    this.updateService,
    this.onMenuBarAllowedChanged,
    this.onRetryMenuBar,
  });

  final ProjectBinding binding;
  final ConnectionRegistry? registry;
  final ServiceOperations? operations;
  final AppUpdateService? updateService;
  final PreferenceStore preferences;
  final ConfigRefresher refresher;
  final EntryHandoffStatus handoffStatus;
  final VoidCallback onOpenWindow;
  final VoidCallback onRefreshConfig;

  /// Repair entry of the invalid-config guidance (issue #43): pick the
  /// project's configuration again.
  final VoidCallback onReselectConfig;

  final VoidCallback onChanged;

  /// retained 只读记录的逐条清除入口；持久化编排（含失败提示）在页面层，
  /// 卡片只上抛意图（E05 界面边界）。
  final void Function(String serviceId)? onClearRetained;

  /// 解除绑定入口；为 null（启动器未就绪）时不显示。失效态引导框中的
  /// 「解除绑定…」共用此回调（issue #43），此时入口置灰并注明原因。
  final VoidCallback? onUnbind;
  final ValueChanged<bool>? onMenuBarAllowedChanged;
  final VoidCallback? onRetryMenuBar;

  @override
  Widget build(BuildContext context) {
    final connected = registry?.isActive(binding.projectId) ?? false;
    final capabilities = registry?.byProject(binding.projectId)?.capabilities;
    final canOpenWindow = capabilities?.supportsApp(kMethodOpenWindow) ?? false;
    final menuBarUnsupported =
        connected &&
        !(capabilities?.supportsApp(kMethodSetEntryManaged) ?? false);
    final invalid = refresher.invalidReason(binding.projectId);
    final retained = refresher.retainedServices(binding.projectId);
    // Runtime bindings (#45): the learned entry can vanish from disk while
    // the app is away. Surface it, never reclaim implicitly — the next run
    // self-heals the entry via hello.
    final learned = binding.learnedEntry;
    final entryInvalid =
        binding.origin == BindingOrigin.runtime && learned != null && !connected
        ? entryInvalidReason(learned)
        : null;
    return Container(
      decoration: AppTheme.cardDecoration(),
      child: Padding(
        padding: const EdgeInsets.all(AppTheme.gapLg),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            CardHeader(
              title: Text(binding.name, style: AppTheme.cardTitle),
              actions: [
                StatusPill(
                  label: connected ? '应用连接：已连接' : '应用连接：未连接',
                  color: connected ? AppTheme.ok : AppTheme.neutral,
                  background: connected
                      ? AppTheme.okSoft
                      : AppTheme.neutralSoft,
                ),
                StatusPill(
                  label: switch (handoffStatus) {
                    EntryHandoffStatus.managed => '统一入口：接管完成',
                    EntryHandoffStatus.unmanaged => '统一入口：未接管',
                    EntryHandoffStatus.notManageable => '应用保留自身入口',
                    EntryHandoffStatus.applying => '菜单栏：正在应用',
                    EntryHandoffStatus.allowed => '菜单栏：由应用决定',
                    EntryHandoffStatus.failed => '菜单栏：尚未应用',
                  },
                  color: switch (handoffStatus) {
                    EntryHandoffStatus.managed => AppTheme.accent,
                    EntryHandoffStatus.unmanaged => AppTheme.neutral,
                    EntryHandoffStatus.notManageable => AppTheme.neutral,
                    EntryHandoffStatus.applying => AppTheme.neutral,
                    EntryHandoffStatus.allowed => AppTheme.accent,
                    EntryHandoffStatus.failed => AppTheme.warn,
                  },
                  background: switch (handoffStatus) {
                    EntryHandoffStatus.managed => AppTheme.accentSoft,
                    EntryHandoffStatus.allowed => AppTheme.accentSoft,
                    EntryHandoffStatus.failed => AppTheme.warnSoft,
                    _ => AppTheme.neutralSoft,
                  },
                ),
                if (binding.origin == BindingOrigin.runtime) ...[
                  const StatusPill(
                    label: '运行时发现',
                    color: AppTheme.accent,
                    background: AppTheme.accentSoft,
                  ),
                ],
                if (canOpenWindow) ...[
                  TextButton.icon(
                    onPressed: onOpenWindow,
                    icon: const Icon(Icons.open_in_new, size: 14),
                    label: const Text('打开窗口'),
                  ),
                ],
                if (binding.origin == BindingOrigin.config)
                  IconButton(
                    tooltip: '刷新配置',
                    onPressed: onRefreshConfig,
                    icon: const Icon(Icons.sync),
                  ),
                if (onUnbind != null && invalid == null)
                  TextButton.icon(
                    onPressed: onUnbind,
                    icon: const Icon(Icons.link_off, size: 14),
                    label: const Text('解除绑定'),
                    style: TextButton.styleFrom(
                      foregroundColor: AppTheme.danger,
                      textStyle: const TextStyle(
                        fontSize: 12.5,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ),
              ],
            ),
            const SizedBox(height: AppTheme.gapXs),
            Text('项目标识：${binding.projectId}', style: AppTheme.monoMuted),
            if (onMenuBarAllowedChanged != null)
              Row(
                children: [
                  Expanded(
                    child: Material(
                      type: MaterialType.transparency,
                      child: SwitchListTile(
                        key: ValueKey('menu-bar-${binding.projectId}'),
                        contentPadding: EdgeInsets.zero,
                        title: const Text('允许应用显示菜单栏', style: AppTheme.body),
                        subtitle: Text(
                          menuBarUnsupported
                              ? '应用不支持菜单栏控制'
                              : !connected
                              ? '等待应用连接后应用'
                              : handoffStatus == EntryHandoffStatus.failed
                              ? '尚未应用，可重试。'
                              : '开启后由应用自身设置决定是否显示。',
                          style: AppTheme.captionMuted,
                        ),
                        value: preferences.isMenuBarAllowed(binding.projectId),
                        onChanged: menuBarUnsupported
                            ? null
                            : onMenuBarAllowedChanged,
                      ),
                    ),
                  ),
                  if (connected &&
                      !menuBarUnsupported &&
                      handoffStatus == EntryHandoffStatus.failed &&
                      onRetryMenuBar != null)
                    TextButton(
                      onPressed: onRetryMenuBar,
                      child: const Text('重试'),
                    ),
                ],
              ),
            if (entryInvalid != null)
              Padding(
                padding: const EdgeInsets.only(top: AppTheme.gapSm),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Icon(
                      Icons.warning_amber_rounded,
                      size: 14,
                      color: AppTheme.warn,
                    ),
                    const SizedBox(width: AppTheme.gapSm),
                    Expanded(
                      child: Text(
                        '入口失效：$entryInvalid。重新运行该应用即可自动修复。',
                        style: AppTheme.caption.copyWith(color: AppTheme.warn),
                      ),
                    ),
                  ],
                ),
              ),
            if (invalid != null)
              Container(
                margin: const EdgeInsets.only(top: AppTheme.gapMd),
                padding: const EdgeInsets.all(AppTheme.gapMd),
                decoration: BoxDecoration(
                  color: AppTheme.warnSoft,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(
                    color: AppTheme.warn.withValues(alpha: 0.35),
                  ),
                ),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Icon(
                      Icons.warning_amber_rounded,
                      size: 16,
                      color: AppTheme.warn,
                    ),
                    const SizedBox(width: AppTheme.gapSm),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            '配置失效：${invalid.reason}（${invalid.detail}）。'
                            '已保留绑定与运行记录，暂停新启动。',
                            style: AppTheme.caption.copyWith(
                              color: AppTheme.warn,
                            ),
                          ),
                          const SizedBox(height: AppTheme.gapSm),
                          const Text(
                            '两条出路：重新选择配置文件完成修复（绑定与偏好迁移'
                            '到新路径）；或解除绑定放弃，运行记录保留，项目'
                            '之后可再次关联。',
                            style: AppTheme.captionMuted,
                          ),
                          const SizedBox(height: AppTheme.gapSm),
                          Row(
                            children: [
                              FilledButton.tonalIcon(
                                onPressed: onReselectConfig,
                                icon: const Icon(
                                  Icons.file_open_outlined,
                                  size: 14,
                                ),
                                label: const Text('重新选择配置…'),
                                style: FilledButton.styleFrom(
                                  backgroundColor: AppTheme.accentSoft,
                                  foregroundColor: AppTheme.accent,
                                  textStyle: const TextStyle(
                                    fontSize: 12.5,
                                    fontWeight: FontWeight.w500,
                                  ),
                                  minimumSize: const Size(0, 30),
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 10,
                                  ),
                                  tapTargetSize:
                                      MaterialTapTargetSize.shrinkWrap,
                                ),
                              ),
                              const SizedBox(width: AppTheme.gapXs),
                              TextButton(
                                onPressed: onUnbind,
                                style: TextButton.styleFrom(
                                  foregroundColor: AppTheme.danger,
                                  disabledForegroundColor:
                                      AppTheme.textTertiary,
                                  textStyle: const TextStyle(
                                    fontSize: 12.5,
                                    fontWeight: FontWeight.w500,
                                  ),
                                  minimumSize: const Size(0, 30),
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 8,
                                  ),
                                  tapTargetSize:
                                      MaterialTapTargetSize.shrinkWrap,
                                ),
                                child: const Text('解除绑定…'),
                              ),
                              if (onUnbind == null) ...[
                                const SizedBox(width: AppTheme.gapXs),
                                const Expanded(
                                  child: Text(
                                    '解除绑定将在后续版本提供。',
                                    style: AppTheme.captionMuted,
                                  ),
                                ),
                              ],
                            ],
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            const Padding(
              padding: EdgeInsets.symmetric(vertical: AppTheme.gapMd),
              child: Divider(),
            ),
            for (final service in binding.services)
              ServiceRow(
                key: ValueKey('${binding.projectId}/${service.id}'),
                projectId: binding.projectId,
                service: service,
                registry: registry,
                operations: operations,
                preferences: preferences,
                onChanged: onChanged,
              ),
            for (final service in retained)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: AppTheme.gapXs),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Icon(
                      Icons.archive_outlined,
                      size: 14,
                      color: AppTheme.textTertiary,
                    ),
                    const SizedBox(width: AppTheme.gapSm),
                    Expanded(
                      child: Text(
                        '服务 ${service.name}（${service.id}）：声明已移除，'
                        '保留只读记录（移除于 ${service.removedAt.toLocal()}）；'
                        '不代表运行已终止。',
                        style: AppTheme.captionMuted,
                      ),
                    ),
                    TextButton(
                      onPressed: onClearRetained == null
                          ? null
                          : () => onClearRetained!(service.id),
                      style: TextButton.styleFrom(
                        foregroundColor: AppTheme.neutral,
                        textStyle: const TextStyle(fontSize: 12.5),
                        minimumSize: const Size(0, 28),
                        padding: const EdgeInsets.symmetric(horizontal: 8),
                        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      ),
                      child: const Text('清除'),
                    ),
                  ],
                ),
              ),
            // App-level version status + 代下载: every value comes from the
            // application's versionStatus answer; the section hides its
            // download entry until an update with a URL is reported.
            AppUpdateSection(
              key: ValueKey('${binding.projectId}/app-update'),
              projectId: binding.projectId,
              registry: registry,
              operations: operations,
              updateService: updateService,
            ),
          ],
        ),
      ),
    );
  }
}

/// One service: operations, login-start preference and an observer-driven
/// status display. Button taps never write business state directly; only
/// application-reported snapshots appear here.
class ServiceRow extends StatefulWidget {
  const ServiceRow({
    super.key,
    required this.projectId,
    required this.service,
    required this.preferences,
    required this.onChanged,
    this.registry,
    this.operations,
  });

  final String projectId;
  final ManifestService service;
  final ConnectionRegistry? registry;
  final ServiceOperations? operations;
  final PreferenceStore preferences;
  final VoidCallback onChanged;

  @override
  State<ServiceRow> createState() => _ServiceRowState();
}

class _ServiceRowState extends State<ServiceRow> {
  StatusObserver? _observer;
  StreamSubscription<ServiceViewState>? _observerSub;
  StreamSubscription<ConnectedProject?>? _registrySub;
  ServiceViewState? _view;
  String? _note;
  var _pending = false;

  bool get _connected => widget.registry?.isActive(widget.projectId) ?? false;

  @override
  void initState() {
    super.initState();
    final operations = widget.operations;
    if (operations != null) {
      final observer = StatusObserver(
        projectId: widget.projectId,
        serviceId: widget.service.id,
        operations: operations,
        isConnected: () => widget.registry?.isActive(widget.projectId) ?? false,
      );
      _observer = observer;
      _view = observer.current;
      _observerSub = observer.states.listen((state) {
        if (mounted) setState(() => _view = state);
      });
      // One observer per visible service: it runs while the app is
      // connected and stops on disconnect and dispose.
      if (_connected) observer.start();
    }
    _registrySub = widget.registry?.changes.listen((_) {
      if (_connected) {
        _observer?.start();
      } else {
        _observer?.stop();
      }
    });
  }

  @override
  void dispose() {
    _registrySub?.cancel();
    _observerSub?.cancel();
    _observer?.stop();
    _observer?.dispose();
    super.dispose();
  }

  void _requery() {
    // StatusObserver starts with an immediate query.
    _observer
      ?..stop()
      ..start();
  }

  Future<void> _change(
    Future<OperationOutcome> Function(ServiceOperations ops) invoke,
  ) async {
    final operations = widget.operations;
    if (operations == null) return;
    setState(() {
      _pending = true;
      // Sending is not completion: never write business state here.
      _note = '已发送，等待应用回报…';
    });
    final outcome = await invoke(operations);
    if (!mounted) return;
    setState(() {
      _pending = false;
      _note = switch (outcome) {
        OperationAcknowledged() => '应用已应答，正在刷新状态…',
        OperationUnsupported() => '应用不支持该操作',
        OperationFailed(:final reason) => '应用报告失败：$reason',
        OperationBusy() => '该服务正忙（busy）',
        OperationUnknown() => '结果未知：等待超时，未重发、未强制停止',
        OperationUnavailable(:final reason) => '无法发送：$reason',
      };
    });
    // After the application answers, re-query the real business state.
    _requery();
  }

  Future<void> _openLogs() async {
    final operations = widget.operations;
    if (operations == null) return;
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (context) => LogPanel(
        operations: operations,
        projectId: widget.projectId,
        serviceId: widget.service.id,
        title: '日志：${widget.service.name}',
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final declared = widget.registry
        ?.byProject(widget.projectId)
        ?.capabilities
        .serviceById(widget.service.id);
    final canStart = declared != null && declared.supports(kMethodStart);
    final canRecycle = declared != null && declared.supports(kMethodRecycle);
    final canStatus = declared != null && declared.supports(kMethodStatus);
    final canLogs = declared != null && declared.supports(kMethodLogs);
    final loginStart = widget.preferences.isLoginStartEnabled(
      widget.projectId,
      widget.service.id,
    );
    final view = _view;
    return Container(
      margin: const EdgeInsets.only(bottom: AppTheme.gapSm),
      padding: const EdgeInsets.symmetric(
        horizontal: AppTheme.gapMd,
        vertical: AppTheme.gapMd,
      ),
      decoration: BoxDecoration(
        color: AppTheme.surfaceSubtle,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: AppTheme.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          CardHeader(
            title: Text(
              '服务 ${widget.service.name}（${widget.service.id}）',
              style: AppTheme.serviceName,
            ),
            actions: [
              if (_pending)
                const Padding(
                  padding: EdgeInsets.only(right: AppTheme.gapSm),
                  child: SizedBox(
                    width: 14,
                    height: 14,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: AppTheme.accent,
                    ),
                  ),
                ),
              _ActionButton(
                label: '启动',
                icon: Icons.play_arrow_rounded,
                color: AppTheme.ok,
                onPressed: canStart && !_pending
                    ? () => _change(
                        (ops) => ops.start(widget.projectId, widget.service.id),
                      )
                    : null,
              ),
              _ActionButton(
                label: '回收',
                icon: Icons.stop_rounded,
                color: AppTheme.danger,
                onPressed: canRecycle && !_pending
                    ? () => _change(
                        (ops) =>
                            ops.recycle(widget.projectId, widget.service.id),
                      )
                    : null,
              ),
              _ActionButton(
                label: '刷新',
                icon: Icons.refresh_rounded,
                color: AppTheme.accent,
                onPressed: canStatus && !_pending ? _requery : null,
              ),
              _ActionButton(
                label: '日志',
                icon: Icons.article_outlined,
                color: AppTheme.neutral,
                onPressed: canLogs ? _openLogs : null,
              ),
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Text('登录启动', style: AppTheme.captionMuted),
                  Transform.scale(
                    scale: 0.75,
                    child: Switch(
                      value: loginStart,
                      onChanged: (value) async {
                        await widget.preferences.setLoginStartEnabled(
                          widget.projectId,
                          widget.service.id,
                          value,
                        );
                        widget.onChanged();
                      },
                    ),
                  ),
                ],
              ),
            ],
          ),
          if (view != null) ...[
            const SizedBox(height: AppTheme.gapSm),
            _StatusView(view: view, connected: _connected),
          ],
          if (_note != null)
            Padding(
              padding: const EdgeInsets.only(top: AppTheme.gapXs),
              child: Text(
                _note!,
                style: AppTheme.caption.copyWith(
                  color: AppTheme.accent,
                  fontStyle: FontStyle.italic,
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// Compact operation button with an icon; disabled state greys out.
class _ActionButton extends StatelessWidget {
  const _ActionButton({
    required this.label,
    required this.icon,
    required this.color,
    this.onPressed,
  });

  final String label;
  final IconData icon;
  final Color color;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final enabled = onPressed != null;
    final foreground = enabled ? color : AppTheme.textTertiary;
    return Padding(
      padding: const EdgeInsets.only(left: AppTheme.gapXs),
      child: TextButton.icon(
        onPressed: onPressed,
        icon: Icon(icon, size: 15, color: foreground),
        label: Text(label),
        style: TextButton.styleFrom(
          foregroundColor: foreground,
          textStyle: const TextStyle(
            fontSize: 12.5,
            fontWeight: FontWeight.w500,
          ),
          minimumSize: const Size(0, 30),
          padding: const EdgeInsets.symmetric(horizontal: 8),
          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        ),
      ),
    );
  }
}

class _StatusView extends StatelessWidget {
  const _StatusView({required this.view, required this.connected});

  final ServiceViewState view;
  final bool connected;

  @override
  Widget build(BuildContext context) {
    final parts = <String>[];
    final status = view.confirmedStatus;
    if (status != null) {
      parts.add('状态：${status.state.name}');
      if (status.instanceId != null) parts.add('实例：${status.instanceId}');
      if (status.state == ServiceState.running) {
        parts.add(switch (status.ready) {
          true => '已就绪',
          false => '运行中但未就绪',
          null => '就绪情况未知',
        });
      }
      if (view.lastObservationAt != null) {
        parts.add('最后观测 ${view.lastObservationAt!.toLocal()}');
      } else {
        parts.add('仅应用报告，观测时间未知');
      }
      if (status.message != null) parts.add(status.message!);
    } else {
      parts.add('尚无已确认状态');
    }
    if (view.isUnknown) {
      parts.add('当前状态未知${view.reason != null ? '（${view.reason}）' : ''}');
    }
    final stateColor = view.isUnknown
        ? AppTheme.textTertiary
        : switch (status?.state) {
            ServiceState.running => AppTheme.ok,
            ServiceState.stopped => AppTheme.neutral,
            null => AppTheme.textTertiary,
            _ => AppTheme.warn,
          };
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(top: 5),
          child: Container(
            width: 7,
            height: 7,
            decoration: BoxDecoration(
              color: stateColor,
              shape: BoxShape.circle,
            ),
          ),
        ),
        const SizedBox(width: AppTheme.gapSm),
        Expanded(
          child: Text(
            parts.join(' · '),
            style: AppTheme.caption.copyWith(
              color: view.isUnknown
                  ? AppTheme.textTertiary
                  : AppTheme.textSecondary,
            ),
          ),
        ),
      ],
    );
  }
}
