import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:launcher_core/launcher_core.dart';
import 'package:maclauncher/main.dart';
import 'package:maclauncher_sdk/maclauncher_sdk.dart';

void main() {
  testWidgets('a bound project appears and shows live capabilities', (
    tester,
  ) async {
    await tester.runAsync(() async {
      final directory = Directory.systemTemp.createTempSync('launcher-ui-');
      final projectDir = Directory('${directory.path}/proj')..createSync();
      File('${projectDir.path}/maclauncher.json').writeAsStringSync('''
{
  "schemaVersion": 1,
  "project": {"id": "project-a", "name": "项目甲"},
  "services": [
    {"id": "read-only", "name": "只读服务"}
  ]
}
''');
      final bindings = await BindingStore.load(
        '${directory.path}/bindings.json',
      );
      await bindings.associate('${projectDir.path}/maclauncher.json');

      final server = await LauncherServer.start(
        layout: EndpointLayout(directory: '${directory.path}/endpoint'),
        bindings: bindings,
      );
      MacLauncherSdk? sdk;
      try {
        await tester.pumpWidget(
          MacLauncherApp(server: server, bindings: bindings),
        );
        expect(find.text('项目甲'), findsOneWidget);
        expect(find.text('应用连接：未连接'), findsOneWidget);

        sdk = MacLauncherSdk.connect(
          projectId: 'project-a',
          socketPath: server.layout.socketPath,
          services: {
            'read-only': ServiceCallbacks(
              name: '只读服务',
              onStatus: () async => ServiceStatus(state: ServiceState.running),
            ),
          },
        );
        await server.registry.changes.first.timeout(
          const Duration(seconds: 10),
        );
        // The page queries status before setState; let that finish.
        await Future<void>.delayed(const Duration(milliseconds: 300));
        await tester.pump();

        expect(find.text('应用连接：已连接'), findsOneWidget);
        expect(find.textContaining('服务 只读服务（read-only）'), findsOneWidget);
        expect(find.textContaining('状态：running'), findsOneWidget);
      } finally {
        await sdk?.dispose();
        await server.close();
        directory.deleteSync(recursive: true);
      }
    });
  });

  testWidgets(
    'tapping 启动 sends the request; the displayed state comes from the application',
    (tester) async {
      await tester.runAsync(() async {
        final directory = Directory.systemTemp.createTempSync('launcher-ui-');
        final projectDir = Directory('${directory.path}/proj')..createSync();
        File('${projectDir.path}/maclauncher.json').writeAsStringSync('''
{
  "schemaVersion": 1,
  "project": {"id": "project-a", "name": "项目甲"},
  "services": [
    {"id": "svc", "name": "受控服务"}
  ]
}
''');
        final bindings = await BindingStore.load(
          '${directory.path}/bindings.json',
        );
        await bindings.associate('${projectDir.path}/maclauncher.json');
        final server = await LauncherServer.start(
          layout: EndpointLayout(directory: '${directory.path}/endpoint'),
          bindings: bindings,
        );
        var appState = ServiceState.stopped;
        var startCalls = 0;
        MacLauncherSdk? sdk;
        try {
          await tester.pumpWidget(
            MacLauncherApp(server: server, bindings: bindings),
          );
          sdk = MacLauncherSdk.connect(
            projectId: 'project-a',
            socketPath: server.layout.socketPath,
            services: {
              'svc': ServiceCallbacks(
                name: '受控服务',
                onStart: () async {
                  startCalls++;
                  appState = ServiceState.running;
                },
                onRecycle: () async => appState = ServiceState.stopped,
                onStatus: () async => ServiceStatus(
                  state: appState,
                  instanceId: 'run-1',
                  ready: appState == ServiceState.running,
                  observedAt: DateTime.utc(2026, 10, 5, 12),
                ),
              ),
            },
          );
          await server.registry.changes.first.timeout(
            const Duration(seconds: 10),
          );
          await Future<void>.delayed(const Duration(milliseconds: 300));
          await tester.pump();

          // Before any tap the snapshot says stopped; nothing was faked.
          expect(find.textContaining('状态：stopped'), findsOneWidget);

          await tester.tap(find.text('启动'));
          await Future<void>.delayed(const Duration(milliseconds: 300));
          await tester.pump();

          expect(startCalls, 1);
          expect(find.textContaining('状态：running'), findsOneWidget);
          expect(find.textContaining('实例：run-1'), findsOneWidget);
          expect(find.textContaining('已就绪'), findsOneWidget);
        } finally {
          await sdk?.dispose();
          await server.close();
          directory.deleteSync(recursive: true);
        }
      });
    },
  );
}
