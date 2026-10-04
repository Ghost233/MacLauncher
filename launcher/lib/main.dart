import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:launcher_core/launcher_core.dart';

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
  runApp(MacLauncherApp(server: server, serverError: error, bindings: bindings));
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
            server: server, serverError: serverError, bindings: bindings),
      );
}

/// The optional management window: project bindings and live connections.
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

  @override
  void initState() {
    super.initState();
    _subscription = widget.server?.registry.changes.listen((_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _subscription?.cancel();
    super.dispose();
  }

  Future<void> _associate() async {
    final path = await _native.invokeMethod<String>('pickManifest');
    if (path == null || !mounted) return;
    try {
      await widget.bindings.associate(path);
      setState(() {});
    } on ManifestException catch (e) {
      if (!mounted) return;
      await showDialog<void>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('无法关联项目配置'),
          content: Text('具体原因：${e.reason}\n${e.detail}'),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('知道了'),
            ),
          ],
        ),
      );
    }
  }

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
                  child: Text(
                      '尚未关联任何项目。\n点击右上角「关联项目」，选择项目目录中的 maclauncher.json。'),
                )
              : ListView(
                  children: [
                    for (final binding in bindings)
                      _ProjectCard(binding: binding, registry: registry),
                  ],
                ),
    );
  }
}

class _ProjectCard extends StatelessWidget {
  const _ProjectCard({required this.binding, this.registry});

  final ProjectBinding binding;
  final ConnectionRegistry? registry;

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
                  child: Text(binding.name,
                      style: Theme.of(context).textTheme.titleMedium),
                ),
                Text(connected ? '应用连接：已连接' : '应用连接：未连接'),
              ],
            ),
            const SizedBox(height: 4),
            Text('项目标识：${binding.projectId}'),
            const Divider(),
            for (final service in binding.services)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 2),
                child: _ServiceLine(
                    service: service, projectId: binding.projectId, registry: registry),
              ),
          ],
        ),
      ),
    );
  }
}

class _ServiceLine extends StatelessWidget {
  const _ServiceLine({required this.service, required this.projectId, this.registry});

  final ManifestService service;
  final String projectId;
  final ConnectionRegistry? registry;

  @override
  Widget build(BuildContext context) {
    final declared = registry
        ?.byProject(projectId)
        ?.capabilities
        .serviceById(service.id);
    final suffix = declared == null ? '' : '：${declared.methods.join(', ')}';
    return Text('服务 ${service.name}（${service.id}）$suffix');
  }
}
