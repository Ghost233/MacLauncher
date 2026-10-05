import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:launcher_core/launcher_core.dart';
import 'package:maclauncher/main.dart';
import 'package:maclauncher_sdk/maclauncher_sdk.dart';

/// Controlled [UpdatePackageDownloader] for widget tests (E08): no network,
/// the test decides progress, completion and failure.
class _FakeDownloader implements UpdatePackageDownloader {
  Object? error;
  var calls = 0;
  Uri? source;
  String? targetPath;
  String? expectedSha256;
  var waitForCancellation = false;

  @override
  Future<DownloadResult> download(
    Uri source,
    String targetPath, {
    String? expectedSha256,
    bool verifyChecksum = true,
    DownloadProgressCallback? onProgress,
    DownloadCancellationToken? cancellationToken,
  }) async {
    calls++;
    this.source = source;
    this.targetPath = targetPath;
    this.expectedSha256 = expectedSha256;
    if (waitForCancellation) {
      onProgress?.call(0, 100);
      while (cancellationToken?.isCancelled != true) {
        await Future<void>.delayed(const Duration(milliseconds: 25));
      }
      throw const DownloadCancelledException();
    }
    onProgress?.call(21, 42);
    final pending = error;
    if (pending != null) throw pending;
    return DownloadResult(
      path: targetPath,
      totalBytes: 42,
      sha256Hex: expectedSha256 ?? 'actual',
      checksumVerified: expectedSha256 != null,
      resumed: false,
    );
  }
}

/// Same shape as the widget_test harness, plus an injectable update service.
class _Harness {
  _Harness._();

  late Directory directory;
  late BindingStore bindings;
  late PreferenceStore preferences;
  late ConfigRefresher refresher;
  late LauncherServer server;
  late ServiceOperations operations;
  late EntryHandoffCoordinator handoff;
  late _FakeDownloader downloader;
  late List<String> opened;
  late AppUpdateService updateService;

  static Future<_Harness> create() async {
    final harness = _Harness._();
    harness.directory = Directory.systemTemp.createTempSync(
      'launcher-update-ui-test-',
    );
    final projectDir = Directory('${harness.directory.path}/proj')
      ..createSync();
    File('${projectDir.path}/maclauncher.json').writeAsStringSync('''
{
  "schemaVersion": 1,
  "project": {"id": "project-a", "name": "项目甲"},
  "services": [{"id": "svc", "name": "测试服务"}]
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
    harness.downloader = _FakeDownloader();
    harness.opened = [];
    harness.updateService = AppUpdateService(
      layout: harness.server.layout,
      downloader: harness.downloader,
      opener: (path) async {
        harness.opened.add(path);
        return null;
      },
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
    updateService: updateService,
  );

  Future<MacLauncherSdk> connectSdk({
    required Future<VersionStatus> Function()? onVersionStatus,
  }) async {
    final sdk = MacLauncherSdk.connect(
      projectId: 'project-a',
      socketPath: server.layout.socketPath,
      services: {
        'svc': ServiceCallbacks(
          name: '测试服务',
          onStatus: () async => ServiceStatus(state: ServiceState.running),
        ),
      },
      app: AppCallbacks(onVersionStatus: onVersionStatus),
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
  testWidgets('连接建立时自动查询一次，成功状况展示版本号与下载入口', (tester) async {
    await tester.runAsync(() async {
      final harness = await _Harness.create();
      var queries = 0;
      MacLauncherSdk? sdk;
      try {
        await tester.pumpWidget(harness.app());
        // Not connected: the unknown state must not invent anything.
        expect(find.textContaining('状态未知（应用未连接）'), findsOneWidget);
        expect(find.text('下载更新'), findsNothing);

        sdk = await harness.connectSdk(
          onVersionStatus: () async {
            queries++;
            return VersionStatus(
              state: VersionQueryState.success,
              currentVersion: '1.2.0',
              hasUpdate: true,
              latestVersion: '1.3.0',
              downloadUrl: 'https://example.com/app-1.3.0.dmg',
              sha256: 'abc123',
            );
          },
        );
        await settle(tester);

        expect(find.textContaining('当前版本 1.2.0'), findsOneWidget);
        expect(find.textContaining('有新版本 1.3.0'), findsOneWidget);
        expect(find.text('下载更新'), findsOneWidget);
        // Exactly one automatic query on connection establishment.
        expect(queries, 1);

        // Manual refresh queries again.
        await tester.tap(find.byTooltip('重新查询版本状况'));
        await settle(tester);
        expect(queries, 2);
      } finally {
        await sdk?.dispose();
        await harness.dispose();
      }
    });
  });

  testWidgets('失败原因逐字呈现，且无下载入口', (tester) async {
    await tester.runAsync(() async {
      final harness = await _Harness.create();
      MacLauncherSdk? sdk;
      try {
        await tester.pumpWidget(harness.app());
        sdk = await harness.connectSdk(
          onVersionStatus: () async => VersionStatus(
            state: VersionQueryState.failure,
            failureReason: '更新源不可达',
          ),
        );
        await settle(tester);

        expect(find.textContaining('查询失败：更新源不可达'), findsOneWidget);
        expect(find.text('下载更新'), findsNothing);
      } finally {
        await sdk?.dispose();
        await harness.dispose();
      }
    });
  });

  testWidgets('应用未提供版本状况能力时呈现不支持更新', (tester) async {
    await tester.runAsync(() async {
      final harness = await _Harness.create();
      MacLauncherSdk? sdk;
      try {
        await tester.pumpWidget(harness.app());
        sdk = await harness.connectSdk(onVersionStatus: null);
        await settle(tester);

        expect(find.textContaining('不支持更新'), findsOneWidget);
        expect(find.text('下载更新'), findsNothing);
      } finally {
        await sdk?.dispose();
        await harness.dispose();
      }
    });
  });

  testWidgets('查询超时呈现状态未知', (tester) async {
    await tester.runAsync(() async {
      final harness = await _Harness.create();
      MacLauncherSdk? sdk;
      try {
        await tester.pumpWidget(harness.app());
        sdk = await harness.connectSdk(
          // Never completes: the launcher must time out into 状态未知.
          onVersionStatus: () => Completer<VersionStatus>().future,
        );
        // Harness operation timeout is 2s; wait past it.
        await settle(tester, const Duration(seconds: 3));

        expect(find.textContaining('状态未知（timeout）'), findsOneWidget);
        expect(find.text('下载更新'), findsNothing);
      } finally {
        await sdk?.dispose();
        await harness.dispose();
      }
    });
  });

  testWidgets('已是最新与缺少下载地址均无下载入口', (tester) async {
    await tester.runAsync(() async {
      final harness = await _Harness.create();
      var status = VersionStatus(
        state: VersionQueryState.success,
        currentVersion: '1.2.0',
        hasUpdate: false,
      );
      MacLauncherSdk? sdk;
      try {
        await tester.pumpWidget(harness.app());
        sdk = await harness.connectSdk(onVersionStatus: () async => status);
        await settle(tester);

        expect(find.textContaining('当前版本 1.2.0'), findsOneWidget);
        expect(find.textContaining('已是最新'), findsOneWidget);
        expect(find.text('下载更新'), findsNothing);

        // A newer version without a download address: shown, but no button.
        status = VersionStatus(
          state: VersionQueryState.success,
          currentVersion: '1.2.0',
          hasUpdate: true,
          latestVersion: '1.3.0',
        );
        await tester.tap(find.byTooltip('重新查询版本状况'));
        await settle(tester);

        expect(find.textContaining('有新版本 1.3.0'), findsOneWidget);
        expect(find.textContaining('应用未提供下载地址'), findsOneWidget);
        expect(find.text('下载更新'), findsNothing);
      } finally {
        await sdk?.dispose();
        await harness.dispose();
      }
    });
  });

  testWidgets('下载更新触发代下载，完成后校验通过并提示手动安装', (tester) async {
    await tester.runAsync(() async {
      final harness = await _Harness.create();
      MacLauncherSdk? sdk;
      try {
        await tester.pumpWidget(harness.app());
        sdk = await harness.connectSdk(
          onVersionStatus: () async => VersionStatus(
            state: VersionQueryState.success,
            currentVersion: '1.2.0',
            hasUpdate: true,
            latestVersion: '1.3.0',
            downloadUrl: 'https://example.com/app-1.3.0.dmg',
            sha256: 'abc123',
          ),
        );
        await settle(tester);

        await tester.tap(find.text('下载更新'));
        await settle(tester);

        // The injected downloader got the verbatim URL, digest and target.
        expect(harness.downloader.calls, 1);
        expect(
          harness.downloader.source,
          Uri.parse('https://example.com/app-1.3.0.dmg'),
        );
        expect(harness.downloader.expectedSha256, 'abc123');
        final expectedPath =
            '${harness.directory.path}/endpoint/downloads/project-a/app-1.3.0.dmg';
        expect(harness.downloader.targetPath, expectedPath);
        expect(harness.opened, [expectedPath]);

        // Completion dialog: verification verdict, path, manual install.
        expect(find.text('已下载并打开更新包'), findsOneWidget);
        expect(find.textContaining('sha256 校验通过'), findsOneWidget);
        expect(
          find.textContaining(expectedPath, findRichText: true),
          findsOneWidget,
        );
        expect(find.textContaining('手动完成替换安装'), findsOneWidget);

        await tester.tap(find.text('知道了'));
        await settle(tester);
      } finally {
        await sdk?.dispose();
        await harness.dispose();
      }
    });
  });

  testWidgets('未提供校验值时需确认，取消不下载，继续则下载并说明未校验', (tester) async {
    await tester.runAsync(() async {
      final harness = await _Harness.create();
      MacLauncherSdk? sdk;
      try {
        await tester.pumpWidget(harness.app());
        sdk = await harness.connectSdk(
          onVersionStatus: () async => VersionStatus(
            state: VersionQueryState.success,
            currentVersion: '1.2.0',
            hasUpdate: true,
            latestVersion: '1.3.0',
            downloadUrl: 'https://example.com/app-1.3.0.dmg',
          ),
        );
        await settle(tester);

        await tester.tap(find.text('下载更新'));
        await settle(tester);
        expect(find.text('未提供校验值'), findsOneWidget);

        // Cancel: nothing is downloaded.
        await tester.tap(find.text('取消'));
        await settle(tester);
        expect(harness.downloader.calls, 0);

        // Confirm: the download runs and reports the missing verification.
        await tester.tap(find.text('下载更新'));
        await settle(tester);
        await tester.tap(find.text('继续下载'));
        await settle(tester);
        expect(harness.downloader.calls, 1);
        expect(harness.downloader.expectedSha256, isNull);
        expect(find.textContaining('未做完整性校验'), findsOneWidget);

        await tester.tap(find.text('知道了'));
        await settle(tester);
      } finally {
        await sdk?.dispose();
        await harness.dispose();
      }
    });
  });

  testWidgets('下载失败就地呈现原因并可重试', (tester) async {
    await tester.runAsync(() async {
      final harness = await _Harness.create();
      harness.downloader.error = DownloadHttpException(
        Uri.parse('https://example.com/app-1.3.0.dmg'),
        404,
      );
      MacLauncherSdk? sdk;
      try {
        await tester.pumpWidget(harness.app());
        sdk = await harness.connectSdk(
          onVersionStatus: () async => VersionStatus(
            state: VersionQueryState.success,
            currentVersion: '1.2.0',
            hasUpdate: true,
            latestVersion: '1.3.0',
            downloadUrl: 'https://example.com/app-1.3.0.dmg',
            sha256: 'abc123',
          ),
        );
        await settle(tester);

        await tester.tap(find.text('下载更新'));
        await settle(tester);
        expect(find.textContaining('下载失败：'), findsOneWidget);
        expect(find.textContaining('404'), findsOneWidget);
        expect(find.text('重试下载'), findsOneWidget);

        harness.downloader.error = null;
        await tester.tap(find.text('重试下载'));
        await settle(tester);
        expect(harness.downloader.calls, 2);
        expect(find.text('已下载并打开更新包'), findsOneWidget);

        await tester.tap(find.text('知道了'));
        await settle(tester);
      } finally {
        await sdk?.dispose();
        await harness.dispose();
      }
    });
  });

  testWidgets('未提供校验值：首次确认后下载失败，重试仍需再次确认', (tester) async {
    await tester.runAsync(() async {
      final harness = await _Harness.create();
      harness.downloader.error = DownloadHttpException(
        Uri.parse('https://example.com/app-1.3.0.dmg'),
        500,
      );
      MacLauncherSdk? sdk;
      try {
        await tester.pumpWidget(harness.app());
        sdk = await harness.connectSdk(
          onVersionStatus: () async => VersionStatus(
            state: VersionQueryState.success,
            currentVersion: '1.2.0',
            hasUpdate: true,
            latestVersion: '1.3.0',
            downloadUrl: 'https://example.com/app-1.3.0.dmg',
            // No sha256: consent is required on every download attempt.
          ),
        );
        await settle(tester);

        // First attempt: consent dialog, then the download fails.
        await tester.tap(find.text('下载更新'));
        await settle(tester);
        expect(find.text('未提供校验值'), findsOneWidget);
        await tester.tap(find.text('继续下载'));
        await settle(tester);
        expect(harness.downloader.calls, 1);
        expect(find.textContaining('下载失败：'), findsOneWidget);
        expect(find.text('重试下载'), findsOneWidget);

        // Retry must re-ask for consent, not download silently.
        await tester.tap(find.text('重试下载'));
        await settle(tester);
        expect(find.text('未提供校验值'), findsOneWidget);
        expect(harness.downloader.calls, 1);

        // Declining the retry consent downloads nothing.
        await tester.tap(find.text('取消'));
        await settle(tester);
        expect(harness.downloader.calls, 1);

        // Confirming the retry runs the download again.
        harness.downloader.error = null;
        await tester.tap(find.text('重试下载'));
        await settle(tester);
        await tester.tap(find.text('继续下载'));
        await settle(tester);
        expect(harness.downloader.calls, 2);
        expect(harness.downloader.expectedSha256, isNull);
        expect(find.text('已下载并打开更新包'), findsOneWidget);

        await tester.tap(find.text('知道了'));
        await settle(tester);
      } finally {
        await sdk?.dispose();
        await harness.dispose();
      }
    });
  });

  testWidgets('下载中可取消，呈现取消路径与断点续传提示', (tester) async {
    await tester.runAsync(() async {
      final harness = await _Harness.create();
      harness.downloader.waitForCancellation = true;
      MacLauncherSdk? sdk;
      try {
        await tester.pumpWidget(harness.app());
        sdk = await harness.connectSdk(
          onVersionStatus: () async => VersionStatus(
            state: VersionQueryState.success,
            currentVersion: '1.2.0',
            hasUpdate: true,
            latestVersion: '1.3.0',
            downloadUrl: 'https://example.com/app-1.3.0.dmg',
            sha256: 'abc123',
          ),
        );
        await settle(tester);

        await tester.tap(find.text('下载更新'));
        await settle(tester);
        // Progress is visible while the download runs.
        expect(find.byType(LinearProgressIndicator), findsOneWidget);

        await tester.tap(find.text('取消'));
        await settle(tester);
        expect(find.textContaining('已取消下载'), findsOneWidget);
        expect(find.textContaining('断点续传'), findsOneWidget);
      } finally {
        await sdk?.dispose();
        await harness.dispose();
      }
    });
  });
}
