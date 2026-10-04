import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:launcher_core/launcher_core.dart';
import 'package:maclauncher/main.dart';
import 'package:maclauncher_sdk/maclauncher_sdk.dart';

/// Builds the full launcher graph against a temp endpoint, with a bound
/// project declaring [services] (id → display name).
class _Harness {
  _Harness._();

  late Directory directory;
  late BindingStore bindings;
  late PreferenceStore preferences;
  late ConfigRefresher refresher;
  late LauncherServer server;
  late ServiceOperations operations;
  late EntryHandoffCoordinator handoff;

  static Future<_Harness> create(Map<String, String> services) async {
    final harness = _Harness._();
    harness.directory = Directory.systemTemp.createTempSync(
      'launcher-ui-test-',
    );
    final projectDir = Directory('${harness.directory.path}/proj')
      ..createSync();
    File('${projectDir.path}/maclauncher.json').writeAsStringSync('''
{
  "schemaVersion": 1,
  "project": {"id": "project-a", "name": "项目甲"},
  "services": [${services.entries.map((e) => '{"id": "${e.key}", "name": "${e.value}"}').join(',')}]
}
''');
    harness.bindings = await BindingStore.load(
      '${harness.directory.path}/bindings.json',
    );
    await harness.bindings.associate('${projectDir.path}/maclauncher.json');
    harness.preferences = await PreferenceStore.load(
      '${harness.directory.path}/preferences.json',
    );
    harness.refresher = await ConfigRefresher.load(
      harness.bindings,
      '${harness.directory.path}/config_state.json',
    );
    harness.server = await LauncherServer.start(
      layout: EndpointLayout(directory: '${harness.directory.path}/endpoint'),
      bindings: harness.bindings,
    );
    harness.operations = ServiceOperations(
      server: harness.server,
      scope: BindingServiceScope(harness.bindings),
      timeout: const Duration(seconds: 2),
    );
    harness.handoff = EntryHandoffCoordinator(
      server: harness.server,
      statusQuery: (_) async => true,
    );
    return harness;
  }

  MacLauncherApp app() => MacLauncherApp(
    server: server,
    bindings: bindings,
    preferences: preferences,
    refresher: refresher,
    operations: operations,
    handoff: handoff,
  );

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
    handoff.dispose();
    await server.close();
    directory.deleteSync(recursive: true);
  }
}

Future<void> settle(
  WidgetTester tester, [
  Duration delay = const Duration(milliseconds: 400),
]) async {
  await Future<void>.delayed(delay);
  await tester.pump();
}

void main() {
  testWidgets('a bound project appears and shows observer-driven status', (
    tester,
  ) async {
    await tester.runAsync(() async {
      final harness = await _Harness.create({'read-only': '只读服务'});
      MacLauncherSdk? sdk;
      try {
        await tester.pumpWidget(harness.app());
        expect(find.text('项目甲'), findsOneWidget);
        expect(find.text('应用连接：未连接'), findsOneWidget);

        sdk = await harness.connectSdk({
          'read-only': ServiceCallbacks(
            name: '只读服务',
            onStatus: () async => ServiceStatus(
              state: ServiceState.running,
              observedAt: DateTime.utc(2026, 10, 5, 12),
            ),
          ),
        });
        await settle(tester);

        expect(find.text('应用连接：已连接'), findsOneWidget);
        expect(find.textContaining('服务 只读服务（read-only）'), findsOneWidget);
        expect(find.textContaining('状态：running'), findsOneWidget);
      } finally {
        await sdk?.dispose();
        await harness.dispose();
      }
    });
  });

  testWidgets(
    'tapping 启动 sends the request; the displayed state comes from the application',
    (tester) async {
      await tester.runAsync(() async {
        final harness = await _Harness.create({'svc': '受控服务'});
        var appState = ServiceState.stopped;
        var startCalls = 0;
        MacLauncherSdk? sdk;
        try {
          await tester.pumpWidget(harness.app());
          sdk = await harness.connectSdk({
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
          });
          await settle(tester);
          expect(find.textContaining('状态：stopped'), findsOneWidget);

          await tester.tap(find.text('启动'));
          await settle(tester);

          expect(startCalls, 1);
          expect(find.textContaining('状态：running'), findsOneWidget);
          expect(find.textContaining('实例：run-1'), findsOneWidget);
          expect(find.textContaining('已就绪'), findsOneWidget);
        } finally {
          await sdk?.dispose();
          await harness.dispose();
        }
      });
    },
  );

  testWidgets('log panel shows app-reported entries verbatim and closes', (
    tester,
  ) async {
    await tester.runAsync(() async {
      final harness = await _Harness.create({'svc': '日志服务'});
      var logQueries = 0;
      MacLauncherSdk? sdk;
      try {
        await tester.pumpWidget(harness.app());
        sdk = await harness.connectSdk({
          'svc': ServiceCallbacks(
            name: '日志服务',
            onStatus: () async => ServiceStatus(state: ServiceState.running),
            onLogs: (query) async {
              logQueries++;
              return LogBatch(
                entries: [
                  LogEntry(text: '第一行日志'),
                  LogEntry(
                    text: '第二行日志',
                    timestamp: DateTime.utc(2026, 10, 5, 11),
                    stream: LogStream.stderr,
                  ),
                ],
                observedAt: DateTime.now().toUtc(),
              );
            },
          ),
        });
        await settle(tester);

        await tester.tap(find.text('日志'));
        // Build the sheet, then finish its fake-time entrance animation so
        // the close button is actually on screen before we tap it later.
        await tester.pump();
        await tester.pumpAndSettle();
        // Let the real socket round-trip finish.
        await settle(tester);

        expect(
          find.textContaining('第一行日志', findRichText: true),
          findsOneWidget,
        );
        expect(
          find.textContaining('第二行日志', findRichText: true),
          findsOneWidget,
        );
        expect(
          find.textContaining('无原始时间', findRichText: true),
          findsOneWidget,
        );
        expect(find.textContaining('分流未知', findRichText: true), findsOneWidget);
        expect(find.textContaining('未提供实例范围'), findsOneWidget);
        expect(logQueries, greaterThanOrEqualTo(1));

        // Closing the panel stops further queries. One query already in
        // flight may still land at the app; after that the count must
        // freeze across a full poll interval.
        await tester.tap(find.byIcon(Icons.close));
        await tester.pump();
        await tester.pumpAndSettle();
        await Future<void>.delayed(const Duration(seconds: 3));
        final frozen = logQueries;
        await Future<void>.delayed(const Duration(seconds: 3));
        expect(logQueries, frozen);
      } finally {
        await sdk?.dispose();
        await harness.dispose();
      }
    });
  });

  testWidgets('登录启动 switch persists to the preference store', (tester) async {
    await tester.runAsync(() async {
      final harness = await _Harness.create({'svc': '偏好服务'});
      MacLauncherSdk? sdk;
      try {
        await tester.pumpWidget(harness.app());
        sdk = await harness.connectSdk({
          'svc': ServiceCallbacks(
            name: '偏好服务',
            onStatus: () async => ServiceStatus(state: ServiceState.stopped),
          ),
        });
        await settle(tester);

        expect(
          harness.preferences.isLoginStartEnabled('project-a', 'svc'),
          isFalse,
        );
        await tester.tap(find.byType(Switch));
        await settle(tester, const Duration(milliseconds: 200));

        expect(
          harness.preferences.isLoginStartEnabled('project-a', 'svc'),
          isTrue,
        );
        // Persisted: a fresh store instance sees the same preference.
        final reloaded = await PreferenceStore.load(
          '${harness.directory.path}/preferences.json',
        );
        expect(reloaded.isLoginStartEnabled('project-a', 'svc'), isTrue);
      } finally {
        await sdk?.dispose();
        await harness.dispose();
      }
    });
  });

  testWidgets('handoff confirms show 接管完成 and 打开窗口 appears when declared', (
    tester,
  ) async {
    await tester.runAsync(() async {
      final harness = await _Harness.create({'svc': '窗口服务'});
      var entryManaged = false;
      var openedWindows = 0;
      MacLauncherSdk? sdk;
      try {
        await tester.pumpWidget(harness.app());
        sdk = await harness.connectSdk(
          {
            'svc': ServiceCallbacks(
              name: '窗口服务',
              onStatus: () async => ServiceStatus(state: ServiceState.running),
            ),
          },
          app: AppCallbacks(
            onOpenWindow: () async => openedWindows++,
            onSetEntryManaged: (managed) async {
              entryManaged = managed;
              return true;
            },
          ),
        );
        await settle(tester, const Duration(milliseconds: 800));

        expect(entryManaged, isTrue);
        expect(find.text('统一入口：接管完成'), findsOneWidget);
        expect(find.text('打开窗口'), findsOneWidget);

        await tester.tap(find.text('打开窗口'));
        await settle(tester, const Duration(milliseconds: 200));
        expect(openedWindows, 1);
      } finally {
        await sdk?.dispose();
        await harness.dispose();
      }
    });
  });
}
