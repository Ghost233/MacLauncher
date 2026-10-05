import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'protocol/codec.dart';
import 'protocol/messages.dart';
import 'request_dedup.dart';

/// Callbacks for one service. Only register what the application actually
/// supports; the declared capability set is derived from the callbacks that
/// are present, so no fake readiness/log/window interfaces are needed.
class ServiceCallbacks {
  ServiceCallbacks({
    required this.name,
    this.onStart,
    this.onRecycle,
    this.onStatus,
    this.onLogs,
  });

  /// Display name; not part of identity.
  final String name;

  final Future<void> Function()? onStart;
  final Future<void> Function()? onRecycle;
  final Future<ServiceStatus> Function()? onStatus;
  final Future<LogBatch> Function(LogQuery query)? onLogs;

  List<String> get methods => [
    if (onStart != null) kMethodStart,
    if (onRecycle != null) kMethodRecycle,
    if (onStatus != null) kMethodStatus,
    if (onLogs != null) kMethodLogs,
  ];
}

/// Optional app-level callbacks for entry/window cooperation and version
/// status queries.
class AppCallbacks {
  AppCallbacks({
    this.onOpenWindow,
    this.onSetEntryManaged,
    this.onVersionStatus,
  });

  final Future<void> Function()? onOpenWindow;

  /// The launcher asks the app to temporarily hide (managed=true) or restore
  /// (managed=false) its own menu-bar entry. Returns true on confirmation.
  final Future<bool> Function(bool managed)? onSetEntryManaged;

  /// The launcher asks for the app's version status (版本状况). The app
  /// decides how it queries its own update source and reports the real
  /// outcome, including failure and 「不支持更新」.
  final Future<VersionStatus> Function()? onVersionStatus;

  List<String> get methods => [
    if (onOpenWindow != null) kMethodOpenWindow,
    if (onSetEntryManaged != null) kMethodSetEntryManaged,
    if (onVersionStatus != null) kMethodVersionStatus,
  ];
}

enum SdkConnectionState { disconnected, connecting, connected, rejected }

class SdkConnectionStatus {
  SdkConnectionStatus(this.state, {this.reason});

  final SdkConnectionState state;

  /// Rejection or failure detail, when relevant.
  final String? reason;
}

/// Public SDK entry point for a standalone application.
///
/// The SDK owns local communication, reconnection, request/response routing
/// and entry cooperation. It never spawns, supervises or recycles business
/// processes; [dispose] only returns the entry and closes communication.
class MacLauncherSdk {
  MacLauncherSdk._({
    required this.projectId,
    required this._services,
    required this._app,
    required this._socketPath,
    required this._retryInterval,
    required this._pingInterval,
    required this._pongTimeout,
  }) {
    _appSessionId = _newSessionId();
    _loop = Future(_runLoop);
  }

  /// Connects to the launcher listener and keeps the connection alive across
  /// launcher restarts. Returns immediately; the connection runs in the
  /// background and never blocks the application's own operation.
  static MacLauncherSdk connect({
    required String projectId,
    required Map<String, ServiceCallbacks> services,
    AppCallbacks? app,
    String? socketPath,
    Duration retryInterval = const Duration(seconds: 5),
    Duration pingInterval = const Duration(seconds: 5),
    Duration pongTimeout = const Duration(seconds: 15),
  }) {
    return MacLauncherSdk._(
      projectId: projectId,
      services: services,
      app: app,
      socketPath: socketPath ?? defaultSocketPath(),
      retryInterval: retryInterval,
      pingInterval: pingInterval,
      pongTimeout: pongTimeout,
    );
  }

  /// Fixed SDK discovery convention: user-private directory.
  static String defaultSocketPath({String? home}) {
    final base = home ?? Platform.environment['HOME'] ?? '.';
    return '$base/Library/Application Support/MacLauncher/sdk-v1.sock';
  }

  final String projectId;
  final Map<String, ServiceCallbacks> _services;
  final AppCallbacks? _app;
  final String _socketPath;
  final Duration _retryInterval;
  final Duration _pingInterval;
  final Duration _pongTimeout;

  late final String _appSessionId;
  late final Future<void> _loop;
  final _states = StreamController<SdkConnectionStatus>.broadcast();
  bool _disposed = false;
  final _stop = Completer<void>();
  ConnectionTask<Socket>? _connecting;
  Future<void>? _disposeFuture;

  /// Visible attempt counter, primarily for diagnostics and tests.
  int get connectAttempts => _connectAttempts;
  int _connectAttempts = 0;

  /// The launcher session id of the current accepted connection, if any.
  String? get launcherSessionId => _launcherSessionId;
  String? _launcherSessionId;

  Socket? _activeSocket;

  /// Services with a start/recycle callback currently running. Scoped to the
  /// SDK (not one connection): business mutations of the same service never
  /// run concurrently, even across reconnects. status/logs are unaffected.
  final _mutationGates = <String>{};

  Stream<SdkConnectionStatus> get states => _states.stream;

  CapabilitySet get capabilities => CapabilitySet(
    services: [
      for (final entry in _services.entries)
        ServiceDeclaration(
          id: entry.key,
          name: entry.value.name,
          methods: entry.value.methods,
        ),
    ],
    app: _app?.methods ?? const [],
  );

  /// Returns the entry and closes communication. Never triggers a recycle.
  Future<void> dispose() => _disposeFuture ??= _dispose();

  Future<void> _dispose() async {
    _disposed = true;
    _stop.complete();
    _connecting?.cancel();
    _activeSocket?.destroy();
    await _loop;
    await _states.close();
  }

  Future<void> _runLoop() async {
    while (!_disposed) {
      _connectAttempts++;
      _emit(SdkConnectionStatus(SdkConnectionState.connecting));
      Socket? socket;
      try {
        final task = await Socket.startConnect(
          InternetAddress(_socketPath, type: InternetAddressType.unix),
          0,
        );
        _connecting = task;
        if (_disposed) task.cancel();
        socket = await task.socket;
        _connecting = null;
        _activeSocket = socket;
        // IOSink completion errors are separate from read-stream errors.
        // Observe them even when a disconnect races a delayed callback.
        unawaited(socket.done.then<void>((_) {}, onError: (Object _) {}));
        if (_disposed) {
          socket.destroy();
        } else {
          await _serve(socket);
        }
      } catch (_) {
        // Connection failed, rejected, or dropped; retry below.
      } finally {
        _connecting = null;
        _activeSocket = null;
        _launcherSessionId = null;
        try {
          await socket?.close();
        } catch (_) {}
        socket?.destroy();
      }
      if (_disposed) break;
      _emit(SdkConnectionStatus(SdkConnectionState.disconnected));
      final retry = Completer<void>();
      final timer = Timer(_retryInterval, retry.complete);
      await Future.any([retry.future, _stop.future]);
      timer.cancel();
    }
  }

  Future<void> _serve(Socket socket) async {
    final sink = socket;
    writeMessage(sink, {
      'type': 'hello',
      'protocolVersion': kProtocolVersion,
      'projectId': projectId,
      'appSessionId': _appSessionId,
      'capabilities': capabilities.toJson(),
    });

    final welcome = Completer<Map<String, Object?>>();
    final done = Completer<void>();
    var accepted = false;
    DateTime lastPong = DateTime.now();
    Timer? pingTimer;
    Timer? watchdog;
    // Request rules are scoped to this connection: cached outcomes and
    // in-flight reuse never leak into a later session.
    final dedup = RequestDedup();

    late StreamSubscription sub;
    sub = decodeMessages(socket).listen(
      (message) {
        switch (message['type']) {
          case 'welcome':
            if (!welcome.isCompleted) {
              final session = message['launcherSessionId'];
              accepted =
                  message['accepted'] == true &&
                  session is String &&
                  session.trim().isNotEmpty;
              welcome.complete(message);
            }
          case 'request':
            if (accepted && !_disposed) {
              // Stream listen does not await async handlers. Observe failures
              // explicitly; callback completion must never escape the zone.
              unawaited(
                _handleRequest(socket, message, dedup).catchError((Object _) {
                  socket.destroy();
                }),
              );
            }
          case 'pong':
            if (accepted) lastPong = DateTime.now();
        }
      },
      onDone: () {
        if (!done.isCompleted) done.complete();
        if (!welcome.isCompleted) {
          welcome.completeError(StateError('connection closed before welcome'));
        }
      },
      onError: (_) {
        if (!done.isCompleted) done.complete();
        if (!welcome.isCompleted) {
          welcome.completeError(StateError('connection error before welcome'));
        }
      },
      cancelOnError: true,
    );

    try {
      final hello = await welcome.future.timeout(const Duration(seconds: 10));
      if (!accepted) {
        _emit(
          SdkConnectionStatus(
            SdkConnectionState.rejected,
            reason: hello['reason'] as String?,
          ),
        );
        // Do not hammer the launcher with retries on a definitive rejection;
        // still keep the normal retry cadence so a fixed binding can accept
        // a later attempt.
        await done.future;
        return;
      }
      _launcherSessionId = hello['launcherSessionId'] as String?;
      _emit(SdkConnectionStatus(SdkConnectionState.connected));

      pingTimer = Timer.periodic(_pingInterval, (_) {
        try {
          writeMessage(sink, {
            'type': 'ping',
            'sentAt': DateTime.now().toUtc().toIso8601String(),
          });
        } catch (_) {}
      });
      // Judged by real elapsed time, not tick counts.
      watchdog = Timer.periodic(const Duration(seconds: 1), (_) {
        if (DateTime.now().difference(lastPong) > _pongTimeout) {
          socket.destroy();
        }
      });

      await done.future;
    } finally {
      pingTimer?.cancel();
      watchdog?.cancel();
      await sub.cancel();
    }
  }

  Future<void> _handleRequest(
    Socket socket,
    Map<String, Object?> message,
    RequestDedup dedup,
  ) async {
    final id = message['id'];
    Map<String, Object?> respond(RequestOutcome outcome) => {
      'type': 'response',
      'id': id,
      if (outcome.error != null)
        'error': outcome.error!.toJson()
      else
        'result': outcome.value,
    };
    RequestOutcome outcome;
    final method = message['method'];
    final serviceId = message['serviceId'];
    final params = message['params'];
    if (id is! String ||
        id.isEmpty ||
        method is! String ||
        method.isEmpty ||
        (serviceId != null && serviceId is! String) ||
        (params != null && params is! Map<String, Object?>)) {
      outcome = RequestOutcome.error(
        ProtocolError(ProtocolError.invalid, 'invalid request structure'),
      );
    } else {
      // Identical request ids reuse in-flight processing or replay the
      // cached outcome; the business callback never runs twice for one id.
      outcome = await dedup.run(
        id,
        () => _execute(
          method,
          serviceId as String?,
          params as Map<String, Object?>?,
        ),
      );
    }
    // Application callbacks may outlive communication. They continue their
    // own work but must not reply into a disposed or replaced connection.
    if (!_disposed && identical(_activeSocket, socket)) {
      try {
        writeMessage(socket, respond(outcome));
      } catch (_) {
        socket.destroy();
      }
    }
  }

  Future<RequestOutcome> _execute(
    String method,
    String? serviceId,
    Map<String, Object?>? params,
  ) async {
    try {
      return RequestOutcome.result(await _dispatch(method, serviceId, params));
    } on ProtocolError catch (e) {
      return RequestOutcome.error(e);
    } catch (e) {
      return RequestOutcome.error(ProtocolError(ProtocolError.failed, '$e'));
    }
  }

  Future<Object?> _dispatch(
    String method,
    String? serviceId,
    Map<String, Object?>? params,
  ) async {
    if (method == kMethodOpenWindow ||
        method == kMethodSetEntryManaged ||
        method == kMethodVersionStatus) {
      return _dispatchApp(method, params);
    }
    if (serviceId == null) {
      throw ProtocolError(ProtocolError.invalid, 'missing serviceId');
    }
    final service = _services[serviceId];
    if (service == null) {
      throw ProtocolError(
        ProtocolError.unsupported,
        'unknown service: $serviceId',
      );
    }
    switch (method) {
      case kMethodStart:
        final cb =
            service.onStart ??
            (throw ProtocolError(
              ProtocolError.unsupported,
              'start not supported',
            ));
        await _runExclusive(serviceId, cb);
        return const {};
      case kMethodRecycle:
        final cb =
            service.onRecycle ??
            (throw ProtocolError(
              ProtocolError.unsupported,
              'recycle not supported',
            ));
        await _runExclusive(serviceId, cb);
        return const {};
      case kMethodStatus:
        final cb =
            service.onStatus ??
            (throw ProtocolError(
              ProtocolError.unsupported,
              'status not supported',
            ));
        return (await cb()).toJson();
      case kMethodLogs:
        final cb =
            service.onLogs ??
            (throw ProtocolError(
              ProtocolError.unsupported,
              'logs not supported',
            ));
        return (await cb(LogQuery.fromJson(params))).toJson();
      default:
        throw ProtocolError(
          ProtocolError.unsupported,
          'unknown method: $method',
        );
    }
  }

  /// Runs one start/recycle callback under the service's mutation gate.
  /// A second mutation for the same service fails fast with `busy` instead
  /// of queueing; other services are unaffected.
  Future<void> _runExclusive(
    String serviceId,
    Future<void> Function() callback,
  ) async {
    if (!_mutationGates.add(serviceId)) {
      throw ProtocolError(ProtocolError.busy, 'service busy: $serviceId');
    }
    try {
      await callback();
    } finally {
      _mutationGates.remove(serviceId);
    }
  }

  Future<Object?> _dispatchApp(
    String method,
    Map<String, Object?>? params,
  ) async {
    final app = _app;
    switch (method) {
      case kMethodOpenWindow:
        final cb =
            app?.onOpenWindow ??
            (throw ProtocolError(
              ProtocolError.unsupported,
              'openWindow not supported',
            ));
        await cb();
        return const {};
      case kMethodSetEntryManaged:
        final cb =
            app?.onSetEntryManaged ??
            (throw ProtocolError(
              ProtocolError.unsupported,
              'setEntryManaged not supported',
            ));
        final managed = params?['managed'] == true;
        return {'confirmed': await cb(managed)};
      case kMethodVersionStatus:
        final cb = app?.onVersionStatus;
        // No callback is not an error: answer 「不支持更新」 so the launcher
        // can show that instead of a failure.
        if (cb == null) return VersionStatus.unsupported().toJson();
        // A throwing callback is not a protocol error either: report the
        // failed query as a normal answer so the launcher can distinguish it
        // from a timeout or disconnect.
        try {
          return (await cb()).toJson();
        } catch (error) {
          return VersionStatus(
            state: VersionQueryState.failure,
            failureReason: 'onVersionStatus threw: $error',
          ).toJson();
        }
      default:
        throw ProtocolError(
          ProtocolError.unsupported,
          'unknown method: $method',
        );
    }
  }

  void _emit(SdkConnectionStatus status) {
    if (!_states.isClosed) _states.add(status);
  }

  static String _newSessionId() {
    final rand = Random.secure();
    final bytes = List<int>.generate(16, (_) => rand.nextInt(256));
    return '${DateTime.now().toUtc().millisecondsSinceEpoch.toRadixString(16)}-'
        '${base64UrlEncode(bytes)}';
  }
}
