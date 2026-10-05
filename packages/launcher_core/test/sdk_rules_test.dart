import 'dart:async';
import 'dart:io';

import 'package:launcher_core/launcher_core.dart';
import 'package:maclauncher_sdk/maclauncher_sdk.dart';
import 'package:test/test.dart';

import 'support.dart';

/// A hand-rolled launcher peer at the protocol level, used where the real
/// server cannot express the scenario (e.g. deliberately duplicated request
/// ids — the real server never generates those).
class RawPeer {
  RawPeer._(this._dir);

  final Directory _dir;
  ServerSocket? _server;

  String get socketPath => '${_dir.path}/sdk.sock';

  Future<void> listen() async {
    _server = await ServerSocket.bind(
      InternetAddress(socketPath, type: InternetAddressType.unix),
      0,
    );
  }

  Future<RawPeerConnection> accept() async {
    final socket = await _server!.first;
    return RawPeerConnection(socket);
  }

  Future<void> close() async {
    await _server?.close();
    final file = File(socketPath);
    if (file.existsSync()) file.deleteSync();
  }
}

class RawPeerConnection {
  RawPeerConnection(this.socket)
    : _iterator = StreamIterator(decodeMessages(socket));

  final Socket socket;
  final StreamIterator<Map<String, Object?>> _iterator;

  Future<Map<String, Object?>> next({
    Duration timeout = const Duration(seconds: 5),
  }) async {
    final has = await _iterator.moveNext().timeout(timeout);
    if (!has) throw StateError('peer connection closed');
    return _iterator.current;
  }

  Future<void> expectHello() async {
    final hello = await next();
    expect(hello['type'], 'hello');
    expect(hello['protocolVersion'], kProtocolVersion);
  }

  Future<void> welcome() async {
    writeMessage(socket, {
      'type': 'welcome',
      'accepted': true,
      'launcherSessionId': 'raw-${DateTime.now().microsecondsSinceEpoch}',
    });
    await socket.flush();
  }

  void request(String id, String method, {String? serviceId}) {
    writeMessage(socket, {
      'type': 'request',
      'id': id,
      'method': method,
      if (serviceId != null) 'serviceId': serviceId,
    });
  }

  Future<Map<String, Object?>> nextResponse() async {
    final message = await next();
    expect(message['type'], 'response');
    return message;
  }

  void destroy() => socket.destroy();
}

MacLauncherSdk connectSdk(
  RawPeer peer,
  Map<String, ServiceCallbacks> services, {
  AppCallbacks? app,
  Duration retryInterval = const Duration(milliseconds: 100),
  Duration pingInterval = const Duration(days: 1),
  Duration pongTimeout = const Duration(days: 1),
}) {
  return MacLauncherSdk.connect(
    projectId: 'proj',
    socketPath: peer.socketPath,
    services: services,
    app: app,
    retryInterval: retryInterval,
    pingInterval: pingInterval,
    pongTimeout: pongTimeout,
  );
}

void main() {
  late Directory temp;

  setUp(() {
    temp = Directory.systemTemp.createTempSync('sdk-rules-test');
  });

  tearDown(() {
    if (temp.existsSync()) temp.deleteSync(recursive: true);
  });

  group('request id dedup', () {
    test('duplicate id while in flight reuses the processing', () async {
      final peer = RawPeer._(temp);
      await peer.listen();
      addTearDown(peer.close);

      var startCalls = 0;
      final gate = Completer<void>();
      final sdk = connectSdk(peer, {
        'a': ServiceCallbacks(
          name: 'A',
          onStart: () async {
            startCalls++;
            await gate.future;
          },
        ),
      });
      addTearDown(sdk.dispose);

      final conn = await peer.accept();
      await conn.expectHello();
      await conn.welcome();

      conn.request('dup', kMethodStart, serviceId: 'a');
      await until(() => startCalls == 1);
      conn.request('dup', kMethodStart, serviceId: 'a');
      // Give the duplicate a chance to (wrongly) execute.
      await Future.delayed(const Duration(milliseconds: 200));
      expect(startCalls, 1);

      gate.complete();
      final first = await conn.nextResponse();
      final second = await conn.nextResponse();
      expect(first['id'], 'dup');
      expect(second['id'], 'dup');
      expect(first['error'], isNull);
      expect(second['error'], isNull);
      expect(startCalls, 1);
    });

    test('duplicate id after completion replays the cached outcome', () async {
      final peer = RawPeer._(temp);
      await peer.listen();
      addTearDown(peer.close);

      var startCalls = 0;
      final sdk = connectSdk(peer, {
        'a': ServiceCallbacks(
          name: 'A',
          onStart: () async {
            startCalls++;
          },
        ),
      });
      addTearDown(sdk.dispose);

      final conn = await peer.accept();
      await conn.expectHello();
      await conn.welcome();

      conn.request('c1', kMethodStart, serviceId: 'a');
      await conn.nextResponse();
      conn.request('c1', kMethodStart, serviceId: 'a');
      await conn.nextResponse();
      expect(startCalls, 1);
    });

    test('completed cache is bounded at 128 and in-flight entries are never evicted', () async {
      final peer = RawPeer._(temp);
      await peer.listen();
      addTearDown(peer.close);

      var statusCalls = 0;
      var startCalls = 0;
      final gate = Completer<void>();
      final sdk = connectSdk(peer, {
        'a': ServiceCallbacks(
          name: 'A',
          onStart: () async {
            startCalls++;
            await gate.future;
          },
          onStatus: () async {
            statusCalls++;
            return ServiceStatus(state: ServiceState.running);
          },
        ),
      });
      addTearDown(sdk.dispose);

      final conn = await peer.accept();
      await conn.expectHello();
      await conn.welcome();

      // One request stays in flight for the whole scenario.
      conn.request('hold', kMethodStart, serviceId: 'a');
      await until(() => startCalls == 1);

      // Fill the completed cache beyond its 128-entry bound.
      for (var i = 1; i <= 130; i++) {
        conn.request('s$i', kMethodStatus, serviceId: 'a');
        final response = await conn.nextResponse();
        expect(response['id'], 's$i');
      }
      expect(statusCalls, 130);

      // The in-flight request survived the churn: a duplicate still reuses.
      conn.request('hold', kMethodStart, serviceId: 'a');
      await Future.delayed(const Duration(milliseconds: 200));
      expect(startCalls, 1);

      // Oldest completed outcomes were evicted: s1 executes again.
      conn.request('s1', kMethodStatus, serviceId: 'a');
      await conn.nextResponse();
      expect(statusCalls, 131);

      // A recent completed outcome is replayed without execution.
      conn.request('s130', kMethodStatus, serviceId: 'a');
      await conn.nextResponse();
      expect(statusCalls, 131);

      gate.complete();
      await conn.nextResponse();
      await conn.nextResponse();
      expect(startCalls, 1);
    });

    test(
      'a new connection starts with an empty view of old request ids',
      () async {
        final peer = RawPeer._(temp);
        await peer.listen();
        addTearDown(peer.close);

        var statusCalls = 0;
        final firstGate = Completer<void>();
        final sdk = connectSdk(peer, {
          'a': ServiceCallbacks(
            name: 'A',
            onStatus: () async {
              statusCalls++;
              if (statusCalls == 1) await firstGate.future;
              return ServiceStatus(state: ServiceState.running);
            },
          ),
        });
        addTearDown(sdk.dispose);

        // First connection: request 'x' goes in flight and stays there.
        final conn1 = await peer.accept();
        await conn1.expectHello();
        await conn1.welcome();
        conn1.request('x', kMethodStatus, serviceId: 'a');
        await until(() => statusCalls == 1);
        conn1.destroy();
        await peer.close();

        // Reconnect: the new connection must not see the old cache.
        await peer.listen();
        final conn2 = await peer.accept();
        await conn2.expectHello();
        await conn2.welcome();
        conn2.request('x', kMethodStatus, serviceId: 'a');
        final response = await conn2.nextResponse();
        expect(response['id'], 'x');
        expect(response['error'], isNull);
        expect(statusCalls, 2);

        // The old callback finishes late: it must not write into conn2.
        firstGate.complete();
        await Future.delayed(const Duration(milliseconds: 300));
        expect(
          () => conn2.next(timeout: const Duration(milliseconds: 300)),
          throwsA(isA<TimeoutException>()),
        );
      },
    );
  });

  group('per-service busy rules (real server + real SDK)', () {
    late EndpointLayout layout;
    late LauncherServer server;

    setUp(() async {
      layout = EndpointLayout(directory: '${temp.path}/endpoint');
      server = await LauncherServer.start(
        layout: layout,
        bindings: InMemoryBindingLookup({'proj'}),
      );
    });

    tearDown(() => server.close());

    test('start/recycle of the same service never run concurrently', () async {
      var startCalls = 0;
      var recycleCalls = 0;
      final gate = Completer<void>();
      final sdk = MacLauncherSdk.connect(
        projectId: 'proj',
        socketPath: layout.socketPath,
        services: {
          'a': ServiceCallbacks(
            name: 'A',
            onStart: () async {
              startCalls++;
              await gate.future;
            },
            onRecycle: () async {
              recycleCalls++;
            },
            onStatus: () async {
              return ServiceStatus(state: ServiceState.running);
            },
          ),
          'b': ServiceCallbacks(name: 'B', onStart: () async {}),
        },
      );
      addTearDown(sdk.dispose);

      await until(() => server.registry.isActive('proj'));
      final session = server.sessionFor('proj')!;

      // Hold a start on service a.
      final pending = session.sendRequest(
        kMethodStart,
        serviceId: 'a',
        timeout: const Duration(seconds: 5),
      );
      await until(() => startCalls == 1);

      // A second mutation on the same service is rejected as busy.
      final dup = await session.sendRequest(
        kMethodStart,
        serviceId: 'a',
        timeout: const Duration(seconds: 5),
      );
      expect((dup['error'] as Map)['code'], ProtocolError.busy);

      final recycle = await session.sendRequest(
        kMethodRecycle,
        serviceId: 'a',
        timeout: const Duration(seconds: 5),
      );
      expect((recycle['error'] as Map)['code'], ProtocolError.busy);
      expect(recycleCalls, 0);

      // status is not serialized; other services are unaffected.
      final status = await session.sendRequest(
        kMethodStatus,
        serviceId: 'a',
        timeout: const Duration(seconds: 5),
      );
      expect(status['error'], isNull);
      final other = await session.sendRequest(
        kMethodStart,
        serviceId: 'b',
        timeout: const Duration(seconds: 5),
      );
      expect(other['error'], isNull);

      gate.complete();
      final first = await pending;
      expect(first['error'], isNull);
      expect(startCalls, 1);
    });
  });

  group('disconnect semantics', () {
    test(
      'dispose never invokes recycle, even with entry cooperation configured',
      () async {
        final layout = EndpointLayout(directory: '${temp.path}/endpoint');
        final server = await LauncherServer.start(
          layout: layout,
          bindings: InMemoryBindingLookup({'proj'}),
        );
        addTearDown(server.close);

        var recycleCalls = 0;
        final sdk = MacLauncherSdk.connect(
          projectId: 'proj',
          socketPath: layout.socketPath,
          services: {
            'a': ServiceCallbacks(
              name: 'A',
              onStart: () async {},
              onRecycle: () async {
                recycleCalls++;
              },
            ),
          },
          app: AppCallbacks(
            onOpenWindow: () async {},
            onSetEntryManaged: (managed) async => true,
          ),
        );
        await until(() => server.registry.isActive('proj'));

        await sdk.dispose();
        expect(recycleCalls, 0);
      },
    );

    test('socket loss emits disconnected promptly', () async {
      final layout = EndpointLayout(directory: '${temp.path}/endpoint');
      final server = await LauncherServer.start(
        layout: layout,
        bindings: InMemoryBindingLookup({'proj'}),
      );

      final sdk = MacLauncherSdk.connect(
        projectId: 'proj',
        socketPath: layout.socketPath,
        retryInterval: const Duration(milliseconds: 100),
        services: {'a': ServiceCallbacks(name: 'A')},
      );
      addTearDown(sdk.dispose);
      await until(() => server.registry.isActive('proj'));

      final disconnected = sdk.states.firstWhere(
        (s) => s.state == SdkConnectionState.disconnected,
      );
      await server.close();
      await disconnected.timeout(const Duration(seconds: 2));
    });

    test('pong timeout emits disconnected and reconnects', () async {
      final peer = RawPeer._(temp);
      await peer.listen();
      addTearDown(peer.close);

      final sdk = connectSdk(
        peer,
        {'a': ServiceCallbacks(name: 'A')},
        pingInterval: const Duration(milliseconds: 100),
        pongTimeout: const Duration(milliseconds: 300),
      );
      addTearDown(sdk.dispose);

      final conn = await peer.accept();
      await conn.expectHello();
      await conn.welcome();
      // Raw peer never pongs: the watchdog must drop the connection.
      final disconnected = sdk.states.firstWhere(
        (s) => s.state == SdkConnectionState.disconnected,
      );
      await disconnected.timeout(const Duration(seconds: 3));
    });
  });
}
