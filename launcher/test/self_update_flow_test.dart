import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:launcher_core/launcher_core.dart';
import 'package:maclauncher/main.dart';
import 'package:maclauncher/self_update_flow.dart';

/// Polls a real-async condition inside `tester.runAsync`: downloads,
/// preference writes and dialog openings all complete on real futures.
Future<void> waitFor(Future<bool> Function() condition) async {
  for (var attempt = 0; attempt < 200; attempt++) {
    if (await condition()) return;
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
  fail('condition was not met in time');
}

class _FakeChecker extends UpdateChecker {
  _FakeChecker(String currentVersion, this._result)
    : super(currentVersion: currentVersion);

  UpdateCheckResult _result;

  set result(UpdateCheckResult value) => _result = value;

  @override
  Future<UpdateCheckResult> checkForUpdate() async => _result;
}

class _FakeDownloader implements UpdatePackageDownloader {
  /// Per-test behavior; defaults to an instantly successful download.
  Future<DownloadResult> Function(
    Uri source,
    String targetPath, {
    String? expectedSha256,
    bool verifyChecksum,
    DownloadProgressCallback? onProgress,
    DownloadCancellationToken? cancellationToken,
  })?
  handler;

  final seen = <bool>{};
  var calls = 0;

  @override
  Future<DownloadResult> download(
    Uri source,
    String targetPath, {
    String? expectedSha256,
    bool verifyChecksum = true,
    DownloadProgressCallback? onProgress,
    DownloadCancellationToken? cancellationToken,
  }) {
    calls++;
    seen.add(verifyChecksum);
    final behavior = handler;
    if (behavior != null) {
      return behavior(
        source,
        targetPath,
        expectedSha256: expectedSha256,
        verifyChecksum: verifyChecksum,
        onProgress: onProgress,
        cancellationToken: cancellationToken,
      );
    }
    onProgress?.call(50, 100);
    return Future.value(
      DownloadResult(
        path: targetPath,
        totalBytes: 100,
        sha256Hex: expectedSha256 ?? 'actual',
        checksumVerified: verifyChecksum && expectedSha256 != null,
        resumed: false,
      ),
    );
  }
}

/// Wired environment: temp stores, an injectable checker/downloader/opener
/// and a relaunch recorder, all behind the seams issue #31 requires.
class _Env {
  late Directory directory;
  late PreferenceStore prefs;
  late BindingStore bindings;
  late ConfigRefresher refresher;
  late _FakeChecker checker;
  late _FakeDownloader downloader;
  late SelfUpdateFlow flow;
  final openedPaths = <String>[];
  var relaunchCalls = 0;
  String? relaunchResult; // null = relaunch initiated
  var checkerCalls = 0;

  Future<void> setUp({
    bool checkOnLaunch = true,
    bool autoDownload = false,
  }) async {
    directory = Directory.systemTemp.createTempSync('self-update-flow-test-');
    prefs = await PreferenceStore.load('${directory.path}/preferences.json');
    if (!checkOnLaunch) await prefs.setUpdateCheckOnLaunch(false);
    if (autoDownload) await prefs.setUpdateAutoDownload(true);
    bindings = await BindingStore.load('${directory.path}/bindings.json');
    refresher = await ConfigRefresher.load(
      bindings,
      '${directory.path}/config_state.json',
    );
    checker = _FakeChecker(
      '1.0.0',
      const UpdateCheckSuccess(hasUpdate: false, latestVersion: '1.0.0'),
    );
    downloader = _FakeDownloader();
    flow = SelfUpdateFlow(
      preferences: prefs,
      service: SelfUpdateService(
        layout: EndpointLayout(directory: directory.path),
        versionResolver: () async => '1.0.0',
        checkerFactory: (v) {
          checkerCalls++;
          return checker;
        },
        downloader: downloader,
        opener: (path) async {
          openedPaths.add(path);
          return null;
        },
      ),
      relauncher: () async {
        relaunchCalls++;
        return relaunchResult;
      },
    );
  }

  void tearDown() {
    flow.dispose();
    if (directory.existsSync()) directory.deleteSync(recursive: true);
  }

  UpdateCheckResult updateAvailable({String? sha256 = 'abc'}) =>
      UpdateCheckSuccess(
        hasUpdate: true,
        latestVersion: '1.3.0',
        dmgDownloadUrl: Uri.parse(
          'https://downloads.example.com/MacLauncher-1.3.0.dmg',
        ),
        sha256: sha256,
      );

  Future<void> pumpApp(WidgetTester tester) async {
    await tester.pumpWidget(
      MacLauncherApp(
        bindings: bindings,
        preferences: prefs,
        refresher: refresher,
        selfUpdateFlow: flow,
      ),
    );
    await tester.pump();
  }

  Future<void> openSettings(WidgetTester tester) async {
    await tester.tap(find.byTooltip('设置'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
  }
}

void main() {
  late _Env env;

  tearDown(() => env.tearDown());

  testWidgets('偏好关闭时不发起启动检查，也没有提示', (tester) async {
    await tester.runAsync(() async {
      env = _Env();
      await env.setUp(checkOnLaunch: false);
      env.checker.result = env.updateAvailable();
      await env.pumpApp(tester);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      await tester.pump();
      expect(env.checkerCalls, 0);
      expect(find.text('发现新版本'), findsNothing);
    });
  });

  testWidgets('启动检查无新版时保持静默', (tester) async {
    await tester.runAsync(() async {
      env = _Env();
      await env.setUp();
      await env.pumpApp(tester);
      await waitFor(() async => env.checkerCalls > 0);
      await tester.pump();
      expect(find.text('发现新版本'), findsNothing);
      expect(env.flow.state, isA<SelfUpdateIdle>());
    });
  });

  testWidgets('发现新版→确认下载→完成打开→重启提示→立刻重启', (tester) async {
    await tester.runAsync(() async {
      env = _Env();
      await env.setUp();
      env.checker.result = env.updateAvailable();
      await env.pumpApp(tester);

      // Silent launch check surfaces the prompt.
      await waitFor(() async {
        await tester.pump();
        return find.text('发现新版本').evaluate().isNotEmpty;
      });
      expect(find.text('稍后'), findsOneWidget);

      // Confirm the download: progress state then completion.
      await tester.tap(find.text('下载'));
      await waitFor(() async {
        await tester.pump();
        return find.text('已打开安装包').evaluate().isNotEmpty;
      });
      expect(env.downloader.calls, 1);
      expect(
        env.openedPaths.single,
        '${env.directory.path}/downloads/self/MacLauncher-1.3.0.dmg',
      );
      expect(find.text('sha256 校验通过。'), findsOneWidget);
      expect(find.text('替换完成后是否立刻重启 launcher？'), findsOneWidget);

      // Relaunch goes through the injected seam.
      await tester.tap(find.text('立刻重启'));
      await waitFor(() async => env.relaunchCalls > 0);
      expect(env.relaunchCalls, 1);
    });
  });

  testWidgets('自动下载开启时启动后直接下载', (tester) async {
    await tester.runAsync(() async {
      env = _Env();
      await env.setUp(autoDownload: true);
      env.checker.result = env.updateAvailable();
      await env.pumpApp(tester);
      await waitFor(() async {
        await tester.pump();
        return find.text('已打开安装包').evaluate().isNotEmpty;
      });
      expect(env.downloader.calls, 1);
      expect(env.flow.state, isA<SelfUpdateReadyToRelaunch>());
    });
  });

  testWidgets('下载失败呈现原因并可重试成功', (tester) async {
    await tester.runAsync(() async {
      env = _Env();
      await env.setUp();
      env.checker.result = env.updateAvailable();
      env.downloader.handler =
          (
            source,
            target, {
            expectedSha256,
            verifyChecksum = true,
            onProgress,
            cancellationToken,
          }) async {
            if (env.downloader.calls == 1) {
              throw DownloadHttpException(source, 404);
            }
            return DownloadResult(
              path: target,
              totalBytes: 100,
              sha256Hex: 'abc',
              checksumVerified: true,
              resumed: true,
            );
          };
      await env.pumpApp(tester);
      await waitFor(() async {
        await tester.pump();
        return find.text('发现新版本').evaluate().isNotEmpty;
      });
      await tester.tap(find.text('下载'));
      await waitFor(() async {
        await tester.pump();
        return find.text('下载失败').evaluate().isNotEmpty;
      });
      expect(find.textContaining('404'), findsOneWidget);

      await tester.tap(find.text('重试下载'));
      await waitFor(() async {
        await tester.pump();
        return find.text('已打开安装包').evaluate().isNotEmpty;
      });
      expect(env.downloader.calls, 2);
    });
  });

  testWidgets('校验失败可跳过校验继续', (tester) async {
    await tester.runAsync(() async {
      env = _Env();
      await env.setUp();
      env.checker.result = env.updateAvailable();
      env.downloader.handler =
          (
            source,
            target, {
            expectedSha256,
            verifyChecksum = true,
            onProgress,
            cancellationToken,
          }) async {
            if (env.downloader.calls == 1) {
              throw const DownloadChecksumMismatchException('abc', 'tampered');
            }
            return DownloadResult(
              path: target,
              totalBytes: 100,
              sha256Hex: 'tampered',
              checksumVerified: verifyChecksum && expectedSha256 != null,
              resumed: false,
            );
          };
      await env.pumpApp(tester);
      await waitFor(() async {
        await tester.pump();
        return find.text('发现新版本').evaluate().isNotEmpty;
      });
      await tester.tap(find.text('下载'));
      await waitFor(() async {
        await tester.pump();
        return find.text('校验失败').evaluate().isNotEmpty;
      });
      expect(find.textContaining('期望：abc'), findsOneWidget);
      expect(find.textContaining('实际：tampered'), findsOneWidget);

      await tester.tap(find.text('跳过校验继续'));
      await waitFor(() async {
        await tester.pump();
        return find.text('已打开安装包').evaluate().isNotEmpty;
      });
      expect(env.downloader.calls, 2);
      expect(env.downloader.seen, contains(false)); // verification skipped
      expect(find.text('未做 sha256 完整性校验。'), findsOneWidget);
    });
  });

  testWidgets('下载中可取消，提示关闭回到空闲', (tester) async {
    await tester.runAsync(() async {
      env = _Env();
      await env.setUp();
      env.checker.result = env.updateAvailable();
      env.downloader.handler =
          (
            source,
            target, {
            expectedSha256,
            verifyChecksum = true,
            onProgress,
            cancellationToken,
          }) async {
            while (!(cancellationToken?.isCancelled ?? false)) {
              await Future<void>.delayed(const Duration(milliseconds: 5));
            }
            throw const DownloadCancelledException();
          };
      await env.pumpApp(tester);
      await waitFor(() async {
        await tester.pump();
        return find.text('发现新版本').evaluate().isNotEmpty;
      });
      await tester.tap(find.text('下载'));
      await waitFor(() async {
        await tester.pump();
        return find.text('正在下载 1.3.0').evaluate().isNotEmpty;
      });
      await tester.tap(find.text('取消'));
      await waitFor(() async {
        await tester.pump();
        return find.text('正在下载 1.3.0').evaluate().isEmpty;
      });
      expect(env.flow.state, isA<SelfUpdateIdle>());
    });
  });

  testWidgets('重启失败在同一对话框呈现并可稍后处理', (tester) async {
    await tester.runAsync(() async {
      env = _Env();
      await env.setUp();
      env.checker.result = env.updateAvailable();
      env.relaunchResult = 'open 失败';
      await env.pumpApp(tester);
      await waitFor(() async {
        await tester.pump();
        return find.text('发现新版本').evaluate().isNotEmpty;
      });
      await tester.tap(find.text('下载'));
      await waitFor(() async {
        await tester.pump();
        return find.text('已打开安装包').evaluate().isNotEmpty;
      });
      await tester.tap(find.text('立刻重启'));
      await waitFor(() async {
        await tester.pump();
        return find.textContaining('重启失败：open 失败').evaluate().isNotEmpty;
      });
      expect(env.flow.state, isA<SelfUpdateReadyToRelaunch>());
      await tester.tap(find.text('稍后'));
      await waitFor(() async {
        await tester.pump();
        return env.flow.state is SelfUpdateIdle;
      });
    });
  });

  testWidgets('设置页手动检查：有新版给出下载入口', (tester) async {
    await tester.runAsync(() async {
      env = _Env();
      await env.setUp(checkOnLaunch: false);
      await env.pumpApp(tester);
      await env.openSettings(tester);
      env.checker.result = env.updateAvailable();
      await tester.tap(find.byKey(const ValueKey('update-check-now')));
      await waitFor(() async {
        await tester.pump();
        return find.text('发现新版本 1.3.0。').evaluate().isNotEmpty;
      });
      await tester.tap(find.byKey(const ValueKey('update-download-entry')));
      await waitFor(() async {
        await tester.pump();
        return find.text('已打开安装包').evaluate().isNotEmpty;
      });
      expect(env.downloader.calls, 1);
    });
  });

  testWidgets('设置页手动检查：已是最新与失败两态', (tester) async {
    await tester.runAsync(() async {
      env = _Env();
      await env.setUp(checkOnLaunch: false);
      await env.pumpApp(tester);
      await env.openSettings(tester);

      await tester.tap(find.byKey(const ValueKey('update-check-now')));
      await waitFor(() async {
        await tester.pump();
        return find
            .byKey(const ValueKey('update-check-latest'))
            .evaluate()
            .isNotEmpty;
      });
      expect(find.text('已是最新版本（1.0.0）。'), findsOneWidget);

      env.checker.result = const UpdateCheckFailure('网络不可达');
      await tester.tap(find.byKey(const ValueKey('update-check-now')));
      await waitFor(() async {
        await tester.pump();
        return find
            .byKey(const ValueKey('update-check-failed'))
            .evaluate()
            .isNotEmpty;
      });
      expect(find.text('检查失败：网络不可达'), findsOneWidget);
    });
  });
}
