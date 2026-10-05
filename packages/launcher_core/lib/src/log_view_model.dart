import 'dart:async';

import 'package:maclauncher_sdk/maclauncher_sdk.dart';

import 'operations.dart';

/// Default panel polling cadence while the log panel is open.
const Duration kLogPollInterval = Duration(seconds: 2);

/// What the log panel should render.
enum LogViewKind {
  /// Nothing queried yet (panel just opened, first query in flight).
  loading,

  /// A fresh batch, replacing any previous content.
  batch,

  /// The last good batch kept after a later query failed, explicitly marked
  /// as old content.
  staleBatch,

  /// The application does not provide the logs capability.
  unsupported,

  /// The application reported a read failure and no batch is held.
  failed,

  /// Timeout/disconnect and no batch is held.
  unknown,
}

class LogViewState {
  const LogViewState._(this.kind, {this.batch, this.reason});

  final LogViewKind kind;

  /// Present for [LogViewKind.batch] and [LogViewKind.staleBatch].
  final LogBatch? batch;

  /// Failure detail for [LogViewKind.failed]/[LogViewKind.unknown] and the
  /// reason a stale batch is stale.
  final String? reason;

  bool get isStale => kind == LogViewKind.staleBatch;

  /// True when the current batch lacks a run scope; the UI must label it
  /// 未提供实例范围 rather than implying it covers the current run.
  bool get instanceScopeMissing => batch != null && batch!.instanceId == null;

  /// A successful read with no entries — distinct from unsupported/failed.
  bool get isEmpty => kind == LogViewKind.batch && (batch!.entries.isEmpty);

  static const loading = LogViewState._(LogViewKind.loading);
}

/// Read model behind the log panel for one project+service.
///
/// Lifecycle follows the panel: [open] starts a non-overlapping query chain
/// (a slow query delays the next tick, never stacks), [close] stops all
/// further queries immediately. Every successful result REPLACES the current
/// batch — no append, merge, or cursor inference. After reconnect or a new
/// run instance the next tick simply reads a fresh batch; results arriving
/// after close or from a superseded query are discarded.
class LogViewModel {
  LogViewModel({
    required this._operations,
    required this.projectId,
    required this.serviceId,
    this.limit,
    this.pollInterval = kLogPollInterval,
  });

  final ServiceOperations _operations;
  final String projectId;
  final String serviceId;
  final int? limit;
  final Duration pollInterval;

  final _states = StreamController<LogViewState>.broadcast();
  LogViewState _current = LogViewState.loading;

  /// Bumped on every open/close so late results from a previous generation
  /// can never overwrite the current view.
  var _generation = 0;
  var _open = false;
  var _querying = false;

  Stream<LogViewState> get states => _states.stream;
  LogViewState get current => _current;

  bool get isOpen => _open;

  /// Number of queries issued — diagnostics and tests.
  int get queryCount => _queryCount;
  var _queryCount = 0;

  /// Whether a query is in flight right now.
  bool get querying => _querying;

  void open() {
    if (_open) return;
    _open = true;
    _generation++;
    _emit(LogViewState.loading, _generation);
    unawaited(_tick(_generation));
  }

  void close() {
    if (!_open) return;
    _open = false;
    // Invalidate in-flight results; the chain checks this before scheduling
    // any further query.
    _generation++;
  }

  Future<void> _tick(int generation) async {
    while (_open && generation == _generation) {
      _querying = true;
      _queryCount++;
      final result = await _operations.logs(projectId, serviceId, limit: limit);
      _querying = false;
      if (!_open || generation != _generation) return; // superseded/closed
      _emit(_map(result), generation);
      await Future.delayed(pollInterval);
    }
  }

  LogViewState _map(LogsResult result) => switch (result) {
    LogsBatch(batch: final batch) => LogViewState._(
      LogViewKind.batch,
      batch: batch,
    ),
    LogsUnsupported() => const LogViewState._(LogViewKind.unsupported),
    LogsFailed(reason: final reason) => _holdBatch(LogViewKind.failed, reason),
    LogsUnknown(reason: final reason) => _holdBatch(
      LogViewKind.unknown,
      reason,
    ),
  };

  /// On failure, keep the previous batch explicitly marked as old content.
  LogViewState _holdBatch(LogViewKind kind, String reason) {
    final held = _current.batch;
    if (held != null) {
      return LogViewState._(
        LogViewKind.staleBatch,
        batch: held,
        reason: reason,
      );
    }
    return LogViewState._(kind, reason: reason);
  }

  void _emit(LogViewState state, int generation) {
    if (generation != _generation) return;
    _current = state;
    if (!_states.isClosed) _states.add(state);
  }

  Future<void> dispose() async {
    close();
    await _states.close();
  }
}
