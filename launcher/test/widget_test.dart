import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:launcher_core/launcher_core.dart';
import 'package:maclauncher/main.dart';
import 'package:maclauncher_sdk/maclauncher_sdk.dart';

void main() {
  testWidgets('a bound project appears and shows live capabilities',
      (tester) async {
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
      final bindings =
          await BindingStore.load('${directory.path}/bindings.json');
      await bindings.associate('${projectDir.path}/maclauncher.json');

      final server = await LauncherServer.start(
        layout: EndpointLayout(directory: '${directory.path}/endpoint'),
        bindings: bindings,
      );
      MacLauncherSdk? sdk;
      try {
        await tester
            .pumpWidget(MacLauncherApp(server: server, bindings: bindings));
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
        await server.registry.changes.first
            .timeout(const Duration(seconds: 10));
        await tester.pump();

        expect(find.text('应用连接：已连接'), findsOneWidget);
        expect(find.text('服务 只读服务（read-only）：status'), findsOneWidget);
      } finally {
        await sdk?.dispose();
        await server.close();
        directory.deleteSync(recursive: true);
      }
    });
  });
}
