import 'dart:async';

import 'protocol/messages.dart';

/// The outcome of executing one request, in a form that can be replayed
/// without re-executing the business callback.
class RequestOutcome {
  RequestOutcome.result(this.value) : error = null;

  RequestOutcome.error(this.error) : value = null;

  final Object? value;
  final ProtocolError? error;
}

/// Per-connection request rules (protocol v1):
///
/// - A request id that matches an in-flight request reuses that processing;
///   the business callback never runs twice for the same id.
/// - A request id that matches a completed request replays the cached
///   outcome without re-executing.
/// - At most [completedCacheLimit] completed outcomes are retained (oldest
///   evicted first); in-flight entries are never evicted by the limit.
///
/// Instances are scoped to one connection: a new session starts with an
/// empty view, so outcomes of an old connection can never leak into it.
class RequestDedup {
  static const int completedCacheLimit = 128;

  final _inFlight = <String, Future<RequestOutcome>>{};

  /// Insertion-ordered cache of completed outcomes.
  final _completed = <String, RequestOutcome>{};

  /// Visible for diagnostics and tests.
  int get inFlightCount => _inFlight.length;
  int get completedCount => _completed.length;

  /// Runs [work] at most once for [id], reusing in-flight processing and
  /// replaying completed outcomes.
  Future<RequestOutcome> run(
    String id,
    Future<RequestOutcome> Function() work,
  ) {
    final flying = _inFlight[id];
    if (flying != null) return flying;
    final cached = _completed[id];
    if (cached != null) return Future.value(cached);

    late Future<RequestOutcome> future;
    future = work().then((outcome) {
      // Guard against a synchronous double-completion corrupting the cache.
      if (!identical(_inFlight[id], future)) return outcome;
      _inFlight.remove(id);
      _completed[id] = outcome;
      while (_completed.length > completedCacheLimit) {
        _completed.remove(_completed.keys.first);
      }
      return outcome;
    });
    _inFlight[id] = future;
    return future;
  }
}
