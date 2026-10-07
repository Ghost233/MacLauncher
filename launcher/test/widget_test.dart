import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:launcher_core/launcher_core.dart';
import 'package:maclauncher/main.dart';
import 'package:maclauncher_sdk/maclauncher_sdk.dart';

import 'launcher_test_harness.dart';

void main() {
  testWidgets('corrupted storage files surface one startup notice, once', (
    tester,
  ) async {
    await tester.runAsync(() async {
      final directory = Directory.systemTemp.createTempSync(
        'launcher-corrupt-ui-test-',
      );
      try {
        // Damage two of the three local stores before the app loads them.
        File('${directory.path}/bindings.json')
            .writeAsStringSync('{oops not json');
        File('${directory.path}/preferences.json')
            .writeAsStringSync('{"proj-a": {"svc": true}, "proj-bad": 42}');
        final bindings = await BindingStore.load(
          '${directory.path}/bindings.json',
        );
        final preferences = await PreferenceStore.load(
          '${directory.path}/preferences.json',
        );
        final refresher = await ConfigRefresher.load(
          bindings,
          '${directory.path}/config_state.json',
        );
        final reports = [
          bindings.corruptionReport,
          preferences.corruptionReport,
          refresher.corruptionReport,
        ].whereType<StorageCorruptionReport>().toList();
        expect(reports, hasLength(2));

        await tester.pumpWidget(
          MacLauncherApp(
            bindings: bindings,
            preferences: preferences,
            refresher: refresher,
            corruptionReports: reports,
          ),
        );
        // Post-frame callback delivers the notice.
        await tester.pump();

        // Content: which file was damaged and where it was backed up.
        expect(find.textContaining('检测到本机存储文件损坏'), findsOneWidget);
        expect(find.textContaining('bindings.json'), findsOneWidget);
        expect(find.textContaining('.corrupt-'), findsOneWidget);
        // Record-level damage is reported too.
        expect(find.textContaining('preferences.json'), findsOneWidget);
        expect(find.textContaining('1 条无效记录'), findsOneWidget);

        // One-time: once dismissed (the snackbar's 5s duration is
        // framework behaviour; hide it explicitly to keep the test
        // deterministic under runAsync), it never comes back — not after
        // further frames, and not across a full widget rebuild.
        tester
            .state<ScaffoldMessengerState>(find.byType(ScaffoldMessenger))
            .hideCurrentSnackBar();
        await tester.pump();
        await tester.pump(const Duration(seconds: 1));
        await tester.pump();
        expect(find.textContaining('检测到本机存储文件损坏'), findsNothing);
        await tester.pumpWidget(
          MacLauncherApp(
            bindings: bindings,
            preferences: preferences,
            refresher: refresher,
            corruptionReports: reports,
          ),
        );
        await tester.pump(const Duration(seconds: 1));
        expect(find.textContaining('检测到本机存储文件损坏'), findsNothing);
      } finally {
        directory.deleteSync(recursive: true);
      }
    });
  });

  testWidgets('a bound project appears and shows observer-driven status', (
    tester,
  ) async {
    await tester.runAsync(() async {
      final harness = await LauncherTestHarness.create(
        services: {'read-only': '只读服务'},
        withServer: true,
      );
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
        final harness = await LauncherTestHarness.create(
          services: {'svc': '受控服务'},
          withServer: true,
        );
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
      final harness = await LauncherTestHarness.create(
        services: {'svc': '日志服务'},
        withServer: true,
      );
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
      final harness = await LauncherTestHarness.create(
        services: {'svc': '偏好服务'},
        withServer: true,
      );
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
        await tester.tap(find.byType(Switch).last);
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
      final harness = await LauncherTestHarness.create(
        services: {'svc': '窗口服务'},
        withServer: true,
      );
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

  testWidgets('解除绑定：确认对话框展示固定文案与影响摘要，确认后回到空态', (tester) async {
    await tester.runAsync(() async {
      final harness = await LauncherTestHarness.create(
        services: {'svc': '偏好服务'},
        withServer: true,
      );
      try {
        await harness.preferences.setLoginStartEnabled(
          'project-a',
          'svc',
          true,
        );
        await tester.pumpWidget(harness.app());
        await settle(tester);

        await tester.tap(find.text('解除绑定'));
        await tester.pumpAndSettle();

        // 固定说明文案 + 动态影响摘要 + 单一确认动作。
        expect(find.text('解除项目绑定'), findsOneWidget);
        expect(find.textContaining('取消该项目的登录启动通知，归还原菜单栏入口。'), findsOneWidget);
        expect(find.textContaining('应用已有业务和日志继续由它自己维护。'), findsOneWidget);
        expect(find.textContaining('将清除 1 项登录启动偏好'), findsOneWidget);
        expect(find.text('保留运行并解除绑定'), findsOneWidget);
        expect(find.text('取消'), findsOneWidget);

        await tester.tap(find.text('保留运行并解除绑定'));
        await tester.pumpAndSettle();
        await settle(tester);

        // 卡片消失，回到空态；本地状态全部清除。
        expect(find.text('项目甲'), findsNothing);
        expect(find.textContaining('尚未关联任何项目'), findsOneWidget);
        expect(harness.bindings.bindings, isEmpty);
        expect(harness.preferences.enabledServices('project-a'), isEmpty);
        // 持久化：重启后绑定不复活。
        final reloaded = await BindingStore.load(
          '${harness.directory.path}/bindings.json',
        );
        expect(reloaded.bindings, isEmpty);
      } finally {
        await harness.dispose();
      }
    });
  });

  testWidgets('解除绑定：取消后一切不变', (tester) async {
    await tester.runAsync(() async {
      final harness = await LauncherTestHarness.create(
        services: {'svc': '偏好服务'},
        withServer: true,
      );
      try {
        await tester.pumpWidget(harness.app());
        await settle(tester);

        await tester.tap(find.text('解除绑定'));
        await tester.pumpAndSettle();
        expect(find.textContaining('将清除 0 项登录启动偏好'), findsOneWidget);

        await tester.tap(find.text('取消'));
        await tester.pumpAndSettle();
        await settle(tester);

        expect(find.text('项目甲'), findsOneWidget);
        expect(harness.bindings.bindings, hasLength(1));
        expect(harness.bindings.byProjectId('project-a'), isNotNull);
      } finally {
        await harness.dispose();
      }
    });
  });

  testWidgets('解除绑定：在线受管会话先收到 setEntryManaged(false) 再断连', (tester) async {
    await tester.runAsync(() async {
      final harness = await LauncherTestHarness.create(
        services: {'svc': '窗口服务'},
        withServer: true,
      );
      final entryEvents = <bool>[];
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
            onSetEntryManaged: (managed) async {
              entryEvents.add(managed);
              return true;
            },
          ),
        );
        await settle(tester, const Duration(milliseconds: 800));
        expect(find.text('统一入口：接管完成'), findsOneWidget);

        await tester.tap(find.text('解除绑定'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('保留运行并解除绑定'));
        await tester.pumpAndSettle();
        await settle(tester, const Duration(milliseconds: 800));

        expect(entryEvents, [true, false]);
        expect(harness.server.registry.isActive('project-a'), isFalse);
        expect(find.textContaining('尚未关联任何项目'), findsOneWidget);
      } finally {
        await sdk?.dispose();
        await harness.dispose();
      }
    });
  });

  testWidgets('retained 记录可逐条清除', (tester) async {
    await tester.runAsync(() async {
      final harness = await LauncherTestHarness.create(
        services: {'svc': '旧服务'},
        withServer: true,
      );
      try {
        // 声明移除 svc：产生一条 retained 记录。
        final manifest = File(
          '${harness.directory.path}/proj/maclauncher.json',
        );
        manifest.writeAsStringSync('''
{
  "schemaVersion": 1,
  "project": {"id": "project-a", "name": "项目甲"},
  "services": []
}
''');
        await harness.refresher.refresh('project-a');
        expect(harness.refresher.retainedServices('project-a'), hasLength(1));

        await tester.pumpWidget(harness.app());
        await settle(tester);

        expect(find.textContaining('声明已移除'), findsOneWidget);
        await tester.tap(find.text('清除'));
        await settle(tester);

        expect(find.textContaining('声明已移除'), findsNothing);
        expect(harness.refresher.retainedServices('project-a'), isEmpty);
        // 持久化：重新加载后记录不复活。
        final reloaded = await ConfigRefresher.load(
          harness.bindings,
          '${harness.directory.path}/config_state.json',
        );
        expect(reloaded.retainedServices('project-a'), isEmpty);
      } finally {
        await harness.dispose();
      }
    });
  });
}
