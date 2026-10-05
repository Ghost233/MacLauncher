import 'dart:async';

import 'package:maclauncher_sdk/maclauncher_sdk.dart';

import 'operations.dart';

/// Application connection state, shown separately from business state.
enum ServiceConnection { connected, disconnected }

/// What the UI shows for one service.
class ServiceViewState {
  const ServiceViewState({
    required this.connection,
    required this.isUnknown,
    this.confirmedStatus,
    this.reason,
    this.lastObservationAt,
  });

  final ServiceConnection connection;

  /// The current confirmed state is unknown (disconnect, read failure,
  /// timeout, or stale observation). [confirmedStatus] still holds the last
  /// confirmed snapshot for display, with its original observation time.
  final bool isUnknown;

  /// Last confirmed application-reported snapshot, verbatim. Never
  /// fabricated locally.
  final ServiceStatus? confirmedStatus;

  /// Why the state is unknown, when it is.
  final String? reason;

  /// The observation time of [confirmedStatus] exactly as the application
  /// reported it. Null when the application provided none — display must say
  /// "application report, not live-verified" rather than inventing a time.
  final DateTime? lastObservationAt;
}

/// Periodically queries one service's status along the public operations
/// seam.
///
/// Rules (spec): immediate query on start, refresh every [refreshInterval]
/// while connected, at most one in-flight query per service. Disconnect,
/// read failure, timeout, no fresh result within [staleAfter], or an expired
/// original observation all turn the confirmed state unknown while
/// preserving the last confirmed snapshot and its time. Recovery only
/// re-queries — the observer never starts, recycles, or restores business.
class StatusObserver {
  StatusObserver({
    required this.projectId,
    required this.serviceId,
    required this._operations,
    required this._isConnected,
    this._refreshInterval = const Duration(seconds: 5),
    this._staleAfter = const Duration(seconds: 15),
    DateTime Function()? clock,
  }) : _clock = clock ?? DateTime.now;

  final String projectId;
  final String serviceId;
  final ServiceOperations _operations;
  final bool Function() _isConnected;
  final Duration _refreshInterval;
  final Duration _staleAfter;
  final DateTime Function() _clock;

  final _states = StreamController<ServiceViewState>.broadcast();
  Timer? _timer;
  var _inFlight = false;
  var _running = false;

  ServiceConnection _connection = ServiceConnection.disconnected;
  ServiceStatus? _confirmed;
  DateTime? _lastObservationAt;
  DateTime? _lastSuccessAt;
  var _isUnknown = true;
  String? _reason = 'not queried yet';

  Stream<ServiceViewState> get states => _states.stream;

  ServiceViewState get current => ServiceViewState(
    connection: _connection,
    isUnknown: _isUnknown,
    confirmedStatus: _confirmed,
    reason: _reason,
    lastObservationAt: _lastObservationAt,
  );

  void start() {
    if (_running) return;
    _running = true;
    _tick();
    _timer = Timer.periodic(_refreshInterval, (_) => _tick());
  }

  void stop() {
    _running = false;
    _timer?.cancel();
    _timer = null;
  }

  Future<void> dispose() async {
    stop();
    await _states.close();
  }

  Future<void> _tick() async {
    _connection = _isConnected()
        ? ServiceConnection.connected
        : ServiceConnection.disconnected;

    // Staleness judged by real elapsed time: no fresh result for too long,
    // or the last confirmed observation itself has expired.
    final now = _clock();
    final lastSuccess = _lastSuccessAt;
    if (lastSuccess != null && now.difference(lastSuccess) > _staleAfter) {
      _markUnknown('no fresh status result for ${_staleAfter.inSeconds}s');
    }
    final observed = _lastObservationAt;
    if (!_isUnknown &&
        observed != null &&
        now.difference(observed) > _staleAfter) {
      _markUnknown('last observation expired');
    }

    // At most one in-flight status query per service.
    if (_inFlight) {
      _emit();
      return;
    }
    _inFlight = true;
    try {
      final result = await _operations.status(projectId, serviceId);
      switch (result) {
        case StatusSnapshot(:final status):
          _confirmed = status;
          _lastObservationAt = status.observedAt;
          _lastSuccessAt = _clock();
          // An already-expired observation never becomes "confirmed".
          if (status.observedAt != null &&
              _clock().difference(status.observedAt!) > _staleAfter) {
            _markUnknown('last observation expired');
          } else {
            _isUnknown = false;
            _reason = null;
          }
        case StatusUnsupported():
          _markUnknown('status unsupported');
        case StatusUnknown(:final reason):
          _markUnknown(reason);
      }
    } finally {
      _inFlight = false;
    }
    _connection = _isConnected()
        ? ServiceConnection.connected
        : ServiceConnection.disconnected;
    _emit();
  }

  void _markUnknown(String reason) {
    // Unknown never fabricates failure or stop: the last confirmed snapshot
    // is preserved untouched, only flagged.
    _isUnknown = true;
    _reason = reason;
  }

  void _emit() {
    if (!_states.isClosed) _states.add(current);
  }
}
