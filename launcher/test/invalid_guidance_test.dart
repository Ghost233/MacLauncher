import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:launcher_core/launcher_core.dart';
import 'package:maclauncher/main.dart';

/// Invalid-config guidance tests drive the real stack (temp manifest files,
/// real stores, real association flow) without a server: the management page
/// renders the card from bindings + refresher state alone.
class _Harness {
  _Harness._();

  late Directory directory;
  late BindingStore bindings;
  late PreferenceStore preferences;
  late ConfigRefresher refresher;

  String get projectDir => '${directory.path}/proj';
  String get manifestPath => '$projectDir/maclauncher.json';

  static Future<_Harness> create() async {
    final harness = _Harness._();
    harness.directory = Directory.systemTemp.createTempSync(
      'launcher-invalid-test-',
    );
    writeManifest(harness.projectDir, ['svc-1', 'svc-2']);
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
    return harness;
  }

  static void writeManifest(String dir, List<String> serviceIds) {
    Directory(dir).createSync(recursive: true);
    File('$dir/maclauncher.json').writeAsStringSync('''
{
  "schemaVersion": 1,
  "project": {"id": "project-a", "name": "项目甲"},
  "services": [${serviceIds.map((id) => '{"id": "$id", "name": "$id"}').join(',')}]
}
''');
  }

  MacLauncherApp app({
    Future<void> Function(String projectId)? onUnbindProject,
  }) => MacLauncherApp(
    bindings: bindings,
    preferences: preferences,
    refresher: refresher,
    onUnbindProject: onUnbindProject,
  );

  Future<void> invalidate() async {
    File(manifestPath).deleteSync();
    final result = await refresher.refresh('project-a');
    expect(result, isA<RefreshInvalid>());
  }

  void dispose() {
    if (directory.existsSync()) directory.deleteSync(recursive: true);
  }
}

Future<void> settle(
  WidgetTester tester, [
  Duration delay = const Duration(milliseconds: 400),
]) async {
  await Future<void>.delayed(delay);
  await tester.pump();
}

TextButton buttonOf(WidgetTester tester, String label) =>
    tester.widget<TextButton>(
      find.ancestor(of: find.text(label), matching: find.byType(TextButton)),
    );

void main() {
  testWidgets('invalid card shows both ways out and a one-time explainer', (
    tester,
  ) async {
    await tester.runAsync(() async {
      final harness = await _Harness.create();
      try {
        await harness.invalidate();
        await tester.pumpWidget(harness.app());
        await tester.pump();
        await tester.pumpAndSettle();

        // First time in the invalid state: the one-time explainer.
        expect(find.text('配置失效说明'), findsOneWidget);
        expect(find.textContaining('数据不会丢'), findsOneWidget);
        await tester.tap(find.text('知道了'));
        await tester.pumpAndSettle();
        await settle(tester);

        // Both ways out are on the card.
        expect(find.textContaining('配置失效：'), findsOneWidget);
        expect(find.text('重新选择配置…'), findsOneWidget);
        expect(find.text('解除绑定…'), findsOneWidget);
        // Unbind is not wired yet (issue #41): disabled with a visible reason.
        expect(buttonOf(tester, '解除绑定…').onPressed, isNull);
        expect(find.textContaining('解除绑定将在后续版本提供'), findsOneWidget);

        // The seen flag persisted: a fresh store instance agrees.
        final reloaded = await PreferenceStore.load(
          '${harness.directory.path}/preferences.json',
        );
        expect(reloaded.invalidConfigGuidanceSeen, isTrue);

        // A fresh page state never re-shows the explainer.
        await tester.pumpWidget(const SizedBox());
        await tester.pumpWidget(harness.app());
        await tester.pump();
        await tester.pumpAndSettle();
        expect(find.text('配置失效说明'), findsNothing);
      } finally {
        harness.dispose();
      }
    });
  });

  testWidgets('重新选择 enters a repair flow with recovery wording', (
    tester,
  ) async {
    await tester.runAsync(() async {
      final harness = await _Harness.create();
      const channel = MethodChannel('maclauncher/native');
      try {
        await harness.invalidate();
        // The user moved the project directory: same identity, new path.
        _Harness.writeManifest('${harness.directory.path}/proj-moved', [
          'svc-1',
          'svc-2',
        ]);
        final movedPath =
            '${harness.directory.path}/proj-moved/maclauncher.json';
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(
              channel,
              (call) async => call.method == 'pickManifest' ? movedPath : null,
            );

        // Keep this test focused on the repair flow, not the explainer.
        await harness.preferences.markInvalidConfigGuidanceSeen();
        await tester.pumpWidget(harness.app());
        await tester.pump();
        await tester.pumpAndSettle();
        expect(find.text('配置失效说明'), findsNothing);

        await tester.tap(find.text('重新选择配置…'));
        await tester.pump();
        await settle(tester);
        await tester.pumpAndSettle();

        // Recovery wording, not association-conflict wording.
        expect(find.text('找回项目配置'), findsOneWidget);
        expect(find.text('项目身份冲突'), findsNothing);

        await tester.tap(find.text('迁移原绑定'));
        await tester.pump();
        await settle(tester);
        await tester.pumpAndSettle();

        // Binding migrated to the moved path: the card recovers. (macOS
        // temp dirs resolve /var → /private/var.)
        expect(find.textContaining('配置失效：'), findsNothing);
        expect(harness.refresher.invalidReason('project-a'), isNull);
        expect(
          harness.bindings.bindings.single.manifestPath,
          File(movedPath).resolveSymbolicLinksSync(),
        );
      } finally {
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, null);
        harness.dispose();
      }
    });
  });

  testWidgets('wired unbind confirms first; retained records stay untouched', (
    tester,
  ) async {
    await tester.runAsync(() async {
      final harness = await _Harness.create();
      try {
        // svc-2 becomes a retained read-only record, then the config goes
        // invalid.
        _Harness.writeManifest(harness.projectDir, ['svc-1']);
        await harness.refresher.refresh('project-a');
        expect(harness.refresher.retainedServices('project-a'), hasLength(1));
        await harness.invalidate();

        final unbound = <String>[];
        await harness.preferences.markInvalidConfigGuidanceSeen();
        await tester.pumpWidget(
          harness.app(
            onUnbindProject: (projectId) async => unbound.add(projectId),
          ),
        );
        await tester.pump();
        await tester.pumpAndSettle();

        // The retained record sits alongside the guidance.
        expect(find.textContaining('保留只读记录'), findsOneWidget);
        expect(buttonOf(tester, '解除绑定…').onPressed, isNotNull);

        await tester.tap(find.text('解除绑定…'));
        await tester.pump();
        await tester.pumpAndSettle();

        // Confirmation first; nothing has been unbound yet.
        expect(find.text('解除绑定'), findsWidgets);
        expect(unbound, isEmpty);

        await tester.tap(find.widgetWithText(FilledButton, '解除绑定'));
        await tester.pump();
        await settle(tester);
        await tester.pumpAndSettle();

        expect(unbound, ['project-a']);
        // Guidance actions never touch retained read-only records.
        expect(find.textContaining('保留只读记录'), findsOneWidget);
        expect(harness.refresher.retainedServices('project-a'), hasLength(1));
      } finally {
        harness.dispose();
      }
    });
  });
}
