import 'dart:convert';
import 'dart:io';

import 'package:launcher_core/launcher_core.dart';
import 'package:test/test.dart';

void main() {
  late Directory temp;
  late BindingStore store;
  late String statePath;
  late List<(String, Set<String>)> pruned;

  setUp(() async {
    temp = Directory.systemTemp.createTempSync('config-refresh-test');
    store = await BindingStore.load('${temp.path}/bindings.json');
    statePath = '${temp.path}/config_refresh_state.json';
    pruned = [];
  });

  tearDown(() {
    if (temp.existsSync()) temp.deleteSync(recursive: true);
  });

  Future<ConfigRefresher> newRefresher() => ConfigRefresher.load(
    store,
    statePath,
    prunePreferences: (projectId, removed) async {
      pruned.add((projectId, removed));
    },
  );

  String writeManifest(
    String dirName,
    Map<String, Object?> content, {
    String projectDir = 'proj',
  }) {
    final dir = Directory('${temp.path}/$projectDir')..createSync();
    final file = File('${dir.path}/$kManifestFileName');
    file.writeAsStringSync(const JsonEncoder.withIndent('  ').convert(content));
    return file.path;
  }

  Map<String, Object?> manifest({
    String id = 'proj-a',
    String name = '项目 A',
    List<Map<String, String>> services = const [
      {'id': 'svc-1', 'name': '服务一'},
      {'id': 'svc-2', 'name': '服务二'},
    ],
  }) => {
    'schemaVersion': 1,
    'project': {'id': id, 'name': name},
    'services': services,
    'integration': {'type': 'sdk'},
  };

  Future<ProjectBinding> bind(String path) => store.associate(path);

  group('valid refresh', () {
    test('applies added/removed/name diffs and preserves boundAt', () async {
      final path = writeManifest('v1', manifest());
      final binding = await bind(path);
      final refresher = await newRefresher();

      writeManifest(
        'v2',
        manifest(
          name: '项目 A2',
          services: [
            {'id': 'svc-2', 'name': '服务二'},
            {'id': 'svc-3', 'name': '服务三'},
          ],
        ),
      );
      final result = await refresher.refresh('proj-a');

      expect(result, isA<RefreshApplied>());
      final applied = result as RefreshApplied;
      expect(applied.added.map((s) => s.id), ['svc-3']);
      expect(applied.removed.map((s) => s.id), ['svc-1']);
      expect(applied.nameChanged, isTrue);

      final updated = store.byProjectId('proj-a')!;
      expect(updated.name, '项目 A2');
      expect(updated.services.map((s) => s.id), ['svc-2', 'svc-3']);
      expect(updated.boundAt, binding.boundAt);

      // Persisted: a fresh store instance sees the same record.
      final reloaded = await BindingStore.load('${temp.path}/bindings.json');
      expect(reloaded.byProjectId('proj-a')!.name, '项目 A2');
    });

    test('is idempotent: second refresh reports unchanged', () async {
      final path = writeManifest('v1', manifest());
      await bind(path);
      final refresher = await newRefresher();

      writeManifest('v2', manifest(name: '新名字'));
      expect(await refresher.refresh('proj-a'), isA<RefreshApplied>());
      expect(await refresher.refresh('proj-a'), isA<RefreshUnchanged>());
    });

    test('removed services are pruned and retained read-only; re-adding restores them', () async {
      final path = writeManifest('v1', manifest());
      await bind(path);
      final refresher = await newRefresher();

      writeManifest(
        'v2',
        manifest(
          services: [
            {'id': 'svc-2', 'name': '服务二'},
          ],
        ),
      );
      await refresher.refresh('proj-a');

      expect(pruned, hasLength(1));
      expect(pruned.single.$1, 'proj-a');
      expect(pruned.single.$2, {'svc-1'});

      final retained = refresher.retainedServices('proj-a');
      expect(retained.single.id, 'svc-1');
      expect(retained.single.name, '服务一');

      // Re-adding the declaration clears the read-only leftover.
      writeManifest('v3', manifest());
      await refresher.refresh('proj-a');
      expect(refresher.retainedServices('proj-a'), isEmpty);
    });

    test(
      'pure metadata: no state-dependent side effects on unknown services',
      () async {
        // A service whose state is UNKNOWN at refresh time must not trigger
        // anything beyond store/prefs bookkeeping. ConfigRefresher holds no
        // operations/registry references, so the only observable effects are
        // the store record and the prune hook.
        final path = writeManifest('v1', manifest());
        await bind(path);
        final refresher = await newRefresher();

        writeManifest('v2', manifest(name: '改名'));
        await refresher.refresh('proj-a');

        expect(pruned, isEmpty); // nothing removed → no pruning
        expect(store.byProjectId('proj-a')!.name, '改名');
        expect(File(statePath).existsSync(), isFalse); // no invalid/retained
      },
    );
  });

  group('invalid or missing manifest', () {
    test(
      'deleted manifest keeps the binding with a typed reason, no prune',
      () async {
        final path = writeManifest('v1', manifest());
        await bind(path);
        final refresher = await newRefresher();

        File(path).deleteSync();
        final result = await refresher.refresh('proj-a');

        expect(result, isA<RefreshInvalid>());
        expect((result as RefreshInvalid).reason, ManifestRejection.unreadable);
        // Binding KEPT, last valid display intact, preferences untouched.
        expect(store.byProjectId('proj-a'), isNotNull);
        expect(store.byProjectId('proj-a')!.services, hasLength(2));
        expect(pruned, isEmpty);
        expect(
          refresher.invalidReason('proj-a')!.reason,
          ManifestRejection.unreadable,
        );

        // The flag survives a reload (UI can show it after a restart).
        final again = await newRefresher();
        expect(
          again.invalidReason('proj-a')!.reason,
          ManifestRejection.unreadable,
        );

        // Fixing the file restores start eligibility — and nothing implicit.
        writeManifest('v3', manifest());
        final fixed = await again.refresh('proj-a');
        expect(fixed, isA<RefreshUnchanged>());
        expect(again.invalidReason('proj-a'), isNull);
      },
    );

    test('invalid JSON / unknown version keep binding and services', () async {
      final path = writeManifest('v1', manifest());
      await bind(path);
      final refresher = await newRefresher();

      File(path).writeAsStringSync('{not json');
      var result = await refresher.refresh('proj-a');
      expect((result as RefreshInvalid).reason, ManifestRejection.invalidJson);

      writeManifest('v2', {'schemaVersion': 99});
      result = await refresher.refresh('proj-a') as RefreshInvalid;
      expect(result.reason, ManifestRejection.unknownVersion);

      expect(store.byProjectId('proj-a')!.services.map((s) => s.id), [
        'svc-1',
        'svc-2',
      ]);
      expect(pruned, isEmpty);
      expect(refresher.retainedServices('proj-a'), isEmpty);
    });

    test(
      'duplicate service ids are rejected without touching the binding',
      () async {
        final path = writeManifest('v1', manifest());
        await bind(path);
        final refresher = await newRefresher();

        writeManifest(
          'v2',
          manifest(
            services: [
              {'id': 'dup', 'name': 'one'},
              {'id': 'dup', 'name': 'two'},
            ],
          ),
        );
        final result = await refresher.refresh('proj-a');
        expect(
          (result as RefreshInvalid).reason,
          ManifestRejection.duplicateServiceId,
        );
        expect(store.byProjectId('proj-a')!.services, hasLength(2));
      },
    );
  });

  group('identity drift', () {
    test(
      'a different identity at the bound path is surfaced, never applied',
      () async {
        final path = writeManifest('v1', manifest());
        await bind(path);
        final refresher = await newRefresher();

        writeManifest('v2', manifest(id: 'someone-else'));
        final result = await refresher.refresh('proj-a');

        expect(result, isA<RefreshIdentityMismatch>());
        expect(
          (result as RefreshIdentityMismatch).declaredProjectId,
          'someone-else',
        );
        expect(store.byProjectId('proj-a'), isNotNull);
        expect(store.byProjectId('someone-else'), isNull);
        expect(pruned, isEmpty);
      },
    );
  });

  group('purge', () {
    test(
      'clears invalid and retained state for the project, persisted',
      () async {
        final path = writeManifest('v1', manifest());
        await bind(path);
        final other = writeManifest(
          'o1',
          manifest(id: 'proj-b', name: '项目 B'),
          projectDir: 'proj-b',
        );
        await bind(other);
        final refresher = await newRefresher();

        // Seed retained: svc-1 declaration disappears.
        writeManifest(
          'v2',
          manifest(
            services: [
              {'id': 'svc-2', 'name': '服务二'},
            ],
          ),
        );
        await refresher.refresh('proj-a');
        // Seed invalid: the manifest becomes unreadable.
        File(path).deleteSync();
        await refresher.refresh('proj-a');
        // Seed invalid for the other project too.
        File(other).deleteSync();
        await refresher.refresh('proj-b');

        expect(refresher.invalidReason('proj-a'), isNotNull);
        expect(refresher.retainedServices('proj-a'), hasLength(1));

        await refresher.purge('proj-a');

        expect(refresher.invalidReason('proj-a'), isNull);
        expect(refresher.retainedServices('proj-a'), isEmpty);
        // Other projects are untouched.
        expect(refresher.invalidReason('proj-b'), isNotNull);

        // Persisted: a fresh refresher no longer sees the purged state.
        final again = await newRefresher();
        expect(again.invalidReason('proj-a'), isNull);
        expect(again.retainedServices('proj-a'), isEmpty);
        expect(again.invalidReason('proj-b'), isNotNull);
      },
    );

    test('purging a project without state is a no-op', () async {
      final path = writeManifest('v1', manifest());
      await bind(path);
      final refresher = await newRefresher();

      await refresher.purge('proj-a');
      await refresher.purge('ghost');

      expect(File(statePath).existsSync(), isFalse);
      expect(store.byProjectId('proj-a'), isNotNull);
    });
  });

  group('removeRetained', () {
    test('drops one retained record and keeps the rest, persisted', () async {
      final path = writeManifest('v1', manifest());
      await bind(path);
      final refresher = await newRefresher();

      writeManifest('v2', manifest(services: const []));
      await refresher.refresh('proj-a');
      expect(refresher.retainedServices('proj-a'), hasLength(2));

      await refresher.removeRetained('proj-a', 'svc-1');

      final retained = refresher.retainedServices('proj-a');
      expect(retained.single.id, 'svc-2');

      // Persisted: a fresh refresher sees the same remaining record.
      final again = await newRefresher();
      expect(again.retainedServices('proj-a').single.id, 'svc-2');
    });

    test('removing an unknown retained record is a no-op', () async {
      final path = writeManifest('v1', manifest());
      await bind(path);
      final refresher = await newRefresher();

      writeManifest('v2', manifest(services: const []));
      await refresher.refresh('proj-a');

      await refresher.removeRetained('proj-a', 'ghost');
      await refresher.removeRetained('ghost', 'svc-1');

      expect(refresher.retainedServices('proj-a'), hasLength(2));
    });
  });

  group('refreshAll', () {
    test('covers every binding and reports per project', () async {
      final pathA = writeManifest('a1', manifest(), projectDir: 'proj');
      await bind(pathA);
      final pathB = writeManifest(
        'b1',
        manifest(id: 'proj-b', name: '项目 B'),
        projectDir: 'proj-b',
      );
      await bind(pathB);
      final refresher = await newRefresher();

      File(pathA).deleteSync();
      writeManifest(
        'b2',
        manifest(
          id: 'proj-b',
          name: '项目 B',
          services: [
            {'id': 'svc-9', 'name': '新服务'},
          ],
        ),
        projectDir: 'proj-b',
      );

      final results = await refresher.refreshAll();
      expect(results.keys, {'proj-a', 'proj-b'});
      expect(results['proj-a'], isA<RefreshInvalid>());
      final appliedB = results['proj-b'] as RefreshApplied;
      expect(
        appliedB.removed.map((s) => s.id),
        unorderedEquals(['svc-1', 'svc-2']),
      );
      expect(appliedB.added.map((s) => s.id), ['svc-9']);
    });

    test('unknown project reports not-bound', () async {
      final refresher = await newRefresher();
      expect(await refresher.refresh('ghost'), isA<RefreshNotBound>());
    });
  });
  group('corrupted storage', () {
    test('malformed JSON is backed up and the state starts empty', () async {
      File(statePath).writeAsStringSync('not json');

      final refresher = await newRefresher();

      expect(refresher.invalidReason('proj-a'), isNull);
      expect(refresher.retainedServices('proj-a'), isEmpty);
      final report = refresher.corruptionReport;
      expect(report, isNotNull);
      expect(report!.filePath, statePath);
      expect(report.skippedRecords, 0);
      expect(File(statePath).existsSync(), isFalse);
      expect(report.backupPath, isNotNull);
      expect(report.backupPath, contains('.corrupt-'));
      expect(File(report.backupPath!).readAsStringSync(), 'not json');
    });

    test(
      'a non-map top level is backed up and the state starts empty',
      () async {
        File(statePath).writeAsStringSync('[{"invalid": {}}]');

        final refresher = await newRefresher();

        expect(refresher.corruptionReport, isNotNull);
        expect(refresher.corruptionReport!.backupPath, isNotNull);
        expect(File(statePath).existsSync(), isFalse);
        expect(
          File(refresher.corruptionReport!.backupPath!).readAsStringSync(),
          '[{"invalid": {}}]',
        );
      },
    );

    test('invalid entries are skipped while good entries are kept', () async {
      File(statePath).writeAsStringSync(
        const JsonEncoder.withIndent('  ').convert({
          'invalid': {
            'proj-good': {
              'reason': 'invalidStructure',
              'detail': 'broken edit',
            },
            'proj-bad': 'not a record',
          },
          'retained': {
            'proj-good': [
              {'id': 'svc-1', 'name': '服务一', 'removedAt': 'bad date'},
              'not a retained record',
            ],
            'proj-bad': 'not a list',
          },
        }),
      );

      final refresher = await newRefresher();

      expect(refresher.invalidReason('proj-good'), isNotNull);
      expect(refresher.invalidReason('proj-good')!.detail, 'broken edit');
      expect(refresher.invalidReason('proj-bad'), isNull);
      final retained = refresher.retainedServices('proj-good');
      expect(retained, hasLength(1));
      expect(retained.single.id, 'svc-1');
      expect(refresher.retainedServices('proj-bad'), isEmpty);
      expect(File(statePath).existsSync(), isTrue);
      final report = refresher.corruptionReport;
      expect(report, isNotNull);
      expect(report!.filePath, statePath);
      expect(report.backupPath, isNull);
      expect(report.skippedRecords, 3);
    });
  });
}
