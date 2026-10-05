import 'package:maclauncher_sdk/maclauncher_sdk.dart';

/// A controlled fake business used by the minimal peer app. It only models
/// state transitions in memory so tests can observe real request delivery
/// and reported snapshots through the public SDK boundary.
class FakeBusiness {
  FakeBusiness({required this.name});

  final String name;

  ServiceState _state = ServiceState.stopped;
  String? _instanceId;
  int _runCounter = 0;
  final List<String> _log = [];

  int startCalls = 0;
  int recycleCalls = 0;

  ServiceCallbacks callbacks() => ServiceCallbacks(
    name: name,
    onStart: _start,
    onRecycle: _recycle,
    onStatus: _status,
    onLogs: _logs,
  );

  Future<void> _start() async {
    startCalls++;
    // Repeated start of an already-running service safely reuses the run.
    if (_state == ServiceState.running) return;
    _state = ServiceState.running;
    _instanceId = 'run-${++_runCounter}';
    _log.add(
      '[${DateTime.now().toUtc().toIso8601String()}] $name started ($_instanceId)',
    );
  }

  Future<void> _recycle() async {
    recycleCalls++;
    _log.add(
      '[${DateTime.now().toUtc().toIso8601String()}] $name recycled ($_instanceId)',
    );
    _state = ServiceState.stopped;
  }

  Future<ServiceStatus> _status() async => ServiceStatus(
    state: _state,
    instanceId: _instanceId,
    ready: _state == ServiceState.running ? true : null,
    observedAt: DateTime.now().toUtc(),
  );

  Future<LogBatch> _logs(LogQuery query) async {
    final entries = _log.length > query.limit
        ? _log.sublist(_log.length - query.limit)
        : List.of(_log);
    return LogBatch(
      entries: [for (final line in entries) LogEntry(text: line)],
      instanceId: _instanceId,
      truncated: _log.length > query.limit,
      observedAt: DateTime.now().toUtc(),
    );
  }
}
