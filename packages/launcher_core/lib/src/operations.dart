import 'dart:async';

import 'package:maclauncher_sdk/maclauncher_sdk.dart';

import 'binding_store.dart';
import 'server.dart';

/// Default time the launcher waits for a request response. On expiry the
/// result is shown as unknown: the application's callback is never cancelled
/// and nothing is resent or force-stopped.
const Duration kDefaultRequestTimeout = Duration(seconds: 30);

/// Outcome of a start/recycle change request. Sending successfully never
/// means the business has completed the change.
sealed class OperationOutcome {
  const OperationOutcome();
}

/// The application acknowledged the request; refresh status to observe the
/// actual business state.
class OperationAcknowledged extends OperationOutcome {
  const OperationAcknowledged();
}

/// The application does not provide this capability.
class OperationUnsupported extends OperationOutcome {
  const OperationUnsupported();
}

/// The application's business callback reported failure, with its reason.
class OperationFailed extends OperationOutcome {
  const OperationFailed(this.reason);

  final String reason;
}

/// The same service is already processing a change (busy).
class OperationBusy extends OperationOutcome {
  const OperationBusy();
}

/// No response within the wait window: result unknown. Nothing was resent.
class OperationUnknown extends OperationOutcome {
  const OperationUnknown();
}

/// The request cannot be routed: project not connected, or the service is
/// outside the confirmed binding scope.
class OperationUnavailable extends OperationOutcome {
  const OperationUnavailable(this.reason);

  final String reason;
}

/// Result of a status query.
sealed class StatusResult {
  const StatusResult();
}

class StatusSnapshot extends StatusResult {
  const StatusSnapshot(this.status);

  /// Verbatim application-reported snapshot; never locally fabricated.
  final ServiceStatus status;
}

class StatusUnsupported extends StatusResult {
  const StatusUnsupported();
}

class StatusUnknown extends StatusResult {
  const StatusUnknown(this.reason);

  final String reason;
}

/// Which services requests may be routed to: only confirmed binding scope.
abstract class ServiceScopeLookup {
  bool isServiceInScope(String projectId, String serviceId);
}

/// Scope backed by the local binding store.
class BindingServiceScope implements ServiceScopeLookup {
  BindingServiceScope(this._store);

  final BindingStore _store;

  @override
  bool isServiceInScope(String projectId, String serviceId) {
    final binding = _store.byProjectId(projectId);
    if (binding == null) return false;
    return binding.services.any((s) => s.id == serviceId);
  }
}

/// Launcher-side service operations over live SDK sessions.
class ServiceOperations {
  ServiceOperations({
    required LauncherServer server,
    required ServiceScopeLookup scope,
    Duration timeout = kDefaultRequestTimeout,
  }) : _server = server,
       _scope = scope,
       _timeout = timeout;

  final LauncherServer _server;
  final ServiceScopeLookup _scope;
  final Duration _timeout;

  Future<OperationOutcome> start(String projectId, String serviceId) =>
      _change(kMethodStart, projectId, serviceId);

  Future<OperationOutcome> recycle(String projectId, String serviceId) =>
      _change(kMethodRecycle, projectId, serviceId);

  Future<StatusResult> status(String projectId, String serviceId) async {
    final check = _route(projectId, serviceId, kMethodStatus);
    if (check != null) {
      return switch (check) {
        _RouteBlock.unsupported => const StatusUnsupported(),
        _RouteBlock.outOfScope => StatusUnknown(
          'service out of binding scope: $serviceId',
        ),
        _RouteBlock.notConnected => const StatusUnknown(
          'application not connected',
        ),
      };
    }
    try {
      final response = await _server
          .sessionFor(projectId)!
          .sendRequest(kMethodStatus, serviceId: serviceId, timeout: _timeout);
      final error = (response['error'] as Map?)?.cast<String, Object?>();
      if (error != null) {
        return error['code'] == ProtocolError.unsupported
            ? const StatusUnsupported()
            : StatusUnknown('${error['code']}: ${error['message']}');
      }
      final result = (response['result'] as Map?)?.cast<String, Object?>();
      if (result == null) return const StatusUnknown('empty result');
      return StatusSnapshot(ServiceStatus.fromJson(result));
    } on TimeoutException {
      return const StatusUnknown('timeout');
    } catch (e) {
      return StatusUnknown('$e');
    }
  }

  Future<OperationOutcome> _change(
    String method,
    String projectId,
    String serviceId,
  ) async {
    final check = _route(projectId, serviceId, method);
    if (check != null) {
      return switch (check) {
        _RouteBlock.unsupported => const OperationUnsupported(),
        _RouteBlock.outOfScope => OperationUnavailable(
          'service out of binding scope: $serviceId',
        ),
        _RouteBlock.notConnected => const OperationUnavailable(
          'application not connected',
        ),
      };
    }
    try {
      final response = await _server
          .sessionFor(projectId)!
          .sendRequest(method, serviceId: serviceId, timeout: _timeout);
      final error = (response['error'] as Map?)?.cast<String, Object?>();
      if (error == null) return const OperationAcknowledged();
      return switch (error['code']) {
        ProtocolError.unsupported => const OperationUnsupported(),
        ProtocolError.busy => const OperationBusy(),
        _ => OperationFailed('${error['message']}'),
      };
    } on TimeoutException {
      return const OperationUnknown();
    } catch (e) {
      return OperationUnavailable('$e');
    }
  }

  /// Returns why the request must not be sent, or null when routing is
  /// allowed. Only capabilities the application registered and the binding
  /// scope allows may be invoked.
  _RouteBlock? _route(String projectId, String serviceId, String method) {
    if (!_scope.isServiceInScope(projectId, serviceId)) {
      return _RouteBlock.outOfScope;
    }
    final project = _server.registry.byProject(projectId);
    if (project == null) {
      return _RouteBlock.notConnected;
    }
    final service = project.capabilities.serviceById(serviceId);
    if (service == null || !service.supports(method)) {
      return _RouteBlock.unsupported;
    }
    return null;
  }
}

enum _RouteBlock { outOfScope, notConnected, unsupported }
