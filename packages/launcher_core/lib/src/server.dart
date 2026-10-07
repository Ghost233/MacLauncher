import 'dart:async';
import 'dart:io';

import 'package:maclauncher_sdk/maclauncher_sdk.dart';

import 'binding_lookup.dart';
import 'endpoint.dart';
import 'endpoint_lock.dart';
import 'pending_registry.dart';
import 'registry.dart';
import 'runtime_binding_sync.dart';

/// Rejection reasons sent in the welcome message.
class RejectReason {
  static const String protocolVersion = 'protocol-version';
  static const String unknownProject = 'unknown-project';
  static const String pendingApproval = 'pending-approval';
  static const String conflict = 'conflict';
  static const String invalidHello = 'invalid-hello';
}

/// The launcher-side Unix domain socket listener.
///
/// One per user: it holds the endpoint lock for its lifetime, owns stale
/// endpoint cleanup, and never lets a second instance override an active
/// endpoint.
class LauncherServer {
  LauncherServer._({
    required this.layout,
    required this.registry,
    required this._lock,
    required this._socket,
    required this._runId,
  }) {
    _acceptSub = _socket.listen(_onConnection);
  }

  static Future<LauncherServer> start({
    required EndpointLayout layout,
    required BindingLookup bindings,
    ConnectionRegistry? registry,
    DiscoveryConfig? discovery,
    RuntimeBindingSync? runtimeSync,
  }) async {
    layout.ensureDirectory();
    final lock = await EndpointLock.acquire(layout.lockPath);

    ServerSocket? socket;
    try {
      // Stale endpoint cleanup is only performed by the lock holder.
      final socketFile = File(layout.socketPath);
      if (socketFile.existsSync()) socketFile.deleteSync();
      socket = await ServerSocket.bind(
        InternetAddress(layout.socketPath, type: InternetAddressType.unix),
        0,
      );
      layout.secureSocket();
      return LauncherServer._(
          layout: layout,
          registry: registry ?? ConnectionRegistry(),
          lock: lock,
          socket: socket,
          runId: DateTime.now().toUtc().microsecondsSinceEpoch.toRadixString(
            16,
          ),
        )
        .._bindings = bindings
        .._discovery = discovery
        .._runtimeSync = runtimeSync;
    } catch (_) {
      try {
        if (socket != null) {
          await socket.close();
          final socketFile = File(layout.socketPath);
          if (socketFile.existsSync()) socketFile.deleteSync();
        }
      } finally {
        await lock.release();
      }
      rethrow;
    }
  }

  final EndpointLayout layout;
  final ConnectionRegistry registry;
  final EndpointLock _lock;
  final ServerSocket _socket;
  final String _runId;
  late final BindingLookup _bindings;
  DiscoveryConfig? _discovery;
  RuntimeBindingSync? _runtimeSync;
  late final StreamSubscription<Socket> _acceptSub;
  final _sessions = <ServerSession>{};
  int _sessionCounter = 0;

  bool _closed = false;

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    await _acceptSub.cancel();
    for (final session in _sessions.toList()) {
      await session.close();
    }
    await _socket.close();
    try {
      final socketFile = File(layout.socketPath);
      if (socketFile.existsSync()) socketFile.deleteSync();
    } catch (_) {}
    await _lock.release();
  }

  void _onConnection(Socket socket) {
    unawaited(socket.done.then<void>((_) {}, onError: (Object _) {}));
    final session = ServerSession._(
      socket: socket,
      server: this,
      launcherSessionId: '$_runId-${++_sessionCounter}',
    );
    _sessions.add(session);
    session.done.whenComplete(() => _sessions.remove(session));
    session.serve();
  }

  /// The live session for [projectId], when connected.
  ServerSession? sessionFor(String projectId) {
    for (final session in _sessions) {
      if (session.project?.projectId == projectId) return session;
    }
    return null;
  }

  void _reject(IOSink sink, String reason) {
    writeMessage(sink, {
      'type': 'welcome',
      'accepted': false,
      'reason': reason,
    });
  }

  /// Handles a hello from an unbound project.
  ///
  /// Without a [DiscoveryConfig] the pre-discovery behavior stands:
  /// rejected as unknown-project. With one, ignored projects are rejected
  /// the same way (silently), while everything else is recorded in the
  /// pending registry and rejected as pending-approval — the SDK's
  /// reconnect loop then doubles as the approval poll.
  Future<String> _handleUnknownProject(
    Map<String, Object?> hello,
    String projectId,
  ) async {
    final discovery = _discovery;
    if (discovery == null || discovery.isIgnored(projectId)) {
      return RejectReason.unknownProject;
    }
    final existing = discovery.pending.byProject(projectId);
    String? sourcePath = existing?.sourceProcessPath;
    if (sourcePath == null && discovery.peerProbe != null) {
      sourcePath = await discovery.peerProbe!();
    }
    final capabilities = CapabilitySet.fromJson(
      (hello['capabilities'] as Map).cast<String, Object?>(),
    );
    final entryJson = hello['entry'];
    discovery.pending.record(
      projectId: projectId,
      projectName: hello['projectName'] as String?,
      services: capabilities.services,
      entry: entryJson is Map
          ? SdkEntry.fromJson(entryJson.cast<String, Object?>())
          : null,
      sourceProcessPath: sourcePath,
    );
    return RejectReason.pendingApproval;
  }
}

/// One accepted (or in-handshake) connection.
class ServerSession {
  ServerSession._({
    required this._socket,
    required this._server,
    required this.launcherSessionId,
  });

  final Socket _socket;
  final LauncherServer _server;
  final String launcherSessionId;
  final Completer<void> _done = Completer<void>();
  final _pending = <String, Completer<Map<String, Object?>>>{};
  var _requestCounter = 0;

  ConnectedProject? project;

  Future<void> get done => _done.future;

  Future<void> serve() async {
    var registered = false;
    // A single subscription for the whole session: cancelling a socket
    // stream subscription would close the underlying socket.
    final iterator = StreamIterator(decodeMessages(_socket));
    try {
      final hasHello = await iterator.moveNext().timeout(
        const Duration(seconds: 10),
      );
      if (!hasHello) return;
      final first = iterator.current;
      if (first['type'] != 'hello') return;

      final version = first['protocolVersion'];
      if (version != kProtocolVersion) {
        _server._reject(_socket, RejectReason.protocolVersion);
        return;
      }
      if (!_validHello(first)) {
        _server._reject(_socket, RejectReason.invalidHello);
        return;
      }
      final projectId = first['projectId'] as String;
      if (!_server._bindings.isKnownProject(projectId)) {
        final handled = await _server._handleUnknownProject(first, projectId);
        _server._reject(_socket, handled);
        return;
      }
      if (_server.registry.isActive(projectId)) {
        // Second active connection for the same identity: conflict, never
        // preempt the incumbent.
        _server._reject(_socket, RejectReason.conflict);
        return;
      }

      project = ConnectedProject(
        projectId: projectId,
        appSessionId: first['appSessionId'] as String? ?? '',
        launcherSessionId: launcherSessionId,
        capabilities: CapabilitySet.fromJson(
          (first['capabilities'] as Map?)?.cast<String, Object?>() ?? {},
        ),
      );
      _server.registry.register(project!);
      registered = true;

      writeMessage(_socket, {
        'type': 'welcome',
        'accepted': true,
        'launcherSessionId': launcherSessionId,
      });

      // Runtime bindings treat each hello as authoritative: refresh the
      // service set and self-heal the learned entry. A sync failure must
      // never kill an accepted session.
      final runtimeSync = _server._runtimeSync;
      if (runtimeSync != null) {
        try {
          final entryJson = first['entry'];
          await runtimeSync.afterHandshake(
            projectId,
            project!.capabilities,
            entryJson is Map
                ? SdkEntry.fromJson(entryJson.cast<String, Object?>())
                : null,
            projectName: first['projectName'] as String?,
          );
        } catch (e) {
          stderr.writeln('runtime binding sync failed for $projectId: $e');
        }
      }

      while (await iterator.moveNext()) {
        final message = iterator.current;
        switch (message['type']) {
          case 'ping':
            writeMessage(_socket, {
              'type': 'pong',
              'sentAt': message['sentAt'],
            });
          case 'response':
            final id = message['id'] as String?;
            final completer = id == null ? null : _pending.remove(id);
            completer?.complete(message);
        }
      }
    } catch (_) {
      // Handshake timeout, malformed frames or connection errors all end the
      // session without issuing any operations.
    } finally {
      try {
        if (registered && project != null) {
          _server.registry.unregister(project!.projectId, launcherSessionId);
        }
      } finally {
        for (final completer in _pending.values) {
          if (!completer.isCompleted) {
            completer.completeError(StateError('connection lost'));
          }
        }
        _pending.clear();
        try {
          await _socket.close();
        } catch (_) {}
        _socket.destroy();
        await iterator.cancel();
        if (!_done.isCompleted) _done.complete();
      }
    }
  }

  static bool _validHello(Map<String, Object?> hello) {
    bool nonempty(Object? value) => value is String && value.trim().isNotEmpty;
    if (!nonempty(hello['projectId']) || !nonempty(hello['appSessionId'])) {
      return false;
    }
    final capabilities = hello['capabilities'];
    if (capabilities is! Map ||
        capabilities['services'] is! List ||
        capabilities['app'] is! List) {
      return false;
    }
    bool validMethods(Object? value, Set<String> allowed) =>
        value is List &&
        value.every((m) => m is String && allowed.contains(m)) &&
        value.toSet().length == value.length;
    if (!validMethods(capabilities['app'], {
      kMethodOpenWindow,
      kMethodSetEntryManaged,
      kMethodVersionStatus,
    })) {
      return false;
    }
    final ids = <String>{};
    for (final service in capabilities['services'] as List) {
      if (service is! Map ||
          !nonempty(service['id']) ||
          !nonempty(service['name']) ||
          !ids.add(service['id'] as String) ||
          !validMethods(service['methods'], {
            kMethodStart,
            kMethodRecycle,
            kMethodStatus,
            kMethodLogs,
          })) {
        return false;
      }
    }
    return true;
  }

  /// Sends one request and waits for its response, correlated by request id.
  ///
  /// On [timeout] the pending entry is dropped and a [TimeoutException] is
  /// thrown: the application's callback is never cancelled, and nothing is
  /// resent automatically.
  Future<Map<String, Object?>> sendRequest(
    String method, {
    String? serviceId,
    Map<String, Object?>? params,
    required Duration timeout,
  }) async {
    final id = '$launcherSessionId-r${++_requestCounter}';
    final completer = Completer<Map<String, Object?>>();
    _pending[id] = completer;
    writeMessage(_socket, {
      'type': 'request',
      'id': id,
      'method': method,
      'serviceId': ?serviceId,
      'params': ?params,
    });
    try {
      return await completer.future.timeout(timeout);
    } on TimeoutException {
      _pending.remove(id);
      rethrow;
    }
  }

  Future<void> close() async {
    try {
      await _socket.close();
    } catch (_) {}
    _socket.destroy();
    await done;
  }
}
