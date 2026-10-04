import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:launcher_core/launcher_core.dart';
import 'package:maclauncher_sdk/maclauncher_sdk.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final layout = EndpointLayout.forUser();
  final bindings = await BindingStore.load('${layout.directory}/bindings.json');
  LauncherServer? server;
  Object? error;
  try {
    server = await LauncherServer.start(layout: layout, bindings: bindings);
  } catch (e) {
    error = e;
  }
  runApp(
    MacLauncherApp(server: server, serverError: error, bindings: bindings),
  );
}

class MacLauncherApp extends StatelessWidget {
  const MacLauncherApp({
    super.key,
    this.server,
    this.serverError,
    required this.bindings,
  });

  final LauncherServer? server;
  final Object? serverError;
  final BindingStore bindings;

  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'MacLauncher',
    theme: ThemeData(colorSchemeSeed: Colors.blueGrey, useMaterial3: true),
    home: ManagementPage(
      server: server,
      serverError: serverError,
      bindings: bindings,
    ),
  );
}

/// The optional management window: project bindings, live connections and
/// per-service operations with application-reported snapshots.
class ManagementPage extends StatefulWidget {
  const ManagementPage({
    super.key,
    this.server,
    this.serverError,
    required this.bindings,
  });

  final LauncherServer? server;
  final Object? serverError;
  final BindingStore bindings;

  @override
  State<ManagementPage> createState() => _ManagementPageState();
}

class _ManagementPageState extends State<ManagementPage> {
  static const _native = MethodChannel('maclauncher/native');
  StreamSubscription<ConnectedProject?>? _subscription;

  /// Application-reported snapshots, keyed `$projectId/$serviceId`. A button
  /// click never writes business state here directly; only query results do.
  final Map<String, ServiceStatus> _statuses = {};
  final Map<String, String> _notes = {};
  final Set<String> _pending = {};

  ServiceOperations? _operations;

  ServiceOperations get operations => _operations ??= ServiceOperations(
    server: widget.server!,
    scope: BindingServiceScope(widget.bindings),
  );

  @override
  void initState() {
    super.initState();
    _subscription = widget.server?.registry.changes.listen((project) async {
      if (project != null) await _queryAll(project);
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _subscription?.cancel();
    super.dispose();
  }

  String _key(String projectId, String serviceId) => '$projectId/$serviceId';

  Future<void> _queryAll(ConnectedProject project) async {
    for (final service in project.capabilities.services) {
      if (service.supports(kMethodStatus)) {
        await _queryStatus(project.projectId, service.id);
      }
    }
  }

  Future<void> _queryStatus(String projectId, String serviceId) async {
    final key = _key(projectId, serviceId);
    final result = await operations.status(projectId, serviceId);
    if (!mounted) return;
    setState(() {
      switch (result) {
        case StatusSnapshot(:final status):
          _statuses[key] = status;
          _notes.remove(key);
        case StatusUnsupported():
          _notes[key] = '应用未提供状态能力';
        case StatusUnknown(:final reason):
          _notes[key] = '状态未知（$reason）';
      }
    });
  }

  Future<void> _change(
    String projectId,
    String serviceId,
    Future<OperationOutcome> Function() invoke,
  ) async {
    final key = _key(projectId, serviceId);
    setState(() {
      _pending.add(key);
      // Sending is not completion: never write business state here.
      _notes[key] = '已发送，等待应用回报…';
    });
    final outcome = await invoke();
    if (!mounted) return;
    setState(() {
      _pending.remove(key);
      switch (outcome) {
        case OperationAcknowledged():
          _notes[key] = '应用已应答，正在刷新状态…';
        case OperationUnsupported():
          _notes[key] = '应用不支持该操作';
        case OperationFailed(:final reason):
          _notes[key] = '应用报告失败：$reason';
        case OperationBusy():
          _notes[key] = '该服务正忙（busy）';
        case OperationUnknown():
          _notes[key] = '结果未知：等待超时，未重发、未强制停止';
        case OperationUnavailable(:final reason):
          _notes[key] = '无法发送：$reason';
      }
    });
    // After the application answers, re-query the real business state.
    await _queryStatus(projectId, serviceId);
  }

  Future<void> _associate() async {
    final path = await _native.invokeMethod<String>('pickManifest');
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

  Future<void> _resolveConflict(
    AssociationFlow flow,
    AssociationConflict conflict,
  ) async {
    final existing = conflict.existingBinding;
    final message = switch (conflict.kind) {
      AssociationConflictKind.identityBoundToOtherPath =>
        '相同的项目身份已在另一路径绑定：\n${existing.manifestPath}\n\n'
            '迁移会把原绑定（含偏好）移到新路径；作为新项目会为进入的配置生成新的项目身份。',
      AssociationConflictKind.pathBoundToOtherIdentity =>
        '该路径已绑定到另一个项目身份：\n${existing.projectId}\n\n'
            '迁移会把绑定更新为进入配置的身份；作为新项目会为进入的配置生成新的项目身份。',
    };
    final choice = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('项目身份冲突'),
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

  void _toast(String message) {
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
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
    return Scaffold(
      appBar: AppBar(
        title: const Text('MacLauncher 管理'),
        actions: [
          TextButton.icon(
            onPressed: _associate,
            icon: const Icon(Icons.link),
            label: const Text('关联项目'),
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: widget.serverError != null
          ? Center(child: SelectableText('监听端点启动失败：${widget.serverError}'))
          : bindings.isEmpty
          ? const Center(
              child: Text('尚未关联任何项目。\n点击右上角「关联项目」，选择项目目录中的 maclauncher.json。'),
            )
          : ListView(
              children: [
                for (final binding in bindings)
                  _ProjectCard(
                    binding: binding,
                    registry: registry,
                    statuses: _statuses,
                    notes: _notes,
                    pending: _pending,
                    onAction: (serviceId, action) {
                      if (action == 'refresh') {
                        _queryStatus(binding.projectId, serviceId);
                        return;
                      }
                      final invoke = action == 'start'
                          ? () => operations.start(binding.projectId, serviceId)
                          : () => operations.recycle(
                              binding.projectId,
                              serviceId,
                            );
                      _change(binding.projectId, serviceId, invoke);
                    },
                  ),
              ],
            ),
    );
  }
}

class _ProjectCard extends StatelessWidget {
  const _ProjectCard({
    required this.binding,
    required this.statuses,
    required this.notes,
    required this.pending,
    required this.onAction,
    this.registry,
  });

  final ProjectBinding binding;
  final ConnectionRegistry? registry;
  final Map<String, ServiceStatus> statuses;
  final Map<String, String> notes;
  final Set<String> pending;
  final void Function(String serviceId, String action) onAction;

  @override
  Widget build(BuildContext context) {
    final connected = registry?.isActive(binding.projectId) ?? false;
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    binding.name,
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                ),
                Text(connected ? '应用连接：已连接' : '应用连接：未连接'),
              ],
            ),
            const SizedBox(height: 4),
            Text('项目标识：${binding.projectId}'),
            const Divider(),
            for (final service in binding.services)
              _ServiceLine(
                projectId: binding.projectId,
                service: service,
                registry: registry,
                status: statuses['${binding.projectId}/${service.id}'],
                note: notes['${binding.projectId}/${service.id}'],
                busy: pending.contains('${binding.projectId}/${service.id}'),
                onAction: (action) => onAction(service.id, action),
              ),
          ],
        ),
      ),
    );
  }
}

class _ServiceLine extends StatelessWidget {
  const _ServiceLine({
    required this.projectId,
    required this.service,
    required this.onAction,
    this.registry,
    this.status,
    this.note,
    this.busy = false,
  });

  final String projectId;
  final ManifestService service;
  final ConnectionRegistry? registry;
  final ServiceStatus? status;
  final String? note;
  final bool busy;
  final void Function(String action) onAction;

  @override
  Widget build(BuildContext context) {
    final declared = registry
        ?.byProject(projectId)
        ?.capabilities
        .serviceById(service.id);
    final connected = declared != null;
    final canStart = connected && declared.supports(kMethodStart);
    final canRecycle = connected && declared.supports(kMethodRecycle);
    final canStatus = connected && declared.supports(kMethodStatus);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  '服务 ${service.name}（${service.id}）',
                  style: Theme.of(context).textTheme.bodyLarge,
                ),
              ),
              if (busy)
                const Padding(
                  padding: EdgeInsets.only(right: 8),
                  child: SizedBox(
                    width: 14,
                    height: 14,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                ),
              TextButton(
                onPressed: canStart && !busy ? () => onAction('start') : null,
                child: const Text('启动'),
              ),
              TextButton(
                onPressed: canRecycle && !busy
                    ? () => onAction('recycle')
                    : null,
                child: const Text('回收'),
              ),
              TextButton(
                onPressed: canStatus && !busy
                    ? () => onAction('refresh')
                    : null,
                child: const Text('刷新'),
              ),
            ],
          ),
          if (status != null) _StatusView(status: status!),
          if (note != null)
            Text(
              note!,
              style: Theme.of(context).textTheme.bodySmall
                  ?.copyWith(color: Theme.of(context).colorScheme.secondary),
            ),
        ],
      ),
    );
  }
}

class _StatusView extends StatelessWidget {
  const _StatusView({required this.status});

  final ServiceStatus status;

  @override
  Widget build(BuildContext context) {
    final parts = <String>['状态：${status.state.name}'];
    if (status.instanceId != null) parts.add('实例：${status.instanceId}');
    if (status.state == ServiceState.running) {
      parts.add(switch (status.ready) {
        true => '已就绪',
        false => '运行中但未就绪',
        null => '就绪情况未知',
      });
    }
    if (status.observedAt != null) {
      parts.add('观测于 ${status.observedAt!.toLocal()}');
    } else {
      parts.add('观测时间未知（仅为应用报告）');
    }
    if (status.message != null) parts.add(status.message!);
    return Text(
      parts.join(' · '),
      style: Theme.of(context).textTheme.bodySmall,
    );
  }
}
