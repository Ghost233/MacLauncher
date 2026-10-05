import 'dart:async';
import 'dart:io';

import 'package:launcher_core/launcher_core.dart';
import 'package:maclauncher_sdk/maclauncher_sdk.dart';
import 'package:test/test.dart';

import 'support.dart';

/// A controllable service behind the real SDK: status behaviour is scripted
/// per test, start/recycle only count calls.
class ScriptedService {
  int statusCalls = 0;
  int startCalls = 0;
  int recycleCalls = 0;

  Future<ServiceStatus> Function() onStatus = () async => ServiceStatus(
    state: ServiceState.running,
    observedAt: DateTime.now().toUtc(),
  );

  ServiceCallbacks callbacks() => ServiceCallbacks(
    name: 'scripted',
    onStart: () async => startCalls++,
    onRecycle: () async => recycleCalls++,
    onStatus: () {
      statusCalls++;
      return onStatus();
    },
  );
}

void main() {
  late Directory temp;
  late EndpointLayout layout;

  setUp(() {
    temp = Directory.systemTemp.createTempSync('launcher-observer-test');
    layout = EndpointLayout(directory: '${temp.path}/endpoint');
  });

  tearDown(() {
    if (temp.existsSync()) temp.deleteSync(recursive: true);
  });

  MacLauncherSdk connectSdk(ScriptedService service) {
    final sdk = MacLauncherSdk.connect(
      projectId: 'proj-a',
      socketPath: layout.socketPath,
      retryInterval: const Duration(milliseconds: 100),
      services: {'svc': service.callbacks()},
    );
    addTearDown(sdk.dispose);
    return sdk;
  }

  StatusObserver makeObserver(
    LauncherServer server,
    BindingStore store, {
    Duration refreshInterval = const Duration(milliseconds: 50),
    Duration staleAfter = const Duration(milliseconds: 300),
  }) {
    final observer = StatusObserver(
      projectId: 'proj-a',
      serviceId: 'svc',
      operations: ServiceOperations(
        server: server,
        scope: BindingServiceScope(store),
        timeout: const Duration(seconds: 2),
      ),
      isConnected: () => server.registry.isActive('proj-a'),
      refreshInterval: refreshInterval,
      staleAfter: staleAfter,
    );
    addTearDown(observer.dispose);
    return observer;
  }

  // The store used for scope must be the same one handed to the server.
  Future<(LauncherServer, BindingStore)> startServerWithStore() async {
    final store = await BindingStore.load('${temp.path}/bindings.json');
    final dir = Directory('${temp.path}/proj')..createSync();
    File('${dir.path}/$kManifestFileName').writeAsStringSync('''
{
  "schemaVersion": 1,
  "project": {"id": "proj-a", "name": "项目甲"},
  "services": [{"id": "svc", "name": "服务"}]
}
''');
    await store.associate('${dir.path}/$kManifestFileName');
    final server = await LauncherServer.start(layout: layout, bindings: store);
    addTearDown(server.close);
    return (server, store);
  }

  test('queries immediately and then every refresh interval', () async {
    final (server, store) = await startServerWithStore();
    final service = ScriptedService();
    connectSdk(service);
    await until(() => server.registry.isActive('proj-a'));

    final observer = makeObserver(server, store);
    observer.start();

    // Immediate query…
    await until(() => service.statusCalls >= 1);
    final afterFirst = service.statusCalls;
    // …then periodic refreshes.
    await Future.delayed(const Duration(milliseconds: 260));
    expect(service.statusCalls, greaterThan(afterFirst + 2));
    expect(observer.current.isUnknown, isFalse);
    expect(observer.current.connection, ServiceConnection.connected);
  });

  test('disconnect turns state unknown and keeps the last snapshot', () async {
    final (server, store) = await startServerWithStore();
    final service = ScriptedService();
    var sdk = connectSdk(service);
    await until(() => server.registry.isActive('proj-a'));

    final observer = makeObserver(server, store);
    observer.start();
    await until(() => !observer.current.isUnknown);
    expect(observer.current.confirmedStatus?.state, ServiceState.running);

    await sdk.dispose();
    await until(() => observer.current.isUnknown);

    final view = observer.current;
    expect(view.connection, ServiceConnection.disconnected);
    // The last confirmed snapshot is preserved for display — never erased
    // and never rewritten as failed/stopped.
    expect(view.confirmedStatus?.state, ServiceState.running);
    expect(view.reason, isNotNull);
  });

  test('an expired application observation is shown as unknown', () async {
    final (server, store) = await startServerWithStore();
    final service = ScriptedService();
    // The app reports a stale observation time (e.g. its own cached read).
    service.onStatus = () async => ServiceStatus(
      state: ServiceState.running,
      observedAt: DateTime.now().toUtc().subtract(const Duration(minutes: 1)),
    );
    connectSdk(service);
    await until(() => server.registry.isActive('proj-a'));

    final observer = makeObserver(server, store);
    observer.start();

    await until(
      () =>
          observer.current.isUnknown &&
          observer.current.confirmedStatus != null,
    );
    expect(observer.current.reason, contains('expired'));
    // Snapshot preserved verbatim, including its original time.
    expect(observer.current.confirmedStatus?.state, ServiceState.running);
    expect(observer.current.lastObservationAt, isNotNull);
  });

  test(
    'a missing observation time is preserved as null (report-only)',
    () async {
      final (server, store) = await startServerWithStore();
      final service = ScriptedService();
      service.onStatus = () async =>
          ServiceStatus(state: ServiceState.running); // no observedAt
      connectSdk(service);
      await until(() => server.registry.isActive('proj-a'));

      final observer = makeObserver(server, store);
      observer.start();
      await until(() => !observer.current.isUnknown);

      // Not filled in with the local receive time.
      expect(observer.current.lastObservationAt, isNull);
    },
  );

  test(
    'recovery only re-queries; it never starts or recycles business',
    () async {
      final (server, store) = await startServerWithStore();
      final service = ScriptedService();
      final first = connectSdk(service);
      await until(() => server.registry.isActive('proj-a'));

      final observer = makeObserver(server, store);
      observer.start();
      await until(() => !observer.current.isUnknown);

      await first.dispose();
      await until(() => observer.current.isUnknown);
      final callsWhileDown = service.statusCalls;

      // A new SDK session for the same project reconnects.
      connectSdk(service);
      await until(() => !observer.current.isUnknown);

      expect(service.statusCalls, greaterThan(callsWhileDown));
      expect(service.startCalls, 0);
      expect(service.recycleCalls, 0);
    },
  );

  test('at most one status query is in flight per service', () async {
    final (server, store) = await startServerWithStore();
    final service = ScriptedService();
    final gate = Completer<void>();
    service.onStatus = () => gate.future.then(
      (_) => ServiceStatus(
        state: ServiceState.running,
        observedAt: DateTime.now().toUtc(),
      ),
    );
    connectSdk(service);
    await until(() => server.registry.isActive('proj-a'));

    final observer = makeObserver(
      server,
      store,
      staleAfter: const Duration(seconds: 30),
    );
    observer.start();

    await until(() => service.statusCalls == 1);
    // Several refresh ticks pass while the first query is gated.
    await Future.delayed(const Duration(milliseconds: 220));
    expect(service.statusCalls, 1);

    gate.complete();
    await until(() => service.statusCalls > 1);
  });

  test('no fresh result within staleAfter turns the state unknown', () async {
    final (server, store) = await startServerWithStore();
    final service = ScriptedService();
    final gate = Completer<void>();
    var first = true;
    service.onStatus = () {
      if (first) {
        first = false;
        return Future.value(
          ServiceStatus(
            state: ServiceState.running,
            observedAt: DateTime.now().toUtc(),
          ),
        );
      }
      // Subsequent queries hang: no fresh results arrive.
      return gate.future.then(
        (_) => ServiceStatus(
          state: ServiceState.running,
          observedAt: DateTime.now().toUtc(),
        ),
      );
    };
    connectSdk(service);
    await until(() => server.registry.isActive('proj-a'));

    final observer = makeObserver(server, store);
    observer.start();
    await until(() => !observer.current.isUnknown);

    await until(
      () => observer.current.isUnknown,
      timeout: const Duration(seconds: 3),
    );
    expect(observer.current.reason, contains('no fresh status result'));
    expect(observer.current.confirmedStatus?.state, ServiceState.running);
  });
}
