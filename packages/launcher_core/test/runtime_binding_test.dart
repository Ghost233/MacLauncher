import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:launcher_core/launcher_core.dart';
import 'package:maclauncher_sdk/maclauncher_sdk.dart';
import 'package:test/test.dart';

import 'support.dart';

void main() {
  late Directory temp;

  setUp(() {
    temp = Directory.systemTemp.createTempSync('runtime-binding-test');
  });

  tearDown(() {
    if (temp.existsSync()) temp.deleteSync(recursive: true);
  });

  ProjectBinding runtimeBinding({
    String projectId = 'rt-1',
    List<ManifestService> services = const [
      ManifestService(id: 'svc', name: '服务'),
    ],
    SdkEntry? entry,
  }) => ProjectBinding(
    projectId: projectId,
    name: '运行时应用',
    services: services,
    boundAt: DateTime.now().toUtc(),
    origin: BindingOrigin.runtime,
    learnedEntry: entry,
  );

  group('runtime binding records', () {
    test('runtime binding round-trips through JSON', () {
      final binding = runtimeBinding(
        entry: SdkEntry.executable(
          '/opt/tool/bin/tool',
          args: ['--serve'],
          workingDirectory: '/opt/tool',
        ),
      );
      final json = binding.toJson();
      expect(json.containsKey('manifestPath'), isFalse);
      expect(json['origin'], 'runtime');

      final restored = ProjectBinding.fromJson(json);
      expect(restored.origin, BindingOrigin.runtime);
      expect(restored.manifestPath, isNull);
      expect(restored.learnedEntry!.kind, SdkEntryKind.executable);
      expect(restored.learnedEntry!.path, '/opt/tool/bin/tool');
      expect(restored.learnedEntry!.args, ['--serve']);
      expect(restored.learnedEntry!.workingDirectory, '/opt/tool');
      expect(restored.services.single.id, 'svc');
    });

    test('old records without origin load as config bindings', () async {
      final storePath = '${temp.path}/bindings.json';
      File(storePath)
        ..createSync(recursive: true)
        ..writeAsStringSync(
          jsonEncode([
            {
              'projectId': 'old-1',
              'name': '旧绑定',
              'manifestPath': '/tmp/proj/maclauncher.json',
              'services': const [],
              'boundAt': DateTime.now().toUtc().toIso8601String(),
            },
          ]),
        );
      final store = await BindingStore.load(storePath);
      final binding = store.byProjectId('old-1')!;
      expect(binding.origin, BindingOrigin.config);
      expect(binding.manifestPath, '/tmp/proj/maclauncher.json');
      expect(store.corruptionReport, isNull);
    });

    test('config record without a manifest path is damage; runtime record without one loads', () async {
      final storePath = '${temp.path}/bindings.json';
      File(storePath)
        ..createSync(recursive: true)
        ..writeAsStringSync(
          jsonEncode([
            {'projectId': 'broken-config', 'name': '缺路径', 'services': []},
            {
              'projectId': 'rt-1',
              'name': '运行时应用',
              'origin': 'runtime',
              'services': [
                {'id': 'svc', 'name': '服务'},
              ],
            },
          ]),
        );
      final store = await BindingStore.load(storePath);
      expect(store.byProjectId('broken-config'), isNull);
      expect(store.byProjectId('rt-1')!.origin, BindingOrigin.runtime);
      expect(store.corruptionReport, isNotNull);
    });

    test(
      'runtime bindings collide on identity, never on manifest path',
      () async {
        final store = await BindingStore.load('${temp.path}/bindings.json');
        await store.insert(runtimeBinding());
        await store.insert(runtimeBinding(projectId: 'rt-2'));
        expect(store.bindings, hasLength(2));
        expect(store.byManifestPath('/anywhere'), isNull);

        expect(
          () => store.insert(runtimeBinding()),
          throwsA(isA<StateError>()),
          reason: 'duplicate identity is still rejected',
        );
      },
    );
  });

  group('DiscoveryApproval', () {
    Future<(BindingStore, PendingRegistry, DiscoveryApproval)> setup({
      bool Function(String path)? pathExists,
    }) async {
      final store = await BindingStore.load('${temp.path}/bindings.json');
      final pending = PendingRegistry();
      addTearDown(pending.close);
      return (
        store,
        pending,
        DiscoveryApproval(
          bindings: store,
          pending: pending,
          pathExists: pathExists,
        ),
      );
    }

    test('approval builds a runtime binding from the pending facts', () async {
      // A real on-disk bundle: app entries require Contents/Info.plist.
      Directory('${temp.path}/Foo.app/Contents').createSync(recursive: true);
      File('${temp.path}/Foo.app/Contents/Info.plist').writeAsStringSync('');
      final (store, pending, approval) = await setup();
      pending.record(
        projectId: 'rt-1',
        projectName: '幽灵面板',
        services: [
          ServiceDeclaration(id: 'inference', name: '推理', methods: ['start']),
        ],
        entry: SdkEntry.appBundle('${temp.path}/Foo.app'),
      );

      final binding = await approval.approve('rt-1');

      expect(binding.origin, BindingOrigin.runtime);
      expect(binding.manifestPath, isNull);
      expect(binding.name, '幽灵面板');
      expect(binding.services.single.id, 'inference');
      expect(binding.learnedEntry!.path, '${temp.path}/Foo.app');
      expect(pending.has('rt-1'), isFalse);
      // Persisted: a fresh load sees the runtime binding.
      final reloaded = await BindingStore.load('${temp.path}/bindings.json');
      expect(reloaded.byProjectId('rt-1')!.origin, BindingOrigin.runtime);
    });

    test(
      'approval without an entry is allowed (observe/recycle only)',
      () async {
        final (store, pending, approval) = await setup();
        pending.record(projectId: 'rt-1', projectName: '纯观察');

        final binding = await approval.approve('rt-1');
        expect(binding.learnedEntry, isNull);
        expect(store.byProjectId('rt-1'), isNotNull);
      },
    );

    test(
      'an entry that vanished on disk blocks approval, pending kept',
      () async {
        final (_, pending, approval) = await setup(pathExists: (_) => false);
        pending.record(
          projectId: 'rt-1',
          entry: SdkEntry.executable('/gone/tool'),
        );

        expect(
          () => approval.approve('rt-1'),
          throwsA(isA<DiscoveryApprovalException>()),
        );
        expect(pending.has('rt-1'), isTrue);
      },
    );

    test(
      'an app bundle without Info.plist is rejected (on-disk check)',
      () async {
        Directory('${temp.path}/Fake.app').createSync();
        final (_, pending, approval) = await setup();
        pending.record(
          projectId: 'rt-1',
          entry: SdkEntry.appBundle('${temp.path}/Fake.app'),
        );

        expect(
          () => approval.approve('rt-1'),
          throwsA(
            isA<DiscoveryApprovalException>().having(
              (e) => e.detail,
              'detail',
              contains('Info.plist'),
            ),
          ),
        );
      },
    );

    test(
      'approving an already-bound identity keeps the pending record',
      () async {
        final (store, pending, approval) = await setup();
        await store.insert(runtimeBinding());
        pending.record(projectId: 'rt-1', projectName: '重复身份');

        expect(() => approval.approve('rt-1'), throwsA(isA<StateError>()));
        expect(pending.has('rt-1'), isTrue);
      },
    );

    test('approving a project that is not pending throws', () async {
      final (_, _, approval) = await setup();
      expect(() => approval.approve('ghost'), throwsA(isA<StateError>()));
    });
  });

  group('ConfigRefresher runtime hello diff', () {
    Future<(BindingStore, ConfigRefresher, List<Set<String>>)> setup() async {
      final store = await BindingStore.load('${temp.path}/bindings.json');
      await store.insert(
        runtimeBinding(
          services: const [
            ManifestService(id: 'a', name: '甲'),
            ManifestService(id: 'b', name: '乙'),
          ],
        ),
      );
      final pruned = <Set<String>>[];
      final refresher = await ConfigRefresher.load(
        store,
        '${temp.path}/refresh-state.json',
        prunePreferences: (projectId, removed) async => pruned.add(removed),
      );
      return (store, refresher, pruned);
    }

    test('file refresh skips runtime bindings entirely', () async {
      final (_, refresher, _) = await setup();
      expect(await refresher.refresh('rt-1'), isA<RefreshUnchanged>());
      expect(refresher.invalidReason('rt-1'), isNull);
    });

    test(
      'hello diff adds, retains removals, prunes prefs, updates the name',
      () async {
        final (store, refresher, pruned) = await setup();

        final result = await refresher.applyRuntimeHello('rt-1', const [
          ManifestService(id: 'b', name: '乙'),
          ManifestService(id: 'c', name: '丙'),
        ], projectName: '新名字');

        expect(result, isA<RefreshApplied>());
        final applied = result as RefreshApplied;
        expect(applied.added.map((s) => s.id), ['c']);
        expect(applied.removed.map((s) => s.id), ['a']);
        expect(applied.nameChanged, isTrue);

        final binding = store.byProjectId('rt-1')!;
        expect(binding.services.map((s) => s.id), ['b', 'c']);
        expect(binding.name, '新名字');
        expect(binding.origin, BindingOrigin.runtime);
        expect(pruned, [
          {'a'},
        ]);
        expect(refresher.retainedServices('rt-1').map((r) => r.id), ['a']);

        // The service comes back in a later hello: live again, not retained.
        final back = await refresher.applyRuntimeHello('rt-1', const [
          ManifestService(id: 'a', name: '甲'),
          ManifestService(id: 'b', name: '乙'),
          ManifestService(id: 'c', name: '丙'),
        ]);
        expect(back, isA<RefreshApplied>());
        expect(refresher.retainedServices('rt-1'), isEmpty);
      },
    );

    test('identical hello is a no-op', () async {
      final (store, refresher, pruned) = await setup();
      final result = await refresher.applyRuntimeHello('rt-1', const [
        ManifestService(id: 'a', name: '甲'),
        ManifestService(id: 'b', name: '乙'),
      ]);
      expect(result, isA<RefreshUnchanged>());
      expect(pruned, isEmpty);
      expect(store.byProjectId('rt-1')!.services, hasLength(2));
    });

    test('config bindings ignore hello-driven diffs', () async {
      final projectDir = Directory('${temp.path}/proj')..createSync();
      File('${projectDir.path}/$kManifestFileName').writeAsStringSync(
        jsonEncode({
          'schemaVersion': 1,
          'project': {'id': 'cfg-1', 'name': '配置项目'},
          'services': [
            {'id': 'svc', 'name': '服务'},
          ],
        }),
      );
      final store = await BindingStore.load('${temp.path}/bindings.json');
      await store.associate('${projectDir.path}/$kManifestFileName');
      final refresher = await ConfigRefresher.load(
        store,
        '${temp.path}/refresh-state.json',
      );

      final result = await refresher.applyRuntimeHello('cfg-1', const [
        ManifestService(id: 'other', name: '别服务'),
      ]);
      expect(result, isA<RefreshUnchanged>());
      expect(store.byProjectId('cfg-1')!.services.single.id, 'svc');
    });
  });

  group('RuntimeBindingSync handshake wiring', () {
    test(
      'accepted hello refreshes services and self-heals the learned entry',
      () async {
        final store = await BindingStore.load('${temp.path}/bindings.json');
        await store.insert(
          runtimeBinding(
            entry: SdkEntry.executable('/old/path/tool'),
            services: const [ManifestService(id: 'old', name: '旧服务')],
          ),
        );
        final refresher = await ConfigRefresher.load(
          store,
          '${temp.path}/refresh-state.json',
        );
        final server = await LauncherServer.start(
          layout: EndpointLayout(directory: '${temp.path}/MacLauncher'),
          bindings: store,
          runtimeSync: RuntimeBindingSync(
            bindings: store,
            refresher: refresher,
          ),
        );
        addTearDown(server.close);

        final socket = await connectRaw(server.layout.socketPath);
        addTearDown(socket.destroy);
        final welcome = await rawHello(socket, {
          ...helloMessage(projectId: 'rt-1'),
          'projectName': '运行时应用·改',
          'entry': {
            'kind': 'executable',
            'path': '/new/path/tool',
            'args': ['--port', '9'],
          },
          'capabilities': {
            'services': [
              {
                'id': 'new',
                'name': '新服务',
                'methods': ['status'],
              },
            ],
            'app': const [],
          },
        });
        expect(welcome['accepted'], isTrue);
        // The sync's persisted writes ride real file IO past the first event
        // turn; poll until the entry self-heal lands.
        await untilTrue(
          () =>
              store.byProjectId('rt-1')!.learnedEntry?.path == '/new/path/tool',
        );

        final binding = store.byProjectId('rt-1')!;
        expect(binding.services.map((s) => s.id), ['new']);
        expect(binding.name, '运行时应用·改');
        expect(binding.learnedEntry!.path, '/new/path/tool');
        expect(binding.learnedEntry!.args, ['--port', '9']);
        expect(refresher.retainedServices('rt-1').map((r) => r.id), ['old']);
      },
    );

    test('config bindings are untouched by the handshake sync', () async {
      final projectDir = Directory('${temp.path}/proj')..createSync();
      File('${projectDir.path}/$kManifestFileName').writeAsStringSync(
        jsonEncode({
          'schemaVersion': 1,
          'project': {'id': 'cfg-1', 'name': '配置项目'},
          'services': [
            {'id': 'svc', 'name': '服务'},
          ],
        }),
      );
      final store = await BindingStore.load('${temp.path}/bindings.json');
      await store.associate('${projectDir.path}/$kManifestFileName');
      final refresher = await ConfigRefresher.load(
        store,
        '${temp.path}/refresh-state.json',
      );
      final server = await LauncherServer.start(
        layout: EndpointLayout(directory: '${temp.path}/MacLauncher'),
        bindings: store,
        runtimeSync: RuntimeBindingSync(bindings: store, refresher: refresher),
      );
      addTearDown(server.close);

      final socket = await connectRaw(server.layout.socketPath);
      addTearDown(socket.destroy);
      final welcome = await rawHello(socket, {
        ...helloMessage(projectId: 'cfg-1'),
        'projectName': '改名也没用',
        'entry': {'kind': 'executable', 'path': '/elsewhere/tool'},
        'capabilities': {
          'services': [
            {
              'id': 'bogus',
              'name': '不应生效',
              'methods': ['status'],
            },
          ],
          'app': const [],
        },
      });
      expect(welcome['accepted'], isTrue);
      // Config bindings are never touched, so there is nothing to wait for;
      // give the (skipped) sync a turn to prove no writes happen.
      await pumpEventQueue();
      await untilTrue(() => store.byProjectId('cfg-1') != null);

      final binding = store.byProjectId('cfg-1')!;
      expect(binding.services.single.id, 'svc');
      expect(binding.name, '配置项目');
      expect(binding.learnedEntry, isNull);
    });
  });

  group('AutostartNotifier with runtime bindings', () {
    test('runtime binding services notify without any manifest file', () async {
      final store = await BindingStore.load('${temp.path}/bindings.json');
      // The binding record is the declaration source for runtime apps:
      // 'gone' has a login preference but is not declared, so it is not a
      // target.
      await store.insert(
        runtimeBinding(
          services: const [ManifestService(id: 'svc', name: '服务')],
        ),
      );
      final prefs = await PreferenceStore.load('${temp.path}/prefs.json');
      await prefs.setLoginStartEnabled('rt-1', 'svc', true);
      await prefs.setLoginStartEnabled('rt-1', 'gone', true);

      final started = <String>[];
      final notifier = AutostartNotifier(preferences: prefs);
      final report = await notifier.runOnce(
        bindings: store,
        startService: (_, serviceId) async {
          started.add(serviceId);
          return const OperationAcknowledged();
        },
      );

      expect(started, ['svc']);
      expect(report.notified.map((n) => n.serviceId), ['svc']);
      // Undeclared services surface as skips, same as config bindings.
      expect(report.skipped.single.serviceId, 'gone');
      expect(report.skipped.single.reason, 'service no longer declared');
    });
  });
}

/// Polls [condition] until it holds, with a deadline.
Future<void> untilTrue(
  bool Function() condition, {
  Duration timeout = const Duration(seconds: 10),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) {
      throw TimeoutException('condition never held');
    }
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
}
