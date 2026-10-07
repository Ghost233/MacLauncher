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

    test(
      'update preferences default on an old file without the section',
      () async {
        // A preference file written before update preferences existed.
        File(prefsPath).writeAsStringSync('{"proj-a": {"svc-1": true}}');

        final store = await PreferenceStore.load(prefsPath);
        expect(store.updateCheckOnLaunch, isTrue);
        expect(store.updateAutoDownload, isFalse);
        expect(store.updateAutoInstall, isFalse);
        // The old login-start entries still load, and the reserved section
        // never leaks into the project view.
        expect(store.isLoginStartEnabled('proj-a', 'svc-1'), isTrue);
        expect(store.projects, {'proj-a'});
      },
    );

    test('update preferences round-trip through save and reload', () async {
      final store = await PreferenceStore.load(prefsPath);
      await store.setUpdateCheckOnLaunch(false);
      await store.setUpdateAutoDownload(true);

      final reloaded = await PreferenceStore.load(prefsPath);
      expect(reloaded.updateCheckOnLaunch, isFalse);
      expect(reloaded.updateAutoDownload, isTrue);
      expect(reloaded.updateAutoInstall, isFalse);

      final mode = FileStat.statSync(prefsPath).mode & 0xFFF;
      expect(mode, int.parse('600', radix: 8));
      // The updates section is not a project.
      expect(reloaded.projects, isEmpty);
    });

    test('update and login-start preferences coexist in one file', () async {
      final store = await PreferenceStore.load(prefsPath);
      await store.setLoginStartEnabled('proj-a', 'svc-1', true);
      await store.setUpdateAutoDownload(true);

      final reloaded = await PreferenceStore.load(prefsPath);
      expect(reloaded.isLoginStartEnabled('proj-a', 'svc-1'), isTrue);
      expect(reloaded.updateAutoDownload, isTrue);
      expect(reloaded.projects, {'proj-a'});
    });

    test(
      'invalid-config guidance seen flag defaults to false on an old file',
      () async {
        // A preference file written before the guidance flag existed.
        File(prefsPath).writeAsStringSync('{"proj-a": {"svc-1": true}}');

        final store = await PreferenceStore.load(prefsPath);
        expect(store.invalidConfigGuidanceSeen, isFalse);
        expect(store.isLoginStartEnabled('proj-a', 'svc-1'), isTrue);
        expect(store.projects, {'proj-a'});
      },
    );

    test(
      'invalid-config guidance seen flag round-trips through save and reload',
      () async {
        final store = await PreferenceStore.load(prefsPath);
        expect(store.invalidConfigGuidanceSeen, isFalse);

        await store.markInvalidConfigGuidanceSeen();

        final reloaded = await PreferenceStore.load(prefsPath);
        expect(reloaded.invalidConfigGuidanceSeen, isTrue);
        // The guidance section is not a project and never leaks into the
        // project view; update preferences are untouched.
        expect(reloaded.projects, isEmpty);
        expect(reloaded.updateCheckOnLaunch, isTrue);

        final mode = FileStat.statSync(prefsPath).mode & 0xFFF;
        expect(mode, int.parse('600', radix: 8));
      },
    );
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
        startService: (_, _) async {
          calls++;
          return const OperationAcknowledged();
        },
      );
      final second = await notifier.runOnce(
        bindings: bindings,
        startService: (_, _) async {
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
          startService: (_, _) async {
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
  group('corrupted storage', () {
    test('malformed JSON is backed up and the store starts empty', () async {
      File(prefsPath).writeAsStringSync('{"proj-a": broken');

      final store = await PreferenceStore.load(prefsPath);

      expect(store.projects, isEmpty);
      expect(store.updateCheckOnLaunch, isTrue); // defaults still apply
      final report = store.corruptionReport;
      expect(report, isNotNull);
      expect(report!.filePath, prefsPath);
      expect(report.skippedRecords, 0);
      expect(File(prefsPath).existsSync(), isFalse);
      expect(report.backupPath, isNotNull);
      expect(report.backupPath, contains('.corrupt-'));
      expect(File(report.backupPath!).readAsStringSync(), '{"proj-a": broken');
    });

    test(
      'a non-map top level is backed up and the store starts empty',
      () async {
        File(prefsPath).writeAsStringSync('["proj-a"]');

        final store = await PreferenceStore.load(prefsPath);

        expect(store.projects, isEmpty);
        final report = store.corruptionReport;
        expect(report, isNotNull);
        expect(report!.backupPath, isNotNull);
        expect(File(prefsPath).existsSync(), isFalse);
        expect(File(report.backupPath!).readAsStringSync(), '["proj-a"]');
      },
    );

    test('invalid entries are skipped while good entries are kept', () async {
      File(prefsPath).writeAsStringSync(
        const JsonEncoder.withIndent('  ').convert({
          'proj-good': {'svc-1': true},
          'proj-bad': 42, // not a service map
          '@updates': {'checkOnLaunch': false},
        }),
      );

      final store = await PreferenceStore.load(prefsPath);

      expect(store.isLoginStartEnabled('proj-good', 'svc-1'), isTrue);
      expect(store.projects, {'proj-good'});
      expect(store.updateCheckOnLaunch, isFalse);
      expect(File(prefsPath).existsSync(), isTrue);
      final report = store.corruptionReport;
      expect(report, isNotNull);
      expect(report!.filePath, prefsPath);
      expect(report.backupPath, isNull);
      expect(report.skippedRecords, 1);
    });

    test('discovery ignore list persists across a restart', () async {
      final store = await PreferenceStore.load(prefsPath);
      expect(store.ignoredDiscoveryProjects, isEmpty);

      await store.setDiscoveryIgnored('proj-x', true);
      await store.setDiscoveryIgnored('proj-y', true);
      await store.setDiscoveryIgnored('proj-x', true); // no-op
      expect(store.ignoredDiscoveryProjects, {'proj-x', 'proj-y'});

      final reloaded = await PreferenceStore.load(prefsPath);
      expect(reloaded.ignoredDiscoveryProjects, {'proj-x', 'proj-y'});

      await reloaded.setDiscoveryIgnored('proj-x', false);
      expect(reloaded.ignoredDiscoveryProjects, {'proj-y'});
      final again = await PreferenceStore.load(prefsPath);
      expect(again.ignoredDiscoveryProjects, {'proj-y'});
      expect(again.corruptionReport, isNull);
    });

    test(
      'unignoring the last project removes the @discovery section',
      () async {
        final store = await PreferenceStore.load(prefsPath);
        await store.setDiscoveryIgnored('proj-x', true);
        await store.setDiscoveryIgnored('proj-x', false);

        final raw = (jsonDecode(File(prefsPath).readAsStringSync()) as Map)
            .cast<String, Object?>();
        expect(raw.containsKey('@discovery'), isFalse);
      },
    );

    test(
      'legacy files without @discovery load with an empty ignore list',
      () async {
        File(prefsPath).writeAsStringSync(
          const JsonEncoder.withIndent('  ').convert({
            '@guidance': {'invalidConfigSeen': true},
            'proj-a': {'svc-1': true},
          }),
        );

        final store = await PreferenceStore.load(prefsPath);

        expect(store.ignoredDiscoveryProjects, isEmpty);
        expect(store.invalidConfigGuidanceSeen, isTrue);
        expect(store.isLoginStartEnabled('proj-a', 'svc-1'), isTrue);
        expect(store.corruptionReport, isNull);
      },
    );

    test('malformed @discovery entries are tolerated', () async {
      File(prefsPath).writeAsStringSync(
        const JsonEncoder.withIndent('  ').convert({
          '@discovery': {
            'ignored': ['proj-x', 42, '', 'proj-y'],
          },
        }),
      );

      final store = await PreferenceStore.load(prefsPath);

      expect(store.ignoredDiscoveryProjects, {'proj-x', 'proj-y'});
      expect(store.corruptionReport, isNull);
    });
  });
}
