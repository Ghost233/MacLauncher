import 'dart:convert';
import 'dart:io';

import 'package:launcher_core/launcher_core.dart';
import 'package:test/test.dart';

void main() {
  late Directory temp;
  late String storePath;

  setUp(() {
    temp = Directory.systemTemp.createTempSync('launcher-association-test');
    storePath = '${temp.path}/bindings.json';
  });

  tearDown(() {
    if (temp.existsSync()) temp.deleteSync(recursive: true);
  });

  String writeManifest(String name, Object content) {
    final dir = Directory('${temp.path}/$name')..createSync();
    final file = File('${dir.path}/$kManifestFileName');
    file.writeAsStringSync(
      content is String
          ? content
          : const JsonEncoder.withIndent('  ').convert(content),
    );
    return file.path;
  }

  Map<String, Object?> validManifest({
    String projectId = 'proj-a',
    String projectName = '项目 A',
  }) => {
    'schemaVersion': 1,
    'project': {'id': projectId, 'name': projectName},
    'services': [
      {'id': 'svc-1', 'name': '服务一'},
      {'id': 'svc-2', 'name': '服务二'},
    ],
    'integration': {'type': 'sdk'},
  };

  Future<AssociationFlow> newFlow() async =>
      AssociationFlow(await BindingStore.load(storePath));

  group('association outcomes', () {
    test('a fresh valid manifest is created', () async {
      final manifestPath = writeManifest('a', validManifest());
      final flow = await newFlow();

      final result = await flow.associate(manifestPath);

      expect(result, isA<AssociationCreated>());
      expect((result as AssociationCreated).binding.projectId, 'proj-a');
    });

    test('re-associating the same path and identity is reused', () async {
      final manifestPath = writeManifest('a', validManifest());
      final flow = await newFlow();

      final first = await flow.associate(manifestPath);
      final second = await flow.associate(manifestPath);

      expect(second, isA<AssociationReused>());
      expect(
        (second as AssociationReused).binding.boundAt,
        (first as AssociationCreated).binding.boundAt,
      );
    });

    test(
      'same identity from another path is a conflict, never a duplicate',
      () async {
        final pathA = writeManifest('a', validManifest());
        final pathB = writeManifest('b', validManifest());
        final store = await BindingStore.load(storePath);
        final flow = AssociationFlow(store);

        await flow.associate(pathA);
        final result = await flow.associate(pathB);

        expect(result, isA<AssociationConflict>());
        final conflict = result as AssociationConflict;
        expect(conflict.kind, AssociationConflictKind.identityBoundToOtherPath);
        expect(
          conflict.existingBinding.manifestPath,
          BindingStore.canonicalPath(pathA),
        );
        expect(conflict.incomingManifest.projectId, 'proj-a');
        // The collision changed nothing.
        expect(store.bindings, hasLength(1));
        expect(store.byManifestPath(pathB), isNull);
      },
    );

    test(
      'same path with a different identity is a conflict, never a swap',
      () async {
        final pathA = writeManifest('a', validManifest());
        final store = await BindingStore.load(storePath);
        final flow = AssociationFlow(store);
        await flow.associate(pathA);

        // The directory now hosts a different project identity.
        File(pathA).writeAsStringSync(
          const JsonEncoder.withIndent('  ')
              .convert(validManifest(projectId: 'proj-b', projectName: '项目 B')),
        );
        final result = await flow.associate(pathA);

        expect(result, isA<AssociationConflict>());
        final conflict = result as AssociationConflict;
        expect(conflict.kind, AssociationConflictKind.pathBoundToOtherIdentity);
        expect(conflict.existingBinding.projectId, 'proj-a');
        expect(conflict.incomingManifest.projectId, 'proj-b');
        // The original binding is untouched.
        expect(store.byProjectId('proj-a'), isNotNull);
        expect(store.byProjectId('proj-b'), isNull);
      },
    );

    test('invalid manifests still throw and never mutate the store', () async {
      final bad = writeManifest('bad', {'schemaVersion': 99});
      final store = await BindingStore.load(storePath);
      final flow = AssociationFlow(store);

      await expectLater(
        flow.associate(bad),
        throwsA(
          isA<ManifestException>().having(
            (e) => e.reason,
            'reason',
            ManifestRejection.unknownVersion,
          ),
        ),
      );
      expect(store.bindings, isEmpty);
      expect(File(storePath).existsSync(), isFalse);
    });
  });

  group('migration resolution', () {
    test('migrating re-points the binding and preserves boundAt', () async {
      final pathA = writeManifest('a', validManifest());
      final pathB = writeManifest('b', validManifest(projectName: '项目 A（新）'));
      final store = await BindingStore.load(storePath);
      final flow = AssociationFlow(store);
      final created = await flow.associate(pathA);
      final boundAt = (created as AssociationCreated).binding.boundAt;

      final migrated = await flow.migrateBinding('proj-a', pathB);

      expect(migrated.projectId, 'proj-a');
      expect(migrated.manifestPath, BindingStore.canonicalPath(pathB));
      expect(migrated.name, '项目 A（新）');
      expect(migrated.boundAt, boundAt);
      expect(store.bindings, hasLength(1));

      // The old path no longer resolves to the binding; the new path does.
      expect(store.byManifestPath(pathA), isNull);
      expect(store.byManifestPath(pathB)!.projectId, 'proj-a');

      // Persisted across reload.
      final reloaded = await BindingStore.load(storePath);
      expect(
        reloaded.byProjectId('proj-a')!.manifestPath,
        BindingStore.canonicalPath(pathB),
      );

      // And re-associating the new path reuses the migrated record.
      final again = await AssociationFlow(reloaded).associate(pathB);
      expect(again, isA<AssociationReused>());
      expect((again as AssociationReused).binding.boundAt, boundAt);
    });

    test('migration picks up changed service declarations', () async {
      final pathA = writeManifest('a', validManifest());
      final store = await BindingStore.load(storePath);
      final flow = AssociationFlow(store);
      await flow.associate(pathA);

      final moved = validManifest()
        ..['services'] = [
          {'id': 'svc-9', 'name': '新服务'},
        ];
      final pathB = writeManifest('b', moved);
      final migrated = await flow.migrateBinding('proj-a', pathB);

      expect(migrated.services.map((s) => s.id), ['svc-9']);
    });

    test(
      'migration rejects a different identity without mutating the store',
      () async {
        final pathA = writeManifest('a', validManifest());
        final pathB = writeManifest(
          'b',
          validManifest(projectId: 'proj-other'),
        );
        final store = await BindingStore.load(storePath);
        final flow = AssociationFlow(store);
        await flow.associate(pathA);

        await expectLater(
          flow.migrateBinding('proj-a', pathB),
          throwsA(isA<ManifestException>()),
        );
        expect(
          store.byProjectId('proj-a')!.manifestPath,
          BindingStore.canonicalPath(pathA),
        );
        expect(store.byManifestPath(pathB), isNull);
      },
    );

    test(
      'migration onto a path bound to another project is rejected',
      () async {
        final pathA = writeManifest('a', validManifest());
        final pathB = writeManifest('b', validManifest(projectId: 'proj-b'));
        final store = await BindingStore.load(storePath);
        final flow = AssociationFlow(store);
        await flow.associate(pathA);
        await flow.associate(pathB);

        // Rewrite A's identity into B's file so identity matches but the path
        // is occupied by another binding.
        final source = File(pathB).readAsStringSync();
        File(pathB)
            .writeAsStringSync(source.replaceAll('"proj-b"', '"proj-a"'));

        await expectLater(
          flow.migrateBinding('proj-a', pathB),
          throwsA(isA<ManifestException>()),
        );
        expect(store.byManifestPath(pathB)!.projectId, 'proj-b');
      },
    );

    test(
      'migration with an unreadable manifest fails without changes',
      () async {
        final pathA = writeManifest('a', validManifest());
        final store = await BindingStore.load(storePath);
        final flow = AssociationFlow(store);
        await flow.associate(pathA);

        await expectLater(
          flow.migrateBinding(
            'proj-a',
            '${temp.path}/missing/$kManifestFileName',
          ),
          throwsA(
            isA<ManifestException>().having(
              (e) => e.reason,
              'reason',
              ManifestRejection.unreadable,
            ),
          ),
        );
        expect(
          store.byProjectId('proj-a')!.manifestPath,
          BindingStore.canonicalPath(pathA),
        );
      },
    );

    test('migration for an unknown identity throws', () async {
      final flow = await newFlow();
      final pathB = writeManifest('b', validManifest());
      await expectLater(flow.migrateBinding('ghost', pathB), throwsStateError);
    });
  });

  group('new-project resolution', () {
    test(
      'a copied manifest becomes an independent binding with a fresh identity',
      () async {
        final pathA = writeManifest('a', validManifest());
        final pathB = writeManifest('b', validManifest());
        final store = await BindingStore.load(storePath);
        final flow = AssociationFlow(store);
        await flow.associate(pathA);
        expect(await flow.associate(pathB), isA<AssociationConflict>());

        final created = await flow.associateAsNewProject(pathB);

        // Two independent bindings with different identities.
        expect(store.bindings, hasLength(2));
        expect(created.projectId, isNot('proj-a'));
        expect(store.byProjectId(created.projectId), isNotNull);
        expect(store.byProjectId('proj-a'), isNotNull);

        // The incoming manifest was rewritten exactly once: only project.id.
        final rewritten = ProjectManifest.parse(File(pathB).readAsStringSync());
        expect(rewritten.projectId, created.projectId);
        expect(rewritten.projectName, '项目 A');
        expect(rewritten.services.map((s) => s.id), ['svc-1', 'svc-2']);

        // The original file kept its identity.
        expect(
          ProjectManifest.parse(File(pathA).readAsStringSync()).projectId,
          'proj-a',
        );

        // Re-associating the rewritten file reuses the new record.
        final again = await flow.associate(pathB);
        expect(again, isA<AssociationReused>());
        expect(
          (again as AssociationReused).binding.projectId,
          created.projectId,
        );
      },
    );

    test('the rewrite preserves other fields and formatting', () async {
      // Unusual spacing, extra unknown field, project not first.
      const source = '''
{
  "schemaVersion": 1,
  "services": [ {"id": "svc-1", "name": "服务一"} ],
  "project":   { "id":   "proj-a",   "name": "保持格式", "extra": true },
  "x-custom": {"note": "do not lose me"}
}
''';
      final path = writeManifest('weird', source);
      final store = await BindingStore.load(storePath);
      final flow = AssociationFlow(store);

      final created = await flow.associateAsNewProject(path);

      final after = File(path).readAsStringSync();
      // Surgical edit: untouched text around the id value survives verbatim.
      expect(after, contains('"name": "保持格式", "extra": true'));
      expect(after, contains('"x-custom": {"note": "do not lose me"}'));
      expect(after, isNot(contains('proj-a')));
      expect(ProjectManifest.parse(after).projectId, created.projectId);
    });

    test('new-project on an already-bound path is refused', () async {
      final pathA = writeManifest('a', validManifest());
      final store = await BindingStore.load(storePath);
      final flow = AssociationFlow(store);
      await flow.associate(pathA);

      await expectLater(flow.associateAsNewProject(pathA), throwsStateError);
      // File and binding untouched.
      expect(
        ProjectManifest.parse(File(pathA).readAsStringSync()).projectId,
        'proj-a',
      );
    });

    test('generated identities are unique across existing bindings', () async {
      final pathA = writeManifest('a', validManifest());
      final pathB = writeManifest('b', validManifest());
      final pathC = writeManifest('c', validManifest());
      final store = await BindingStore.load(storePath);
      final flow = AssociationFlow(store);
      await flow.associate(pathA);
      final second = await flow.associateAsNewProject(pathB);
      final third = await flow.associateAsNewProject(pathC);

      final ids = store.bindings.map((b) => b.projectId).toSet();
      expect(ids, hasLength(3));
      expect(ids, containsAll(['proj-a', second.projectId, third.projectId]));
    });
  });

  group('generateProjectId', () {
    test('produces UUIDv4-shaped unique identities', () {
      final pattern = RegExp(
        '^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}\$',
      );
      final seen = <String>{};
      for (var i = 0; i < 200; i++) {
        final id = generateProjectId();
        expect(id, matches(pattern));
        expect(seen.add(id), isTrue);
      }
    });
  });
}
