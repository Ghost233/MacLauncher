import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:launcher_core/launcher_core.dart';
import 'package:maclauncher/main.dart';
import 'package:maclauncher_sdk/maclauncher_sdk.dart';

/// Shared launcher test fixture: a temp directory with one bound project
/// (project-a / 项目甲) and real local stores. The server-side stack
/// (socket endpoint, operations, handoff, UnbindFlow) is wired on demand,
/// so serverless tests (invalid guidance) and full-stack tests share the
/// same setup code.
class LauncherTestHarness {
  LauncherTestHarness._();

  late Directory directory;
  late BindingStore bindings;
  late PreferenceStore preferences;
  late ConfigRefresher refresher;
  LauncherServer? _server;
  ServiceOperations? _operations;
  EntryHandoffCoordinator? _handoff;
  UnbindFlow? _unbindFlow;

  String get projectDir => '${directory.path}/proj';
  String get manifestPath => '$projectDir/maclauncher.json';

  LauncherServer get server => _server!;
  ServiceOperations get operations => _operations!;
  EntryHandoffCoordinator get handoff => _handoff!;
  UnbindFlow? get unbindFlow => _unbindFlow;

  static Future<LauncherTestHarness> create({
    Map<String, String> services = const {'svc-1': 'svc-1', 'svc-2': 'svc-2'},
    bool withServer = false,
  }) async {
    final harness = LauncherTestHarness._();
    harness.directory = Directory.systemTemp.createTempSync('launcher-test-');
    writeManifest(harness.projectDir, services);
    harness.bindings = await BindingStore.load(
      '${harness.directory.path}/bindings.json',
    );
    await harness.bindings.associate(harness.manifestPath);
    harness.preferences = await PreferenceStore.load(
      '${harness.directory.path}/preferences.json',
    );
    harness.refresher = await ConfigRefresher.load(
      harness.bindings,
      '${harness.directory.path}/config_state.json',
    );
    if (withServer) await harness.enableServerStack();
    return harness;
  }

  /// Writes a manifest for project-a declaring [services] (id → 显示名).
  static void writeManifest(String dir, Map<String, String> services) {
    Directory(dir).createSync(recursive: true);
    File('$dir/maclauncher.json').writeAsStringSync('''
{
  "schemaVersion": 1,
  "project": {"id": "project-a", "name": "项目甲"},
  "services": [${services.entries.map((e) => '{"id": "${e.key}", "name": "${e.value}"}').join(',')}]
}
''');
  }

  /// Wires the server-side stack (socket endpoint, operations, handoff,
  /// UnbindFlow) so wired paths are exercised end to end.
  Future<void> enableServerStack() async {
    if (_server != null) return;
    _server = await LauncherServer.start(
      layout: EndpointLayout(directory: '${directory.path}/endpoint'),
      bindings: bindings,
    );
    _operations = ServiceOperations(
      server: _server!,
      scope: BindingServiceScope(bindings),
      timeout: const Duration(seconds: 2),
    );
    _handoff = EntryHandoffCoordinator(
      server: _server!,
      statusQuery: (_) async => true,
    );
    _unbindFlow = UnbindFlow(
      bindings: bindings,
      preferences: preferences,
      refresher: refresher,
      handoff: _handoff!,
      server: _server!,
    );
  }

  MacLauncherApp app() => MacLauncherApp(
    server: _server,
    bindings: bindings,
    preferences: preferences,
    refresher: refresher,
    operations: _operations,
    handoff: _handoff,
    unbindFlow: _unbindFlow,
  );

  /// Connects an SDK client for project-a and waits until the registry
  /// sees the session. Requires [enableServerStack].
  Future<MacLauncherSdk> connectSdk(
    Map<String, ServiceCallbacks> services, {
    AppCallbacks? app,
  }) async {
    final sdk = MacLauncherSdk.connect(
      projectId: 'project-a',
      socketPath: server.layout.socketPath,
      services: services,
      app: app,
    );
    await server.registry.changes.first.timeout(const Duration(seconds: 10));
    return sdk;
  }

  Future<void> dispose() async {
    _handoff?.dispose();
    await _server?.close();
    if (directory.existsSync()) directory.deleteSync(recursive: true);
  }
}

/// Lets real async work (socket round-trips, timers) finish under
/// `tester.runAsync`, then pumps one frame.
Future<void> settle(
  WidgetTester tester, [
  Duration delay = const Duration(milliseconds: 400),
]) async {
  await Future<void>.delayed(delay);
  await tester.pump();
}
