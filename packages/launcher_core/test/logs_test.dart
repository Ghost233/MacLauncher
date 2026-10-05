import 'dart:async';
import 'dart:io';

import 'package:launcher_core/launcher_core.dart';
import 'package:maclauncher_sdk/maclauncher_sdk.dart';
import 'package:test/test.dart';

import 'support.dart';

/// A controlled logs provider behind the real SDK boundary.
class _LogsProbe {
  _LogsProbe({this.failWith});

  final String? failWith;

  var logsCalls = 0;
  final receivedLimits = <int>[];

  /// Completed while a query is in flight, released by the test.
  Completer<void>? gate;

  /// Batches served in order; the last one repeats when exhausted.
  List<LogBatch> batches = [
    LogBatch(
      entries: [LogEntry(text: 'line-1')],
      instanceId: 'run-1',
      observedAt: DateTime.utc(2026, 10, 5, 12),
    ),
  ];

  ServiceCallbacks callbacks({String name = 'probe'}) => ServiceCallbacks(
    name: name,
    onStatus: () async => ServiceStatus(state: ServiceState.running),
    onLogs: (query) async {
      logsCalls++;
      receivedLimits.add(query.limit);
      await gate?.future;
      if (failWith != null) throw StateError(failWith!);
      final batch =
          batches[logsCalls - 1 < batches.length
              ? logsCalls - 1
              : batches.length - 1];
      // Enforce the contract server-side expectations rely on: at most
      // limit entries, oldest first.
      final entries = batch.entries.length > query.limit
          ? batch.entries.sublist(batch.entries.length - query.limit)
          : batch.entries;
      return LogBatch(
        entries: entries,
        instanceId: batch.instanceId,
        truncated: batch.truncated,
        observedAt: batch.observedAt,
      );
    },
  );
}

void main() {
  late Directory temp;
  late EndpointLayout layout;
  late BindingStore store;

  setUp(() async {
    temp = Directory.systemTemp.createTempSync('launcher-logs-test');
    layout = EndpointLayout(directory: '${temp.path}/endpoint');
    store = await BindingStore.load('${temp.path}/bindings.json');
    final dir = Directory('${temp.path}/proj')..createSync();
    File('${dir.path}/$kManifestFileName').writeAsStringSync('''
{
  "schemaVersion": 1,
  "project": {"id": "proj-a", "name": "项目甲"},
  "services": [{"id": "svc", "name": "svc"}, {"id": "extra", "name": "extra"}]
}
''');
    await store.associate('${dir.path}/$kManifestFileName');
  });

  tearDown(() {
    if (temp.existsSync()) temp.deleteSync(recursive: true);
  });

  Future<(LauncherServer, MacLauncherSdk)> runningPair(
    Map<String, ServiceCallbacks> services,
  ) async {
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

  ServiceOperations ops(LauncherServer server) => ServiceOperations(
    server: server,
    scope: BindingServiceScope(store),
    timeout: const Duration(seconds: 2),
  );

  group('ServiceOperations.logs', () {
    test(
      'batch passes through verbatim: nulls stay null, nothing invented',
      () async {
        final probe = _LogsProbe()
          ..batches = [
            LogBatch(
              entries: [
                LogEntry(
                  text: 'early',
                  timestamp: DateTime.utc(2026, 10, 5, 8),
                  stream: LogStream.stdout,
                ),
                // No timestamp, unknown stream: must survive as null/unknown.
                LogEntry(text: 'late'),
              ],
              instanceId: 'run-7',
              truncated: true,
              observedAt: DateTime.utc(2026, 10, 5, 12),
            ),
          ];
        final (server, _) = await runningPair({'svc': probe.callbacks()});

        final result = await ops(server).logs('proj-a', 'svc');

        final batch = (result as LogsBatch).batch;
        expect(batch.entries.map((e) => e.text), ['early', 'late']);
        expect(batch.entries[0].timestamp, DateTime.utc(2026, 10, 5, 8));
        expect(batch.entries[0].stream, LogStream.stdout);
        expect(batch.entries[1].timestamp, isNull);
        expect(batch.entries[1].stream, LogStream.unknown);
        expect(batch.instanceId, 'run-7');
        expect(batch.truncated, isTrue);
        expect(batch.observedAt, DateTime.utc(2026, 10, 5, 12));
      },
    );

    test('limit defaults to 200 and clamps into 1–500', () async {
      final probe = _LogsProbe();
      final (server, _) = await runningPair({'svc': probe.callbacks()});
      final o = ops(server);

      await o.logs('proj-a', 'svc');
      await o.logs('proj-a', 'svc', limit: 99999);
      await o.logs('proj-a', 'svc', limit: 0);

      expect(probe.receivedLimits, [200, 500, 1]);
    });

    test(
      'missing logs capability yields unsupported without any query',
      () async {
        final (server, _) = await runningPair({
          'svc': ServiceCallbacks(
            name: 'svc',
            onStatus: () async => ServiceStatus(state: ServiceState.running),
          ),
        });

        final result = await ops(server).logs('proj-a', 'svc');

        expect(result, isA<LogsUnsupported>());
      },
    );

    test('application read failure yields failed with its reason', () async {
      final (server, _) = await runningPair({
        'svc': _LogsProbe(failWith: 'log file corrupted').callbacks(),
      });

      final result = await ops(server).logs('proj-a', 'svc');

      expect((result as LogsFailed).reason, contains('log file corrupted'));
    });

    test('services outside the binding scope are never queried', () async {
      final probe = _LogsProbe();
      final (server, _) = await runningPair({
        'svc': probe.callbacks(),
        // Declared by the app but not declared in the manifest scope test:
        // 'ghost' is neither in the manifest nor registered.
        'extra': probe.callbacks(name: 'extra'),
      });

      final result = await ops(server).logs('proj-a', 'ghost');

      expect(result, isA<LogsUnknown>());
      expect((result as LogsUnknown).reason, contains('out of binding scope'));
      expect(probe.logsCalls, 0);
    });
  });

  group('LogViewModel', () {
    const tick = Duration(milliseconds: 50);

    Future<(LogViewModel, _LogsProbe)> openPanel(
      LauncherServer server,
      _LogsProbe probe,
    ) async {
      final vm = LogViewModel(
        operations: ops(server),
        projectId: 'proj-a',
        serviceId: 'svc',
        pollInterval: tick,
      );
      vm.open();
      await until(() => vm.current.kind == LogViewKind.batch);
      return (vm, probe);
    }

    test(
      'while open it queries every interval; close freezes all queries',
      () async {
        final probe = _LogsProbe();
        final (server, _) = await runningPair({'svc': probe.callbacks()});
        final (vm, _) = await openPanel(server, probe);
        addTearDown(vm.dispose);

        await until(() => probe.logsCalls >= 3);
        vm.close();
        final frozen = probe.logsCalls;
        await Future.delayed(tick * 4);
        expect(probe.logsCalls, frozen);
        expect(vm.isOpen, isFalse);
      },
    );

    test('a slow query delays the next tick and never stacks', () async {
      final probe = _LogsProbe()..gate = Completer<void>();
      final (server, _) = await runningPair({'svc': probe.callbacks()});
      final vm = LogViewModel(
        operations: ops(server),
        projectId: 'proj-a',
        serviceId: 'svc',
        pollInterval: tick,
      );
      addTearDown(vm.dispose);
      vm.open();
      await until(() => probe.logsCalls == 1);

      // Several intervals pass while the first query is still gated.
      await Future.delayed(tick * 4);
      expect(probe.logsCalls, 1);
      expect(vm.querying, isTrue);

      probe.gate!.complete();
      await until(() => vm.current.kind == LogViewKind.batch);
      await until(() => probe.logsCalls >= 2);
    });

    test('every result replaces the previous batch, never appends', () async {
      final probe = _LogsProbe()
        ..batches = [
          LogBatch(
            entries: [
              LogEntry(text: 'one'),
              LogEntry(text: 'two'),
            ],
          ),
          LogBatch(entries: [LogEntry(text: 'three')]),
        ];
      final (server, _) = await runningPair({'svc': probe.callbacks()});
      final (vm, _) = await openPanel(server, probe);
      addTearDown(vm.dispose);

      await until(() => probe.logsCalls >= 2);
      // The call count is app-side; the view update trails it by one async
      // hop. Wait on the state itself, not the counter.
      await until(
        () =>
            vm.current.kind == LogViewKind.batch &&
            vm.current.batch!.entries.map((e) => e.text).join(',') == 'three',
      );

      final state = vm.current;
      expect(state.kind, LogViewKind.batch);
      expect(state.batch!.entries.map((e) => e.text), ['three']);
    });

    test('failure keeps the previous batch explicitly marked stale', () async {
      final probe = _FlakyLogsProbe()
        ..batches = [
          LogBatch(entries: [LogEntry(text: 'good')]),
        ];
      final (server, _) = await runningPair({'svc': probe.callbacks()});
      final (vm, _) = await openPanel(server, probe);
      addTearDown(vm.dispose);

      probe.failNext = true;
      await until(() => vm.current.kind == LogViewKind.staleBatch);

      final state = vm.current;
      expect(state.isStale, isTrue);
      expect(state.batch!.entries.map((e) => e.text), ['good']);
      expect(state.reason, contains('boom'));
    });

    test('an empty batch is distinct from failure', () async {
      final probe = _LogsProbe()..batches = [LogBatch(entries: const [])];
      final (server, _) = await runningPair({'svc': probe.callbacks()});
      final (vm, _) = await openPanel(server, probe);
      addTearDown(vm.dispose);

      expect(vm.current.kind, LogViewKind.batch);
      expect(vm.current.isEmpty, isTrue);
    });

    test('results landing after close are discarded', () async {
      final probe = _LogsProbe()..gate = Completer<void>();
      final (server, _) = await runningPair({'svc': probe.callbacks()});
      final vm = LogViewModel(
        operations: ops(server),
        projectId: 'proj-a',
        serviceId: 'svc',
        pollInterval: tick,
      );
      addTearDown(vm.dispose);
      vm.open();
      await until(() => probe.logsCalls == 1);

      vm.close();
      probe.gate!.complete();
      await Future.delayed(tick * 3);

      expect(vm.current.kind, LogViewKind.loading);
      expect(probe.logsCalls, 1);
    });

    test('a batch without instance scope is labelled, not implied', () async {
      final probe = _LogsProbe()
        ..batches = [
          LogBatch(entries: [LogEntry(text: 'x')]),
        ];
      final (server, _) = await runningPair({'svc': probe.callbacks()});
      final (vm, _) = await openPanel(server, probe);
      addTearDown(vm.dispose);

      expect(vm.current.instanceScopeMissing, isTrue);
    });
  });
}

/// Serves one good batch, then fails when [failNext] is set.
class _FlakyLogsProbe extends _LogsProbe {
  bool failNext = false;

  @override
  ServiceCallbacks callbacks({String name = 'probe'}) {
    final base = super.callbacks(name: name);
    return ServiceCallbacks(
      name: name,
      onStatus: base.onStatus,
      onLogs: (query) async {
        if (failNext) {
          failNext = false;
          logsCalls++;
          throw StateError('boom');
        }
        return base.onLogs!(query);
      },
    );
  }
}
