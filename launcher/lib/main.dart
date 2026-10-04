import 'dart:async';

import 'package:flutter/material.dart';
import 'package:launcher_core/launcher_core.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  LauncherServer? server;
  Object? error;
  try {
    server = await LauncherServer.start(
      layout: EndpointLayout.forUser(),
      // Development-only peer until persisted project bindings arrive.
      bindings: InMemoryBindingLookup({'demo-project'}),
    );
  } catch (e) {
    error = e;
  }
  runApp(MacLauncherApp(server: server, serverError: error));
}

class MacLauncherApp extends StatelessWidget {
  const MacLauncherApp({super.key, this.server, this.serverError});

  final LauncherServer? server;
  final Object? serverError;

  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'MacLauncher',
    theme: ThemeData(colorSchemeSeed: Colors.blueGrey, useMaterial3: true),
    home: ManagementPage(server: server, serverError: serverError),
  );
}

class ManagementPage extends StatefulWidget {
  const ManagementPage({super.key, this.server, this.serverError});

  final LauncherServer? server;
  final Object? serverError;

  @override
  State<ManagementPage> createState() => _ManagementPageState();
}

class _ManagementPageState extends State<ManagementPage> {
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

  @override
  Widget build(BuildContext context) {
    final server = widget.server;
    final projects = server?.registry.connected ?? <ConnectedProject>[];
    return Scaffold(
      appBar: AppBar(title: const Text('MacLauncher 管理')),
      body: widget.serverError != null
          ? Center(child: SelectableText('监听端点启动失败：${widget.serverError}'))
          : projects.isEmpty
          ? const Center(child: Text('暂无已连接应用。\n接入的应用经 SDK 握手后会显示在这里。'))
          : ListView(
              children: [
                for (final project in projects)
                  Card(
                    margin: const EdgeInsets.all(16),
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            project.projectId,
                            style: Theme.of(context).textTheme.titleLarge,
                          ),
                          const Text('应用连接：已连接'),
                          Text('应用会话：${project.appSessionId}'),
                          const Divider(),
                          for (final service in project.capabilities.services)
                            Text(
                              '${service.name}（${service.id}）：${service.methods.join(', ')}',
                            ),
                          if (project.capabilities.app.isNotEmpty)
                            Text('应用能力：${project.capabilities.app.join(', ')}'),
                        ],
                      ),
                    ),
                  ),
              ],
            ),
    );
  }
}
