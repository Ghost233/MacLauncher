import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:launcher_core/launcher_core.dart';
import 'package:maclauncher_sdk/maclauncher_sdk.dart';

import 'launcher_test_harness.dart';

void main() {
  const switchKey = ValueKey('menu-bar-project-a');

  testWidgets(
    'offline project can save menu-bar permission before connecting',
    (tester) async {
      await tester.runAsync(() async {
        final harness = await LauncherTestHarness.create(services: {});
        try {
          await tester.pumpWidget(harness.app());
          expect(
            tester.widget<SwitchListTile>(find.byKey(switchKey)).value,
            isFalse,
          );
          expect(find.text('等待应用连接后应用'), findsOneWidget);
          await tester.tap(find.text('允许应用显示菜单栏'));
          await settle(tester);
          expect(
            tester.widget<SwitchListTile>(find.byKey(switchKey)).value,
            isTrue,
          );
          final reloaded = await PreferenceStore.load(
            '${harness.directory.path}/preferences.json',
          );
          expect(reloaded.isMenuBarAllowed('project-a'), isTrue);
        } finally {
          await harness.dispose();
        }
      });
    },
  );

  testWidgets(
    'permission respects the app setting without leaving launcher mode',
    (tester) async {
      await tester.runAsync(() async {
        final harness = await LauncherTestHarness.create(
          services: {},
          withServer: true,
        );
        MacLauncherSdk? sdk;
        final calls = <bool>[];
        var appWantsVisible = true;
        var visible = false;
        try {
          await tester.pumpWidget(harness.app());
          sdk = await harness.connectSdk(
            {},
            app: AppCallbacks(
              onSetEntryManaged: (managed) async {
                calls.add(managed);
                visible = !managed && appWantsVisible;
                return true;
              },
            ),
          );
          await settle(tester);
          appWantsVisible = false;
          await tester.tap(find.text('允许应用显示菜单栏'));
          await settle(tester);
          expect(calls, [true, false]);
          expect(visible, isFalse);
          expect(find.text('菜单栏：由应用决定'), findsOneWidget);
          expect(find.text('应用连接：已连接'), findsOneWidget);
        } finally {
          await sdk?.dispose();
          await harness.dispose();
        }
      });
    },
  );

  testWidgets(
    'unsupported connected app has a disabled switch and explanation',
    (tester) async {
      await tester.runAsync(() async {
        final harness = await LauncherTestHarness.create(
          services: {},
          withServer: true,
        );
        MacLauncherSdk? sdk;
        try {
          await tester.pumpWidget(harness.app());
          sdk = await harness.connectSdk({});
          await settle(tester);
          final toggle = tester.widget<SwitchListTile>(find.byKey(switchKey));
          expect(toggle.onChanged, isNull);
          expect(find.text('应用不支持菜单栏控制'), findsOneWidget);
          expect(find.text('应用连接：已连接'), findsOneWidget);
        } finally {
          await sdk?.dispose();
          await harness.dispose();
        }
      });
    },
  );

  testWidgets('failed change keeps selection and exposes a working retry', (
    tester,
  ) async {
    await tester.runAsync(() async {
      final harness = await LauncherTestHarness.create(
        services: {},
        withServer: true,
      );
      MacLauncherSdk? sdk;
      var confirm = true;
      try {
        await tester.pumpWidget(harness.app());
        sdk = await harness.connectSdk(
          {},
          app: AppCallbacks(onSetEntryManaged: (_) async => confirm),
        );
        await settle(tester);
        confirm = false;
        await tester.tap(find.text('允许应用显示菜单栏'));
        await settle(tester);
        expect(
          tester.widget<SwitchListTile>(find.byKey(switchKey)).value,
          isTrue,
        );
        expect(find.text('菜单栏：尚未应用'), findsOneWidget);
        confirm = true;
        await tester.tap(find.text('重试'));
        await settle(tester);
        expect(find.text('菜单栏：由应用决定'), findsOneWidget);
        expect(find.text('重试'), findsNothing);
      } finally {
        await sdk?.dispose();
        await harness.dispose();
      }
    });
  });
}
