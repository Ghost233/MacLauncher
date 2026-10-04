import 'dart:io';

import 'package:launcher_core/launcher_core.dart';
import 'package:maclauncher_sdk/maclauncher_sdk.dart';
import 'package:minimal_app/fake_business.dart';
import 'package:test/test.dart';

import 'support.dart';

void main() {
  late Directory temp;
  late EndpointLayout layout;

  setUp(() {
    temp = Directory.systemTemp.createTempSync('launcher-handshake-test');
    layout = EndpointLayout(directory: '${temp.path}/MacLauncher');
  });

  tearDown(() {
    if (temp.existsSync()) temp.deleteSync(recursive: true);
  });

  Future<LauncherServer> startServer(Set<String> projects) =>
      LauncherServer.start(
        layout: layout,
        bindings: InMemoryBindingLookup(projects),
      );

  test(
    'valid SDK connection is welcomed and capabilities are registered',
    () async {
      final server = await startServer({'proj-1'});
      addTearDown(server.close);

      final business = FakeBusiness(name: 'Demo');
      final sdk = MacLauncherSdk.connect(
        projectId: 'proj-1',
        socketPath: layout.socketPath,
        retryInterval: const Duration(milliseconds: 100),
        services: {'svc-a': business.callbacks()},
      );
      addTearDown(sdk.dispose);

      await until(() => server.registry.isActive('proj-1'));
      final project = server.registry.byProject('proj-1')!;

      expect(project.capabilities.services, hasLength(1));
      final svc = project.capabilities.services.single;
      expect(svc.id, 'svc-a');
      expect(svc.name, 'Demo');
      expect(
        svc.methods,
        containsAll([kMethodStart, kMethodRecycle, kMethodStatus, kMethodLogs]),
      );
      // Server-side activation precedes the welcome round-trip; wait for the
      // client to process it before asserting client-side state.
      await until(() => sdk.launcherSessionId != null);
      expect(sdk.launcherSessionId, isNotNull);
    },
  );

  test('only declared capabilities are visible', () async {
    final server = await startServer({'proj-1'});
    addTearDown(server.close);

    // A service that only supports status must not fake start/logs.
    final sdk = MacLauncherSdk.connect(
      projectId: 'proj-1',
      socketPath: layout.socketPath,
      services: {
        'readonly': ServiceCallbacks(
          name: 'ReadOnly',
          onStatus: () async => ServiceStatus(
            state: ServiceState.running,
            observedAt: DateTime.now().toUtc(),
          ),
        ),
      },
    );
    addTearDown(sdk.dispose);

    await until(() => server.registry.isActive('proj-1'));
    final svc = server.registry
        .byProject('proj-1')!
        .capabilities
        .services
        .single;
    expect(svc.methods, [kMethodStatus]);
  });

  test('wrong protocol version is rejected without operations', () async {
    final server = await startServer({'proj-1'});
    addTearDown(server.close);

    final socket = await connectRaw(layout.socketPath);
    addTearDown(socket.destroy);
    final welcome = await rawHello(
      socket,
      helloMessage(projectId: 'proj-1', protocolVersion: 99),
    );
    expect(welcome['accepted'], isFalse);
    expect(welcome['reason'], RejectReason.protocolVersion);
    expect(server.registry.connected, isEmpty);
  });

  test('unknown project identity is rejected', () async {
    final server = await startServer({'proj-1'});
    addTearDown(server.close);

    final socket = await connectRaw(layout.socketPath);
    addTearDown(socket.destroy);
    final welcome = await rawHello(socket, helloMessage(projectId: 'stranger'));
    expect(welcome['accepted'], isFalse);
    expect(welcome['reason'], RejectReason.unknownProject);
    expect(server.registry.connected, isEmpty);
  });

  test('second active connection for the same identity conflicts and never preempts', () async {
    final server = await startServer({'proj-1'});
    addTearDown(server.close);

    final first = MacLauncherSdk.connect(
      projectId: 'proj-1',
      socketPath: layout.socketPath,
      services: {
        'svc': ServiceCallbacks(
          name: 'First',
          onStatus: () async {
            return ServiceStatus(state: ServiceState.running);
          },
        ),
      },
    );
    addTearDown(first.dispose);
    await until(() => server.registry.isActive('proj-1'));
    final incumbentSession = server.registry
        .byProject('proj-1')!
        .launcherSessionId;

    final second = MacLauncherSdk.connect(
      projectId: 'proj-1',
      socketPath: layout.socketPath,
      retryInterval: const Duration(milliseconds: 100),
      services: {
        'svc': ServiceCallbacks(
          name: 'Second',
          onStatus: () async {
            return ServiceStatus(state: ServiceState.running);
          },
        ),
      },
    );
    addTearDown(second.dispose);

    final rejected = second.states.firstWhere(
      (s) => s.state == SdkConnectionState.rejected,
    );
    expect((await rejected).reason, RejectReason.conflict);

    // Give the challenger time to retry; the incumbent must remain.
    await Future.delayed(const Duration(milliseconds: 400));
    expect(
      server.registry.byProject('proj-1')!.launcherSessionId,
      incumbentSession,
    );
  });
}
