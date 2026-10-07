import 'dart:io';

import 'package:launcher_core/launcher_core.dart';
import 'package:maclauncher_sdk/maclauncher_sdk.dart';
import 'package:test/test.dart';

import 'support.dart';

void main() {
  late Directory temp;
  late EndpointLayout layout;

  setUp(() {
    temp = Directory.systemTemp.createTempSync('launcher-discovery-test');
    layout = EndpointLayout(directory: '${temp.path}/MacLauncher');
  });

  tearDown(() {
    if (temp.existsSync()) temp.deleteSync(recursive: true);
  });

  Map<String, Object?> discoveryHello({
    String projectId = 'stranger',
    String? projectName,
    Map<String, Object?>? entry,
    List<Map<String, Object?>> services = const [],
  }) => {
    ...helloMessage(projectId: projectId),
    'projectName': ?projectName,
    'entry': ?entry,
    'capabilities': {'services': services, 'app': const []},
  };

  group('handshake pending branch', () {
    test(
      'unknown project is recorded pending and rejected pending-approval',
      () async {
        final pending = PendingRegistry();
        addTearDown(pending.close);
        var probeCalls = 0;
        final server = await LauncherServer.start(
          layout: layout,
          bindings: InMemoryBindingLookup({'proj-1'}),
          discovery: DiscoveryConfig(
            pending: pending,
            isIgnored: (_) => false,
            peerProbe: () async {
              probeCalls++;
              return '/Applications/Foo.app/Contents/MacOS/Foo';
            },
          ),
        );
        addTearDown(server.close);

        final socket = await connectRaw(layout.socketPath);
        addTearDown(socket.destroy);
        final welcome = await rawHello(
          socket,
          discoveryHello(
            projectName: '示例应用',
            entry: {'kind': 'app', 'path': '/Applications/Foo.app'},
            services: [
              {
                'id': 'inference',
                'name': '推理服务',
                'methods': ['start', 'status'],
              },
            ],
          ),
        );
        expect(welcome['accepted'], isFalse);
        expect(welcome['reason'], RejectReason.pendingApproval);
        expect(server.registry.connected, isEmpty);

        final project = pending.byProject('stranger')!;
        expect(project.displayName, '示例应用');
        expect(project.services.single.id, 'inference');
        expect(project.entry!.kind, SdkEntryKind.app);
        expect(project.entry!.path, '/Applications/Foo.app');
        expect(
          project.sourceProcessPath,
          '/Applications/Foo.app/Contents/MacOS/Foo',
        );
        expect(probeCalls, 1);
      },
    );

    test(
      'retry preserves firstSeenAt, advances lastSeenAt, skips probe',
      () async {
        final pending = PendingRegistry();
        addTearDown(pending.close);
        var probeCalls = 0;
        final server = await LauncherServer.start(
          layout: layout,
          bindings: InMemoryBindingLookup(const {}),
          discovery: DiscoveryConfig(
            pending: pending,
            isIgnored: (_) => false,
            peerProbe: () async {
              probeCalls++;
              return '/tmp/tool';
            },
          ),
        );
        addTearDown(server.close);

        for (var i = 0; i < 2; i++) {
          final socket = await connectRaw(layout.socketPath);
          addTearDown(socket.destroy);
          final welcome = await rawHello(socket, discoveryHello());
          expect(welcome['reason'], RejectReason.pendingApproval);
        }
        final project = pending.byProject('stranger')!;
        expect(
          project.lastSeenAt.isBefore(project.firstSeenAt),
          isFalse,
          reason: 'lastSeenAt must never precede firstSeenAt',
        );
        expect(probeCalls, 1, reason: 'known source path is not re-probed');
        expect(pending.projects, hasLength(1));
      },
    );

    test(
      'ignored project is rejected unknown-project without recording',
      () async {
        final pending = PendingRegistry();
        addTearDown(pending.close);
        var probeCalls = 0;
        final server = await LauncherServer.start(
          layout: layout,
          bindings: InMemoryBindingLookup(const {}),
          discovery: DiscoveryConfig(
            pending: pending,
            isIgnored: (id) => id == 'stranger',
            peerProbe: () async {
              probeCalls++;
              return null;
            },
          ),
        );
        addTearDown(server.close);

        final socket = await connectRaw(layout.socketPath);
        addTearDown(socket.destroy);
        final welcome = await rawHello(socket, discoveryHello());
        expect(welcome['reason'], RejectReason.unknownProject);
        expect(pending.projects, isEmpty);
        expect(probeCalls, 0);
      },
    );

    test('missing discovery config keeps pre-discovery behavior', () async {
      final server = await LauncherServer.start(
        layout: layout,
        bindings: InMemoryBindingLookup(const {}),
      );
      addTearDown(server.close);

      final socket = await connectRaw(layout.socketPath);
      addTearDown(socket.destroy);
      final welcome = await rawHello(socket, discoveryHello());
      expect(welcome['reason'], RejectReason.unknownProject);
    });

    test('invalid entry json is tolerated, project still recorded', () async {
      final pending = PendingRegistry();
      addTearDown(pending.close);
      final server = await LauncherServer.start(
        layout: layout,
        bindings: InMemoryBindingLookup(const {}),
        discovery: DiscoveryConfig(pending: pending, isIgnored: (_) => false),
      );
      addTearDown(server.close);

      final socket = await connectRaw(layout.socketPath);
      addTearDown(socket.destroy);
      final welcome = await rawHello(
        socket,
        discoveryHello(entry: {'kind': 'app'}),
      );
      expect(welcome['reason'], RejectReason.pendingApproval);
      final project = pending.byProject('stranger')!;
      expect(project.entry, isNull);
    });

    test('real SDK client lands in pending with declared facts', () async {
      final pending = PendingRegistry();
      addTearDown(pending.close);
      final server = await LauncherServer.start(
        layout: layout,
        bindings: InMemoryBindingLookup(const {}),
        discovery: DiscoveryConfig(pending: pending, isIgnored: (_) => false),
      );
      addTearDown(server.close);

      final sdk = MacLauncherSdk.connect(
        projectId: 'com.example.new-app',
        socketPath: layout.socketPath,
        retryInterval: const Duration(milliseconds: 100),
        projectName: '新应用',
        entry: SdkEntry.executable('/tmp/proj/run.sh', args: ['--serve']),
        services: {
          'svc': ServiceCallbacks(
            name: '服务',
            onStatus: () async => ServiceStatus(state: ServiceState.stopped),
          ),
        },
      );
      addTearDown(sdk.dispose);

      final rejected = sdk.states.firstWhere(
        (s) => s.state == SdkConnectionState.rejected,
      );
      expect((await rejected).reason, kRejectReasonPendingApproval);

      await until(() => pending.has('com.example.new-app'));
      final project = pending.byProject('com.example.new-app')!;
      expect(project.displayName, '新应用');
      expect(project.services.single.id, 'svc');
      expect(project.entry!.kind, SdkEntryKind.executable);
      expect(project.entry!.path, '/tmp/proj/run.sh');
      expect(project.entry!.args, ['--serve']);
    });
  });

  group('PendingRegistry', () {
    test('record upsert keeps known fields when retry omits them', () {
      final registry = PendingRegistry();
      final t1 = DateTime(2026, 1, 1, 10);
      final t2 = DateTime(2026, 1, 1, 10, 0, 5);
      registry.record(
        projectId: 'p',
        projectName: '名称',
        entry: SdkEntry.appBundle('/A.app'),
        sourceProcessPath: '/A.app/Contents/MacOS/A',
        now: t1,
      );
      registry.record(projectId: 'p', now: t2);
      final project = registry.byProject('p')!;
      expect(project.firstSeenAt, t1);
      expect(project.lastSeenAt, t2);
      expect(project.projectName, '名称');
      expect(project.entry, isNotNull);
      expect(project.sourceProcessPath, isNotNull);
    });

    test('projects are sorted by firstSeenAt and changes emit', () async {
      final registry = PendingRegistry();
      addTearDown(registry.close);
      final emissions = <List<PendingProject>>[];
      final sub = registry.changes.listen(emissions.add);
      addTearDown(sub.cancel);

      registry.record(projectId: 'b', now: DateTime(2026, 1, 1, 10, 0, 1));
      registry.record(projectId: 'a', now: DateTime(2026, 1, 1, 10, 0, 2));
      expect(registry.projects.map((p) => p.projectId), ['b', 'a']);

      final removed = registry.remove('b');
      expect(removed, isNotNull);
      expect(registry.projects.map((p) => p.projectId), ['a']);
      expect(registry.remove('missing'), isNull);

      // Broadcast stream events arrive on a later event-loop turn.
      await pumpEventQueue();
      expect(emissions, hasLength(3));
    });
  });

  group('parsePeerPids', () {
    test('extracts endpoint pids and excludes self', () {
      const output =
          'COMMAND   PID USER   FD   TYPE    DEVICE SIZE/OFF NODE NAME\n'
          'launcher 1001 usr    8u   unix 0xaaa 0t0 /tmp/sock type=STREAM '
          '->INO=0xbbb 2002,dart,5u\n'
          'dart    2002 usr    5u   unix 0xccc 0t0 type=STREAM '
          '->INO=0xddd 1001,launcher,8u\n';
      expect(parsePeerPids(output, 1001), [2002]);
      expect(parsePeerPids(output, 2002), [1001]);
    });

    test('dedupes repeated pids and tolerates non-endpoint lines', () {
      const output =
          'launcher 1001 usr 8u unix 0xaaa 0t0 /tmp/sock type=LISTEN\n'
          'launcher 1001 usr 9u unix 0xbbb 0t0 type=STREAM '
          '->INO=0xccc 2002,dart,5u\n'
          'launcher 1001 usr 10u unix 0xddd 0t0 type=STREAM '
          '->INO=0xeee 2002,dart,6u\n';
      expect(parsePeerPids(output, 1001), [2002]);
      expect(parsePeerPids('', 1001), isEmpty);
    });
  });
}
