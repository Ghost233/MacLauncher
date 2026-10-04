import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:launcher_core/launcher_core.dart';
import 'package:maclauncher/main.dart';
import 'package:maclauncher_sdk/maclauncher_sdk.dart';

void main() {
  testWidgets('an SDK application appears with only its real capabilities', (
    tester,
  ) async {
    await tester.runAsync(() async {
      final directory = Directory.systemTemp.createTempSync('launcher-ui-');
      final server = await LauncherServer.start(
        layout: EndpointLayout(directory: directory.path),
        bindings: InMemoryBindingLookup({'project-a'}),
      );
      MacLauncherSdk? sdk;
      try {
        await tester.pumpWidget(MacLauncherApp(server: server));
        expect(find.textContaining('暂无已连接应用'), findsOneWidget);

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
        await tester.pump();

        expect(find.text('project-a'), findsOneWidget);
        expect(find.text('应用连接：已连接'), findsOneWidget);
        expect(find.text('只读服务（read-only）：status'), findsOneWidget);
      } finally {
        await sdk?.dispose();
        await server.close();
        directory.deleteSync(recursive: true);
      }
    });
  });
}
