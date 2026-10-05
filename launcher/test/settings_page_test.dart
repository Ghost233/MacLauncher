import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:launcher_core/launcher_core.dart';
import 'package:maclauncher/main.dart';
import 'package:maclauncher/settings_page.dart';
import 'package:maclauncher/theme.dart';

Finder _switchOf(String key) => find.descendant(
  of: find.byKey(ValueKey(key)),
  matching: find.byType(Switch),
);

/// Polls a real-IO condition inside `tester.runAsync`. Switch toggles apply
/// their state only after the store finishes persisting, so tests must wait
/// for the write instead of assuming a single pump is enough.
Future<void> waitFor(Future<bool> Function() condition) async {
  for (var attempt = 0; attempt < 200; attempt++) {
    if (await condition()) return;
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
  fail('condition was not met in time');
}

void main() {
  late Directory directory;
  late String prefsPath;

  setUp(() {
    directory = Directory.systemTemp.createTempSync('settings-page-test-');
    prefsPath = '${directory.path}/preferences.json';
  });

  tearDown(() {
    if (directory.existsSync()) directory.deleteSync(recursive: true);
  });

  Future<PreferenceStore> loadPrefs() => PreferenceStore.load(prefsPath);

  Future<void> pumpSettings(
    WidgetTester tester,
    PreferenceStore prefs, {
    UpdateCheckCallback? onCheckNow,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.material(),
        home: SettingsPage(
          preferences: prefs,
          onCheckNow: onCheckNow ?? () async {},
        ),
      ),
    );
    await tester.pump();
  }

  testWidgets('三个更新开关展示默认值，自动安装置灰并附说明', (tester) async {
    await tester.runAsync(() async {
      final prefs = await loadPrefs();
      await pumpSettings(tester, prefs);

      expect(
        tester.widget<Switch>(_switchOf('update-check-on-launch')).value,
        isTrue,
      );
      expect(
        tester.widget<Switch>(_switchOf('update-auto-download')).value,
        isFalse,
      );
      final install = tester.widget<Switch>(_switchOf('update-auto-install'));
      expect(install.value, isFalse);
      expect(install.onChanged, isNull);
      expect(find.text('需要签名证书，暂不可用'), findsOneWidget);
    });
  });

  testWidgets('开关切换写入偏好文件并可重读', (tester) async {
    await tester.runAsync(() async {
      final prefs = await loadPrefs();
      await pumpSettings(tester, prefs);

      await tester.tap(_switchOf('update-auto-download'));
      await tester.pump();
      // Optimistic: the UI applies before the write lands.
      expect(
        tester.widget<Switch>(_switchOf('update-auto-download')).value,
        isTrue,
      );
      await waitFor(() async => (await loadPrefs()).updateAutoDownload);

      await tester.tap(_switchOf('update-check-on-launch'));
      await tester.pump();
      expect(
        tester.widget<Switch>(_switchOf('update-check-on-launch')).value,
        isFalse,
      );
      await waitFor(() async => !(await loadPrefs()).updateCheckOnLaunch);

      // Persisted: a fresh store instance sees the same values.
      final reloaded = await loadPrefs();
      expect(reloaded.updateAutoDownload, isTrue);
      expect(reloaded.updateCheckOnLaunch, isFalse);
    });
  });

  testWidgets('持久化失败时回滚开关并提示', (tester) async {
    await tester.runAsync(() async {
      // The parent path is a regular file, so every atomic write fails.
      final blocker = File('${directory.path}/blocked')..writeAsStringSync('x');
      final prefs = await PreferenceStore.load(
        '${blocker.path}/preferences.json',
      );
      await pumpSettings(tester, prefs);

      await tester.tap(_switchOf('update-check-on-launch'));
      await tester.pump();
      // Optimistically applied first…
      expect(
        tester.widget<Switch>(_switchOf('update-check-on-launch')).value,
        isFalse,
      );

      // …then rolled back once the write fails, with a visible hint. Pump
      // while polling: rollback is a setState, which needs a frame.
      var rolledBack = false;
      for (var i = 0; i < 200 && !rolledBack; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 5));
        await tester.pump();
        rolledBack = tester
            .widget<Switch>(_switchOf('update-check-on-launch'))
            .value;
      }
      expect(rolledBack, isTrue, reason: 'switch should roll back on failure');
      expect(find.text('偏好保存失败，请重试。'), findsOneWidget);
      expect(prefs.updateCheckOnLaunch, isTrue);
    });
  });

  testWidgets('置灰的自动安装不可交互，偏好保持不变', (tester) async {
    await tester.runAsync(() async {
      final prefs = await loadPrefs();
      await pumpSettings(tester, prefs);

      await tester.tap(_switchOf('update-auto-install'));
      await tester.pump();

      expect(
        tester.widget<Switch>(_switchOf('update-auto-install')).value,
        isFalse,
      );
      expect(File(prefsPath).existsSync(), isFalse);
      final reloaded = await loadPrefs();
      expect(reloaded.updateAutoInstall, isFalse);
    });
  });

  testWidgets('立即检查更新触发注入的回调', (tester) async {
    await tester.runAsync(() async {
      final prefs = await loadPrefs();
      var calls = 0;
      await pumpSettings(tester, prefs, onCheckNow: () async => calls++);

      await tester.tap(find.byKey(const ValueKey('update-check-now')));
      await tester.pump();
      expect(calls, 1);
    });
  });

  testWidgets('管理页 AppBar 的齿轮入口打开设置页', (tester) async {
    await tester.runAsync(() async {
      final bindings = await BindingStore.load(
        '${directory.path}/bindings.json',
      );
      final prefs = await loadPrefs();
      final refresher = await ConfigRefresher.load(
        bindings,
        '${directory.path}/config_state.json',
      );
      await tester.pumpWidget(
        MacLauncherApp(
          bindings: bindings,
          preferences: prefs,
          refresher: refresher,
        ),
      );
      await tester.pump();

      await tester.tap(find.byIcon(Icons.settings_outlined));
      await tester.pump();
      await tester.pumpAndSettle();

      expect(find.byType(SettingsPage), findsOneWidget);
      expect(find.text('启动时检查新版本'), findsOneWidget);

      // The placeholder seam answers with a neutral snackbar until the
      // update checker (#29) lands.
      await tester.tap(find.byKey(const ValueKey('update-check-now')));
      await tester.pump();
      await tester.pumpAndSettle();
      expect(find.text('更新检查将在后续版本接入。'), findsOneWidget);
    });
  });
}
