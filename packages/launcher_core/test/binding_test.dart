import 'dart:convert';
import 'dart:io';

import 'package:launcher_core/launcher_core.dart';
import 'package:maclauncher_sdk/maclauncher_sdk.dart';
import 'package:test/test.dart';

import 'support.dart';

void main() {
  late Directory temp;
  late String storePath;

  setUp(() {
    temp = Directory.systemTemp.createTempSync('launcher-binding-test');
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

  group('association', () {
    test('a valid manifest becomes a persisted binding', () async {
      final manifestPath = writeManifest('a', validManifest());
      final store = await BindingStore.load(storePath);

      final binding = await store.associate(manifestPath);

      expect(binding.projectId, 'proj-a');
      expect(binding.name, '项目 A');
      expect(binding.services.map((s) => s.id), ['svc-1', 'svc-2']);

      // Persisted locally and survives reload.
      final reloaded = await BindingStore.load(storePath);
      expect(reloaded.bindings, hasLength(1));
      expect(reloaded.byProjectId('proj-a'), isNotNull);
      final mode = FileStat.statSync(storePath).mode & 0xFFF;
      expect(mode, int.parse('600', radix: 8));
    });

    test('re-associating the same configuration reuses the record', () async {
      final manifestPath = writeManifest('a', validManifest());
      final store = await BindingStore.load(storePath);

      final first = await store.associate(manifestPath);
      final second = await store.associate(manifestPath);

      expect(store.bindings, hasLength(1));
      expect(second.boundAt, first.boundAt);
    });

    test('the manifest file itself is never modified', () async {
      final manifestPath = writeManifest('a', validManifest());
      final before = File(manifestPath).readAsStringSync();
      final store = await BindingStore.load(storePath);
      await store.associate(manifestPath);
      expect(File(manifestPath).readAsStringSync(), before);
    });
  });

  group('validation rejects with concrete reasons', () {
    Future<ManifestRejection> rejectionOf(Object content) async {
      final manifestPath = writeManifest(
        'bad-${DateTime.now().microsecondsSinceEpoch}',
        content,
      );
      final store = await BindingStore.load(storePath);
      try {
        await store.associate(manifestPath);
      } on ManifestException catch (e) {
        return e.reason;
      }
      fail('expected ManifestException');
    }

    test('unreadable file', () async {
      final store = await BindingStore.load(storePath);
      expect(
        () => store.associate('${temp.path}/missing/$kManifestFileName'),
        throwsA(
          isA<ManifestException>().having(
            (e) => e.reason,
            'reason',
            ManifestRejection.unreadable,
          ),
        ),
      );
    });

    test('invalid JSON', () async {
      expect(await rejectionOf('{not json'), ManifestRejection.invalidJson);
    });

    test('unknown schemaVersion', () async {
      expect(
        await rejectionOf({'schemaVersion': 99}),
        ManifestRejection.unknownVersion,
      );
    });

    test('empty project id', () async {
      expect(
        await rejectionOf({
          'schemaVersion': 1,
          'project': {'id': '', 'name': 'x'},
          'services': const [],
        }),
        ManifestRejection.emptyProjectId,
      );
    });

    test("project id starting with '@' is reserved", () async {
      expect(
        await rejectionOf({
          'schemaVersion': 1,
          'project': {'id': '@updates', 'name': 'x'},
          'services': const [],
        }),
        ManifestRejection.reservedProjectId,
      );
    });

    test('empty service id', () async {
      expect(
        await rejectionOf({
          'schemaVersion': 1,
          'project': {'id': 'p', 'name': 'x'},
          'services': [
            {'id': '', 'name': 's'},
          ],
        }),
        ManifestRejection.emptyServiceId,
      );
    });

    test('duplicate service id', () async {
      expect(
        await rejectionOf({
          'schemaVersion': 1,
          'project': {'id': 'p', 'name': 'x'},
          'services': [
            {'id': 'dup', 'name': 'one'},
            {'id': 'dup', 'name': 'two'},
          ],
        }),
        ManifestRejection.duplicateServiceId,
      );
    });

    test('rejections never create a binding', () async {
      final store = await BindingStore.load(storePath);
      final bad = writeManifest('bad', {'schemaVersion': 99});
      await expectLater(
        store.associate(bad),
        throwsA(isA<ManifestException>()),
      );
      expect(store.bindings, isEmpty);
      expect(File(storePath).existsSync(), isFalse);
    });
  });

  group('handshake integration', () {
    test('only bound projects pass the handshake', () async {
      final manifestPath = writeManifest('a', validManifest());
      final store = await BindingStore.load(storePath);
      await store.associate(manifestPath);

      final layout = EndpointLayout(directory: '${temp.path}/endpoint');
      final server = await LauncherServer.start(
        layout: layout,
        bindings: store,
      );
      addTearDown(server.close);

      final sdk = MacLauncherSdk.connect(
        projectId: 'proj-a',
        socketPath: layout.socketPath,
        services: {
          'svc-1': ServiceCallbacks(
            name: '服务一',
            onStatus: () async {
              return ServiceStatus(state: ServiceState.running);
            },
          ),
        },
      );
      addTearDown(sdk.dispose);

      await until(() => server.registry.isActive('proj-a'));
      expect(server.registry.byProject('proj-a'), isNotNull);
    });
  });

  group('corrupted storage', () {
    test('malformed JSON is backed up and the store starts empty', () async {
      File(storePath).writeAsStringSync('{not json at all');

      final store = await BindingStore.load(storePath);

      expect(store.bindings, isEmpty);
      final report = store.corruptionReport;
      expect(report, isNotNull);
      expect(report!.filePath, storePath);
      expect(report.skippedRecords, 0);
      // The original moved aside: app never trips over it again.
      expect(File(storePath).existsSync(), isFalse);
      final backupPath = report.backupPath;
      expect(backupPath, isNotNull);
      expect(backupPath, contains('.corrupt-'));
      expect(File(backupPath!).readAsStringSync(), '{not json at all');
    });

    test('a non-list top level is backed up and the store starts empty', () async {
      File(storePath).writeAsStringSync('{"projectId": "proj-a"}');

      final store = await BindingStore.load(storePath);

      expect(store.bindings, isEmpty);
      final report = store.corruptionReport;
      expect(report, isNotNull);
      expect(report!.backupPath, isNotNull);
      expect(File(storePath).existsSync(), isFalse);
      expect(
        File(report.backupPath!).readAsStringSync(),
        '{"projectId": "proj-a"}',
      );
    });

    test('invalid records are skipped while good records are kept', () async {
      final good = ProjectBinding(
        projectId: 'proj-good',
        name: '好项目',
        manifestPath: '${temp.path}/good/maclauncher.json',
        services: const [],
        boundAt: DateTime.utc(2026, 1, 1),
      );
      File(storePath).writeAsStringSync(
        const JsonEncoder.withIndent('  ').convert([
          good.toJson(),
          'not a record at all',
          {'name': '缺身份字段'}, // no projectId / manifestPath
          {
            'projectId': 'proj-bad-services',
            'manifestPath': '${temp.path}/bad/maclauncher.json',
            'services': 'not-a-list',
          },
        ]),
      );

      final store = await BindingStore.load(storePath);

      expect(store.bindings, hasLength(1));
      expect(store.byProjectId('proj-good'), isNotNull);
      expect(store.byProjectId('proj-good')!.name, '好项目');
      // The file itself is readable, so it stays in place; only the skip
      // is reported.
      expect(File(storePath).existsSync(), isTrue);
      final report = store.corruptionReport;
      expect(report, isNotNull);
      expect(report!.filePath, storePath);
      expect(report.backupPath, isNull);
      expect(report.skippedRecords, 3);
    });
  });
}
