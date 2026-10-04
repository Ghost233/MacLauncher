import 'dart:async';
import 'dart:io';

import 'package:launcher_core/launcher_core.dart';
import 'package:maclauncher_sdk/maclauncher_sdk.dart';
import 'package:test/test.dart';

import 'support.dart';

/// A controllable fake service behind the real SDK boundary.
class _Probe {
  _Probe({this.startGate});

  /// When set, the start callback blocks until this completer completes.
  final Completer<void>? startGate;

  var startCalls = 0;
  var recycleCalls = 0;
  var statusCalls = 0;
  ServiceState state = ServiceState.stopped;
  String? instanceId = 'run-1';
  bool? ready;
  String? failWith;

  ServiceCallbacks callbacks({String name = 'probe'}) => ServiceCallbacks(
    name: name,
    onStart: () async {
      startCalls++;
      await startGate?.future;
      if (failWith != null) throw StateError(failWith!);
      state = ServiceState.running;
      ready = true;
    },
    onRecycle: () async {
      recycleCalls++;
      state = ServiceState.stopped;
      ready = null;
    },
    onStatus: () async {
      statusCalls++;
      return ServiceStatus(
        state: state,
        instanceId: instanceId,
        ready: ready,
        observedAt: DateTime.utc(2026, 10, 5, 12),
      );
    },
  );
}

void main() {
  late Directory temp;
  late EndpointLayout layout;
  late BindingStore store;

  setUp(() async {
    temp = Directory.systemTemp.createTempSync('launcher-request-test');
    layout = EndpointLayout(directory: '${temp.path}/endpoint');
    store = await BindingStore.load('${temp.path}/bindings.json');
  });

  tearDown(() {
    if (temp.existsSync()) temp.deleteSync(recursive: true);
  });

  Future<void> bindServices(List<String> serviceIds) async {
    final dir = Directory('${temp.path}/proj')..createSync(recursive: true);
    File('${dir.path}/$kManifestFileName').writeAsStringSync('''
{
  "schemaVersion": 1,
  "project": {"id": "proj-a", "name": "项目甲"},
  "services": [${serviceIds.map((id) => '{"id": "$id", "name": "$id"}').join(',')}]
}
''');
    await store.associate('${dir.path}/$kManifestFileName');
  }

  Future<(LauncherServer, MacLauncherSdk)> runningPair(
    Map<String, ServiceCallbacks> services, {
    Duration timeout = const Duration(seconds: 2),
  }) async {
    final server = await LauncherServer.start(layout: layout, bindings: store);
    addTearDown(server.close);
    final sdk = MacLauncherSdk.connect(
      projectId: 'proj-a',
      socketPath: layout.socketPath,
      services: services,
    );
    addTearDown(sdk.dispose);
    await until(() => server.registry.isActive('proj-a'));
    return (server, sdk);
  }

  ServiceOperations ops(
    LauncherServer server, {
    Duration timeout = const Duration(seconds: 2),
  }) => ServiceOperations(
    server: server,
    scope: BindingServiceScope(store),
    timeout: timeout,
  );

  test('start reaches the application callback and is acknowledged', () async {
    await bindServices(['svc']);
    final probe = _Probe();
    final (server, _) = await runningPair({'svc': probe.callbacks()});

    final outcome = await ops(server).start('proj-a', 'svc');

    expect(outcome, isA<OperationAcknowledged>());
    expect(probe.startCalls, 1);
    expect(probe.state, ServiceState.running);
  });

  test('status returns the application snapshot verbatim', () async {
    await bindServices(['svc']);
    final probe = _Probe()
      ..state = ServiceState.running
      ..ready = false;
    final (server, _) = await runningPair({'svc': probe.callbacks()});

    final result = await ops(server).status('proj-a', 'svc');

    final snapshot = (result as StatusSnapshot).status;
    expect(snapshot.state, ServiceState.running);
    expect(snapshot.instanceId, 'run-1');
    expect(snapshot.ready, isFalse);
    expect(snapshot.observedAt, DateTime.utc(2026, 10, 5, 12));
  });

  test(
    'timeout yields result-unknown: no resend, callback never cancelled',
    () async {
      await bindServices(['svc']);
      final gate = Completer<void>();
      final probe = _Probe(startGate: gate);
      final (server, _) = await runningPair({'svc': probe.callbacks()});

      final outcome = await ops(
        server,
        timeout: const Duration(milliseconds: 200),
      ).start('proj-a', 'svc');
      expect(outcome, isA<OperationUnknown>());
      expect(probe.startCalls, 1);

      // The callback still runs to completion afterwards.
      gate.complete();
      await until(() => probe.state == ServiceState.running);
      // Nothing was resent.
      expect(probe.startCalls, 1);
    },
  );

  test('unsupported capability is never sent to the application', () async {
    await bindServices(['svc']);
    var statusCalls = 0;
    final (server, _) = await runningPair({
      'svc': ServiceCallbacks(
        name: 'readonly',
        onStatus: () async {
          statusCalls++;
          return ServiceStatus(state: ServiceState.running);
        },
      ),
    });

    final outcome = await ops(server).start('proj-a', 'svc');

    expect(outcome, isA<OperationUnsupported>());
    expect(statusCalls, 0);
  });

  test(
    'business callback failure returns failed with the application reason',
    () async {
      await bindServices(['svc']);
      final probe = _Probe()..failWith = '容器未就绪';
      final (server, _) = await runningPair({'svc': probe.callbacks()});

      final outcome = await ops(server).start('proj-a', 'svc');

      expect(outcome, isA<OperationFailed>());
      expect((outcome as OperationFailed).reason, contains('容器未就绪'));
    },
  );

  test('requests outside the binding scope are not delivered', () async {
    await bindServices(['svc']);
    final probe = _Probe();
    final (server, _) = await runningPair({
      'svc': probe.callbacks(),
      // The app declares an extra service unknown to the binding.
      'extra': _Probe().callbacks(),
    });

    final outcome = await ops(server).start('proj-a', 'extra');

    expect(outcome, isA<OperationUnavailable>());
  });

  test('multiple services are operated independently', () async {
    await bindServices(['one', 'two']);
    final one = _Probe();
    final two = _Probe();
    final (server, _) = await runningPair({
      'one': one.callbacks(name: '一'),
      'two': two.callbacks(name: '二'),
    });
    final operations = ops(server);

    await operations.start('proj-a', 'one');
    expect(one.state, ServiceState.running);
    expect(two.state, ServiceState.stopped);

    final twoStatus = await operations.status('proj-a', 'two');
    expect((twoStatus as StatusSnapshot).status.state, ServiceState.stopped);

    await operations.recycle('proj-a', 'one');
    expect(one.state, ServiceState.stopped);
    expect(one.recycleCalls, 1);
    expect(two.recycleCalls, 0);
  });

  test(
    'after an acknowledged change, a fresh query observes the new state',
    () async {
      await bindServices(['svc']);
      final probe = _Probe();
      final (server, _) = await runningPair({'svc': probe.callbacks()});
      final operations = ops(server);

      final before = await operations.status('proj-a', 'svc');
      expect((before as StatusSnapshot).status.state, ServiceState.stopped);

      await operations.start('proj-a', 'svc');
      final after = await operations.status('proj-a', 'svc');
      final snapshot = (after as StatusSnapshot).status;
      expect(snapshot.state, ServiceState.running);
      expect(snapshot.ready, isTrue);
    },
  );
}
