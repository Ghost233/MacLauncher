import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:launcher_core/launcher_core.dart';
import 'package:maclauncher_sdk/maclauncher_sdk.dart';
import 'package:test/test.dart';

import 'support.dart';

void main() {
  final peerPath = File.fromUri(
    Isolate.resolvePackageUriSync(
      Uri.parse('package:launcher_core/launcher_core.dart'),
    )!.resolve('../test/fixtures/endpoint_peer.dart'),
  ).path;
  late Directory temp;
  late EndpointLayout layout;
  setUp(() {
    temp = Directory.systemTemp.createTempSync('launcher-lifecycle');
    layout = EndpointLayout(directory: '${temp.path}/entry');
  });
  tearDown(() => temp.deleteSync(recursive: true));

  test('disposing during retry ends communication promptly', () async {
    final sdk = MacLauncherSdk.connect(
      projectId: 'project',
      socketPath: layout.socketPath,
      services: {},
      retryInterval: const Duration(seconds: 30),
    );
    await sdk.states.firstWhere(
      (s) => s.state == SdkConnectionState.disconnected,
    );
    await sdk.dispose().timeout(const Duration(milliseconds: 500));
  });

  test(
    'disposing while welcome is pending closes the connection promptly',
    () async {
      layout.ensureDirectory();
      final listener = await ServerSocket.bind(
        InternetAddress(layout.socketPath, type: InternetAddressType.unix),
        0,
      );
      final accepted = listener.first;
      final sdk = MacLauncherSdk.connect(
        projectId: 'project',
        socketPath: layout.socketPath,
        services: {},
      );
      final socket = await accepted;
      try {
        await sdk.dispose().timeout(const Duration(milliseconds: 500));
      } finally {
        socket.destroy();
        await listener.close();
      }
    },
  );

  test(
    'a real second process cannot replace the active SDK endpoint',
    () async {
      final server = await LauncherServer.start(
        layout: layout,
        bindings: InMemoryBindingLookup({'project'}),
      );
      addTearDown(server.close);
      final challenger = await Process.run(Platform.resolvedExecutable, [
        'run',
        peerPath,
        layout.directory,
        // dart run 现场编译 peer，冷/慢机器上远超 5s；留足编译余量。
      ]).timeout(const Duration(seconds: 15));
      expect(challenger.exitCode, 73);
      final sdk = MacLauncherSdk.connect(
        projectId: 'project',
        socketPath: layout.socketPath,
        services: {},
      );
      addTearDown(sdk.dispose);
      await until(() => server.registry.isActive('project'));
    },
  );

  test('an independent owner excludes this process and crash permits stale cleanup', () async {
    final owner = await Process.start(Platform.resolvedExecutable, [
      'run',
      peerPath,
      layout.directory,
    ]);
    try {
      final ready = await owner.stdout
          .cast<List<int>>()
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .first
          // 同上：peer 进程的 dart run 编译时间计入此超时。
          .timeout(const Duration(seconds: 15));
      expect(ready, 'owned');
      await expectLater(
        LauncherServer.start(
          layout: layout,
          bindings: InMemoryBindingLookup({'project'}),
        ),
        throwsStateError,
      );
      owner.kill(ProcessSignal.sigkill);
      await owner.exitCode;
      final server = await LauncherServer.start(
        layout: layout,
        bindings: InMemoryBindingLookup({'project'}),
      );
      addTearDown(server.close);
      final sdk = MacLauncherSdk.connect(
        projectId: 'project',
        socketPath: layout.socketPath,
        services: {},
      );
      addTearDown(sdk.dispose);
      await until(() => server.registry.isActive('project'));
    } finally {
      owner.kill(ProcessSignal.sigkill);
      await owner.exitCode;
    }
  });

  test(
    'failed endpoint bind releases ownership for a subsequent launch',
    () async {
      layout.ensureDirectory();
      // A directory at the socket path makes binding impossible.
      final obstruction = Directory(layout.socketPath)..createSync();
      await expectLater(
        LauncherServer.start(
          layout: layout,
          bindings: InMemoryBindingLookup({'project'}),
        ),
        throwsA(anything),
      );
      obstruction.deleteSync();
      final server = await LauncherServer.start(
        layout: layout,
        bindings: InMemoryBindingLookup({'project'}),
      );
      await server.close();
    },
  );

  test(
    'requests before handshake never execute application callbacks',
    () async {
      layout.ensureDirectory();
      final listener = await ServerSocket.bind(
        InternetAddress(layout.socketPath, type: InternetAddressType.unix),
        0,
      );
      var starts = 0;
      final accepted = listener.first;
      final sdk = MacLauncherSdk.connect(
        projectId: 'project',
        socketPath: layout.socketPath,
        services: {
          'svc': ServiceCallbacks(
            name: 'Service',
            onStart: () async {
              starts++;
            },
          ),
        },
      );
      final socket = await accepted;
      writeMessage(socket, {
        'type': 'request',
        'id': 'early',
        'method': 'start',
        'serviceId': 'svc',
      });
      await socket.flush();
      await Future<void>.delayed(const Duration(milliseconds: 100));
      try {
        expect(starts, 0);
      } finally {
        await sdk.dispose();
        socket.destroy();
        await listener.close();
      }
    },
  );

  test(
    'malformed requests return invalid without leaking asynchronous errors',
    () async {
      layout.ensureDirectory();
      final listener = await ServerSocket.bind(
        InternetAddress(layout.socketPath, type: InternetAddressType.unix),
        0,
      );
      final accepted = listener.first;
      final sdk = MacLauncherSdk.connect(
        projectId: 'project',
        socketPath: layout.socketPath,
        services: {},
      );
      final socket = await accepted;
      final messages = StreamIterator(decodeMessages(socket));
      try {
        expect(await messages.moveNext(), true); // hello
        writeMessage(socket, {
          'type': 'welcome',
          'accepted': true,
          'launcherSessionId': 'launcher',
        });
        writeMessage(socket, {
          'type': 'request',
          'id': 'bad',
          'method': 42,
          'params': [],
        });
        expect(
          await messages.moveNext().timeout(const Duration(seconds: 1)),
          true,
        );
        expect((messages.current['error'] as Map)['code'], 'invalid');
      } finally {
        await sdk.dispose();
        await messages.cancel();
        socket.destroy();
        await listener.close();
      }
    },
  );

  test(
    'failed lock-file open does not poison future endpoint acquisition',
    () async {
      layout.ensureDirectory();
      final obstruction = Directory(layout.lockPath)..createSync();
      await expectLater(
        LauncherServer.start(
          layout: layout,
          bindings: InMemoryBindingLookup({'project'}),
        ),
        throwsA(anything),
      );
      obstruction.deleteSync();
      final server = await LauncherServer.start(
        layout: layout,
        bindings: InMemoryBindingLookup({'project'}),
      );
      await server.close();
    },
  );

  test('dispose does not wait for business callback or recycle it', () async {
    layout.ensureDirectory();
    final listener = await ServerSocket.bind(
      InternetAddress(layout.socketPath, type: InternetAddressType.unix),
      0,
    );
    final entered = Completer<void>();
    final business = Completer<void>();
    var recycled = false;
    final accepted = listener.first;
    final sdk = MacLauncherSdk.connect(
      projectId: 'project',
      socketPath: layout.socketPath,
      services: {
        'svc': ServiceCallbacks(
          name: 'Service',
          onStart: () {
            entered.complete();
            return business.future;
          },
          onRecycle: () async {
            recycled = true;
          },
        ),
      },
    );
    final socket = await accepted;
    final messages = StreamIterator(decodeMessages(socket));
    try {
      expect(await messages.moveNext(), true);
      writeMessage(socket, {
        'type': 'welcome',
        'accepted': true,
        'launcherSessionId': 'launcher',
      });
      writeMessage(socket, {
        'type': 'request',
        'id': 'start',
        'method': 'start',
        'serviceId': 'svc',
      });
      await entered.future.timeout(const Duration(seconds: 1));
      await sdk.dispose().timeout(const Duration(milliseconds: 500));
      expect(recycled, false);
      // The app callback may still complete/fail after communication ended.
      // No obsolete response or unhandled asynchronous error may escape.
      business.completeError(StateError('late application failure'));
      await Future<void>.delayed(const Duration(milliseconds: 50));
    } finally {
      await sdk.dispose();
      await messages.cancel();
      socket.destroy();
      await listener.close();
    }
  });

  test(
    'malformed capability declarations never enter the project registry',
    () async {
      final server = await LauncherServer.start(
        layout: layout,
        bindings: InMemoryBindingLookup({'project'}),
      );
      addTearDown(server.close);
      final malformed = <Object?>[
        null,
        [],
        {'services': {}, 'app': []},
        {
          'services': [],
          'app': ['unsupported'],
        },
        {
          'services': [
            {'id': '', 'name': 'Service', 'methods': []},
          ],
          'app': [],
        },
        {
          'services': [
            {
              'id': 's',
              'name': 'Service',
              'methods': [42],
            },
          ],
          'app': [],
        },
        {
          'services': [
            {
              'id': 's',
              'name': 'Service',
              'methods': ['status', 'status'],
            },
          ],
          'app': [],
        },
        {
          'services': [
            {'id': 's', 'name': 'Service', 'methods': []},
            {'id': 's', 'name': 'Duplicate', 'methods': []},
          ],
          'app': [],
        },
      ];
      for (final capabilities in malformed) {
        final socket = await connectRaw(layout.socketPath);
        try {
          final response = await rawHello(
            socket,
            helloMessage(projectId: 'project')..['capabilities'] = capabilities,
          );
          expect(response['accepted'], false, reason: '$capabilities');
          expect(response['reason'], 'invalid-hello');
          expect(server.registry.connected, isEmpty);
        } finally {
          socket.destroy();
        }
      }
    },
  );

  test(
    'retiring an old SDK connection cannot remove its replacement session',
    () async {
      final server = await LauncherServer.start(
        layout: layout,
        bindings: InMemoryBindingLookup({'project'}),
      );
      addTearDown(server.close);
      final first = MacLauncherSdk.connect(
        projectId: 'project',
        socketPath: layout.socketPath,
        services: {},
      );
      await until(() => server.registry.isActive('project'));
      final oldSession = server.registry
          .byProject('project')!
          .launcherSessionId;
      await first.dispose();
      await until(() => !server.registry.isActive('project'));
      final replacement = MacLauncherSdk.connect(
        projectId: 'project',
        socketPath: layout.socketPath,
        services: {},
      );
      addTearDown(replacement.dispose);
      await until(() => server.registry.isActive('project'));
      final newSession = server.registry
          .byProject('project')!
          .launcherSessionId;
      expect(newSession, isNot(oldSession));
      await first.dispose();
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(
        server.registry.byProject('project')!.launcherSessionId,
        newSession,
      );
    },
  );

  test(
    'alternate path spelling cannot steal the active listening endpoint',
    () async {
      final server = await LauncherServer.start(
        layout: layout,
        bindings: InMemoryBindingLookup({'project'}),
      );
      addTearDown(server.close);
      await expectLater(
        LauncherServer.start(
          layout: EndpointLayout(directory: '${layout.directory}/../entry'),
          bindings: InMemoryBindingLookup({'project'}),
        ),
        throwsStateError,
      );
      final sdk = MacLauncherSdk.connect(
        projectId: 'project',
        socketPath: layout.socketPath,
        services: {},
      );
      addTearDown(sdk.dispose);
      await until(() => server.registry.isActive('project'));
    },
  );

  test(
    'malformed hello is explicitly rejected without registering capabilities',
    () async {
      final server = await LauncherServer.start(
        layout: layout,
        bindings: InMemoryBindingLookup({'project'}),
      );
      addTearDown(server.close);
      final socket = await connectRaw(layout.socketPath);
      addTearDown(socket.destroy);
      final hello = helloMessage(projectId: 'project')..['appSessionId'] = '';
      final response = await rawHello(socket, hello);
      expect(response['accepted'], false);
      expect(response['reason'], 'invalid-hello');
      expect(server.registry.connected, isEmpty);
    },
  );
}
