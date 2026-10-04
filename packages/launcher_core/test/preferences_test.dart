import 'dart:convert';
import 'dart:io';

import 'package:launcher_core/launcher_core.dart';
import 'package:maclauncher_sdk/maclauncher_sdk.dart';
import 'package:minimal_app/fake_business.dart';
import 'package:test/test.dart';

import 'support.dart';

void main() {
  late Directory temp;
  late String prefsPath;

  setUp(() {
    temp = Directory.systemTemp.createTempSync('launcher-prefs-test');
    prefsPath = '${temp.path}/preferences.json';
  });

  tearDown(() {
    if (temp.existsSync()) temp.deleteSync(recursive: true);
  });

  String writeProject(String name, String projectId, List<String> serviceIds) {
    final dir = Directory('${temp.path}/$name')..createSync();
    final file = File('${dir.path}/$kManifestFileName');
    file.writeAsStringSync(
      const JsonEncoder.withIndent('  ').convert({
        'schemaVersion': 1,
        'project': {'id': projectId, 'name': name},
        'services': [
          for (final id in serviceIds) {'id': id, 'name': id},
        ],
      }),
    );
    return file.path;
  }

  group('PreferenceStore', () {
    test('login-start preferences persist across a launcher restart', () async {
      final store = await PreferenceStore.load(prefsPath);
      await store.setLoginStartEnabled('proj-a', 'svc-1', true);

      // A restarted launcher is a new store instance over the same file.
      final reloaded = await PreferenceStore.load(prefsPath);
      expect(reloaded.isLoginStartEnabled('proj-a', 'svc-1'), isTrue);
      expect(reloaded.isLoginStartEnabled('proj-a', 'svc-2'), isFalse);
      expect(reloaded.isLoginStartEnabled('proj-b', 'svc-1'), isFalse);

      final mode = FileStat.statSync(prefsPath).mode & 0xFFF;
      expect(mode, int.parse('600', radix: 8));
    });

    test('disabling removes the entry and survives reload', () async {
      final store = await PreferenceStore.load(prefsPath);
      await store.setLoginStartEnabled('proj-a', 'svc-1', true);
      await store.setLoginStartEnabled('proj-a', 'svc-1', false);

      final reloaded = await PreferenceStore.load(prefsPath);
      expect(reloaded.isLoginStartEnabled('proj-a', 'svc-1'), isFalse);
      expect(reloaded.projects, isEmpty);
    });

    test('removeProject drops all services of that project only', () async {
      final store = await PreferenceStore.load(prefsPath);
      await store.setLoginStartEnabled('proj-a', 'svc-1', true);
      await store.setLoginStartEnabled('proj-a', 'svc-2', true);
      await store.setLoginStartEnabled('proj-b', 'svc-1', true);

      await store.removeProject('proj-a');

      expect(store.enabledServices('proj-a'), isEmpty);
      expect(store.isLoginStartEnabled('proj-b', 'svc-1'), isTrue);
    });

    test('recycling a running service never clears its preference', () async {
      // Full real stack: server + real SDK peer + operations recycle.
      final manifestPath = writeProject('proj', 'proj-a', ['svc-1']);
      final bindings = await BindingStore.load('${temp.path}/bindings.json');
      await bindings.associate(manifestPath);
      final prefs = await PreferenceStore.load(prefsPath);
      await prefs.setLoginStartEnabled('proj-a', 'svc-1', true);

      final layout = EndpointLayout(directory: '${temp.path}/endpoint');
      final server = await LauncherServer.start(
        layout: layout,
        bindings: bindings,
      );
      addTearDown(server.close);

      final business = FakeBusiness(name: 'svc-1');
      await business.callbacks().onStart!();
      final sdk = MacLauncherSdk.connect(
        projectId: 'proj-a',
        socketPath: layout.socketPath,
        services: {'svc-1': business.callbacks()},
      );
      addTearDown(sdk.dispose);
      await until(() => server.registry.isActive('proj-a'));

      final operations = ServiceOperations(
        server: server,
        scope: BindingServiceScope(bindings),
      );
      final outcome = await operations.recycle('proj-a', 'svc-1');
      expect(outcome, isA<OperationAcknowledged>());
      expect(business.recycleCalls, 1);

      // The preference is untouched: next login still notifies.
      final reloaded = await PreferenceStore.load(prefsPath);
      expect(reloaded.isLoginStartEnabled('proj-a', 'svc-1'), isTrue);
    });
  });

  group('AutostartNotifier', () {
    test('only enabled preferences are notified', () async {
      final manifestPath = writeProject('proj', 'proj-a', ['svc-1', 'svc-2']);
      final bindings = await BindingStore.load('${temp.path}/bindings.json');
      await bindings.associate(manifestPath);
      final prefs = await PreferenceStore.load(prefsPath);
      await prefs.setLoginStartEnabled('proj-a', 'svc-1', true);

      final started = <String>[];
      final notifier = AutostartNotifier(preferences: prefs);
      final report = await notifier.runOnce(
        bindings: bindings,
        startService: (projectId, serviceId) async {
          started.add(serviceId);
          return const OperationAcknowledged();
        },
      );

      expect(started, ['svc-1']);
      expect(report.notified.map((n) => n.serviceId), ['svc-1']);
      expect(report.skipped, isEmpty);
      expect(report.alreadyRan, isFalse);
    });

    test('runOnce is idempotent within one process', () async {
      final manifestPath = writeProject('proj', 'proj-a', ['svc-1']);
      final bindings = await BindingStore.load('${temp.path}/bindings.json');
      await bindings.associate(manifestPath);
      final prefs = await PreferenceStore.load(prefsPath);
      await prefs.setLoginStartEnabled('proj-a', 'svc-1', true);

      var calls = 0;
      final notifier = AutostartNotifier(preferences: prefs);
      await notifier.runOnce(
        bindings: bindings,
        startService: (_, __) async {
          calls++;
          return const OperationAcknowledged();
        },
      );
      final second = await notifier.runOnce(
        bindings: bindings,
        startService: (_, __) async {
          calls++;
          return const OperationAcknowledged();
        },
      );

      expect(calls, 1);
      expect(second.alreadyRan, isTrue);
      expect(second.notified, isEmpty);
    });

    test(
      'an invalid current manifest blocks notification with the reason',
      () async {
        final manifestPath = writeProject('proj', 'proj-a', ['svc-1']);
        final bindings = await BindingStore.load('${temp.path}/bindings.json');
        await bindings.associate(manifestPath);
        final prefs = await PreferenceStore.load(prefsPath);
        await prefs.setLoginStartEnabled('proj-a', 'svc-1', true);

        File(manifestPath).writeAsStringSync('{broken');

        var calls = 0;
        final notifier = AutostartNotifier(preferences: prefs);
        final report = await notifier.runOnce(
          bindings: bindings,
          startService: (_, __) async {
            calls++;
            return const OperationAcknowledged();
          },
        );

        expect(calls, 0);
        expect(report.notified, isEmpty);
        expect(report.skipped.single.serviceId, 'svc-1');
        expect(report.skipped.single.reason, contains('invalidJson'));
      },
    );

    test(
      'a service removed from the current manifest is not notified',
      () async {
        final manifestPath = writeProject('proj', 'proj-a', ['svc-1', 'svc-2']);
        final bindings = await BindingStore.load('${temp.path}/bindings.json');
        await bindings.associate(manifestPath);
        final prefs = await PreferenceStore.load(prefsPath);
        await prefs.setLoginStartEnabled('proj-a', 'svc-1', true);
        await prefs.setLoginStartEnabled('proj-a', 'svc-2', true);

        // The manifest now declares only svc-1.
        writeProject('proj', 'proj-a', ['svc-1']);

        final started = <String>[];
        final notifier = AutostartNotifier(preferences: prefs);
        final report = await notifier.runOnce(
          bindings: bindings,
          startService: (_, serviceId) async {
            started.add(serviceId);
            return const OperationAcknowledged();
          },
        );

        expect(started, ['svc-1']);
        expect(report.skipped.single.serviceId, 'svc-2');
        expect(report.skipped.single.reason, contains('no longer declared'));
      },
    );
  });
}
