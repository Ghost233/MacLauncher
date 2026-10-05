import 'dart:async';
import 'dart:io';

import 'package:launcher_core/launcher_core.dart';
import 'package:maclauncher_sdk/maclauncher_sdk.dart';
import 'package:test/test.dart';

import 'support.dart';

void main() {
  group('VersionStatus codec', () {
    test('full answer round-trips verbatim', () {
      final status = VersionStatus(
        state: VersionQueryState.success,
        currentVersion: '1.2.0',
        hasUpdate: true,
        latestVersion: '1.3.0',
        downloadUrl: 'https://example.com/app-1.3.0.dmg',
        sha256: 'ab' * 32,
      );

      final decoded = VersionStatus.fromJson(status.toJson());

      expect(decoded.state, VersionQueryState.success);
      expect(decoded.currentVersion, '1.2.0');
      expect(decoded.hasUpdate, isTrue);
      expect(decoded.latestVersion, '1.3.0');
      expect(decoded.downloadUrl, 'https://example.com/app-1.3.0.dmg');
      expect(decoded.sha256, 'ab' * 32);
      expect(decoded.failureReason, isNull);
    });

    test('missing optional fields stay null', () {
      final decoded = VersionStatus.fromJson({'state': 'unsupported'});

      expect(decoded.state, VersionQueryState.unsupported);
      expect(decoded.currentVersion, isNull);
      expect(decoded.hasUpdate, isNull);
      expect(decoded.latestVersion, isNull);
      expect(decoded.downloadUrl, isNull);
      expect(decoded.failureReason, isNull);
      expect(decoded.sha256, isNull);
    });

    test(
      'missing or invalid state reads as failure with an explicit reason',
      () {
        final missing = VersionStatus.fromJson(const {});
        expect(missing.state, VersionQueryState.failure);
        expect(missing.failureReason, contains('missing or invalid'));

        final invalid = VersionStatus.fromJson(const {
          'state': 'everything-fine',
        });
        expect(invalid.state, VersionQueryState.failure);
        expect(invalid.failureReason, contains('everything-fine'));
      },
    );

    test('wrong-typed fields are dropped instead of throwing', () {
      final decoded = VersionStatus.fromJson(const {
        'state': 'success',
        'currentVersion': 42,
        'hasUpdate': 'yes',
        'latestVersion': ['1.3.0'],
        'downloadUrl': true,
        'sha256': 123,
      });

      expect(decoded.state, VersionQueryState.success);
      expect(decoded.currentVersion, isNull);
      expect(decoded.hasUpdate, isNull);
      expect(decoded.latestVersion, isNull);
      expect(decoded.downloadUrl, isNull);
      expect(decoded.sha256, isNull);
    });
  });

  group('versionStatus over real sockets', () {
    late Directory temp;
    late EndpointLayout layout;
    late BindingStore store;

    setUp(() async {
      temp = Directory.systemTemp.createTempSync('launcher-version-test');
      layout = EndpointLayout(directory: '${temp.path}/endpoint');
      store = await BindingStore.load('${temp.path}/bindings.json');
    });

    tearDown(() {
      if (temp.existsSync()) temp.deleteSync(recursive: true);
    });

    Future<void> bindProject() async {
      final dir = Directory('${temp.path}/proj')..createSync(recursive: true);
      File('${dir.path}/$kManifestFileName').writeAsStringSync('''
{
  "schemaVersion": 1,
  "project": {"id": "proj-a", "name": "项目甲"},
  "services": [{"id": "svc", "name": "svc"}]
}
''');
      await store.associate('${dir.path}/$kManifestFileName');
    }

    Future<LauncherServer> runningPair({AppCallbacks? app}) async {
      final server = await LauncherServer.start(
        layout: layout,
        bindings: store,
      );
      addTearDown(server.close);
      final sdk = MacLauncherSdk.connect(
        projectId: 'proj-a',
        socketPath: layout.socketPath,
        services: {
          'svc': ServiceCallbacks(
            name: 'svc',
            onStatus: () async => ServiceStatus(state: ServiceState.running),
          ),
        },
        app: app,
      );
      addTearDown(sdk.dispose);
      await until(() => server.registry.isActive('proj-a'));
      return server;
    }

    ServiceOperations ops(
      LauncherServer server, {
      Duration timeout = const Duration(seconds: 2),
    }) => ServiceOperations(
      server: server,
      scope: BindingServiceScope(store),
      timeout: timeout,
    );

    test('capability is declared when the callback is registered', () async {
      await bindProject();
      final server = await runningPair(
        app: AppCallbacks(
          onVersionStatus: () async => VersionStatus.unsupported(),
        ),
      );
      expect(
        server.registry
            .byProject('proj-a')!
            .capabilities
            .supportsApp(kMethodVersionStatus),
        isTrue,
      );
    });

    test('capability is absent without the callback', () async {
      await bindProject();
      final server = await runningPair();
      expect(
        server.registry
            .byProject('proj-a')!
            .capabilities
            .supportsApp(kMethodVersionStatus),
        isFalse,
      );
    });

    test('successful query returns the application answer verbatim', () async {
      await bindProject();
      final server = await runningPair(
        app: AppCallbacks(
          onVersionStatus: () async => VersionStatus(
            state: VersionQueryState.success,
            currentVersion: '1.2.0',
            hasUpdate: true,
            latestVersion: '1.3.0',
            downloadUrl: 'https://example.com/app-1.3.0.dmg',
            sha256: 'cd' * 32,
          ),
        ),
      );

      final result = await ops(server).versionStatus('proj-a');

      final status = (result as VersionStatusSnapshot).status;
      expect(status.state, VersionQueryState.success);
      expect(status.currentVersion, '1.2.0');
      expect(status.hasUpdate, isTrue);
      expect(status.latestVersion, '1.3.0');
      expect(status.downloadUrl, 'https://example.com/app-1.3.0.dmg');
      expect(status.sha256, 'cd' * 32);
    });

    test(
      'failed update query arrives as a failure answer, not an error',
      () async {
        await bindProject();
        final server = await runningPair(
          app: AppCallbacks(
            onVersionStatus: () async => VersionStatus(
              state: VersionQueryState.failure,
              currentVersion: '1.2.0',
              failureReason: '更新源不可达',
            ),
          ),
        );

        final result = await ops(server).versionStatus('proj-a');

        final status = (result as VersionStatusSnapshot).status;
        expect(status.state, VersionQueryState.failure);
        expect(status.failureReason, '更新源不可达');
      },
    );

    test(
      'application-reported unsupported is an answer, not an error',
      () async {
        await bindProject();
        final server = await runningPair(
          app: AppCallbacks(
            onVersionStatus: () async => VersionStatus.unsupported(),
          ),
        );

        final result = await ops(server).versionStatus('proj-a');

        final status = (result as VersionStatusSnapshot).status;
        expect(status.state, VersionQueryState.unsupported);
      },
    );

    test(
      'old application without the capability: unsupported, nothing sent',
      () async {
        await bindProject();
        final server = await LauncherServer.start(
          layout: layout,
          bindings: store,
        );
        addTearDown(server.close);

        // A legacy client at the protocol level: no versionStatus capability.
        // A single StreamIterator: a socket stream allows one subscription.
        final socket = await connectRaw(layout.socketPath);
        addTearDown(socket.destroy);
        final iterator = StreamIterator(decodeMessages(socket));
        writeMessage(socket, helloMessage(projectId: 'proj-a'));
        await socket.flush();
        expect(await iterator.moveNext(), isTrue);
        expect(iterator.current['accepted'], isTrue);

        final result = await ops(server).versionStatus('proj-a');

        expect(result, isA<VersionStatusUnsupported>());
        // The launcher must not send a request the client never declared.
        await expectLater(
          iterator.moveNext().timeout(const Duration(milliseconds: 300)),
          throwsA(isA<TimeoutException>()),
        );
      },
    );

    test(
      'declared capability but unsupported error still maps to unsupported',
      () async {
        await bindProject();
        final server = await LauncherServer.start(
          layout: layout,
          bindings: store,
        );
        addTearDown(server.close);

        final socket = await connectRaw(layout.socketPath);
        addTearDown(socket.destroy);
        final iterator = StreamIterator(decodeMessages(socket));
        final hello = helloMessage(projectId: 'proj-a');
        (hello['capabilities'] as Map)['app'] = [kMethodVersionStatus];
        writeMessage(socket, hello);
        await socket.flush();
        expect(await iterator.moveNext(), isTrue);
        expect(iterator.current['accepted'], isTrue);

        unawaited(() async {
          expect(await iterator.moveNext(), isTrue);
          final request = iterator.current;
          expect(request['method'], kMethodVersionStatus);
          writeMessage(socket, {
            'type': 'response',
            'id': request['id'],
            'error': {'code': ProtocolError.unsupported, 'message': 'old sdk'},
          });
        }());

        final result = await ops(server).versionStatus('proj-a');

        expect(result, isA<VersionStatusUnsupported>());
      },
    );

    test('unbound project and disconnected project yield unknown', () async {
      await bindProject();
      final server = await LauncherServer.start(
        layout: layout,
        bindings: store,
      );
      addTearDown(server.close);

      expect(
        await ops(server).versionStatus('proj-a'),
        isA<VersionStatusUnknown>(),
      );
      expect(
        await ops(server).versionStatus('stranger'),
        isA<VersionStatusUnknown>(),
      );
    });

    test('timeout yields unknown; nothing is resent', () async {
      await bindProject();
      final gate = Completer<void>();
      var calls = 0;
      final server = await runningPair(
        app: AppCallbacks(
          onVersionStatus: () async {
            calls++;
            await gate.future;
            return VersionStatus.unsupported();
          },
        ),
      );

      final result = await ops(
        server,
        timeout: const Duration(milliseconds: 200),
      ).versionStatus('proj-a');

      expect(result, isA<VersionStatusUnknown>());
      expect(calls, 1);
      gate.complete();
    });

    test('SDK auto-answers 「不支持更新」 when no callback is registered', () async {
      // A hand-rolled launcher peer forces the request through even though
      // the SDK declared no such capability.
      final dir = Directory.systemTemp.createTempSync('sdk-version-auto');
      addTearDown(() {
        if (dir.existsSync()) dir.deleteSync(recursive: true);
      });
      final socketPath = '${dir.path}/sdk.sock';
      final listener = await ServerSocket.bind(
        InternetAddress(socketPath, type: InternetAddressType.unix),
        0,
      );
      addTearDown(listener.close);

      final sdk = MacLauncherSdk.connect(
        projectId: 'proj-a',
        socketPath: socketPath,
        services: const {},
      );
      addTearDown(sdk.dispose);

      final peer = await listener.first;
      final incoming = decodeMessages(peer);
      final iterator = StreamIterator(incoming);
      expect(await iterator.moveNext(), isTrue);
      expect(iterator.current['type'], 'hello');
      expect(
        (iterator.current['capabilities'] as Map)['app'],
        isNot(contains(kMethodVersionStatus)),
      );
      writeMessage(peer, {
        'type': 'welcome',
        'accepted': true,
        'launcherSessionId': 'raw-1',
      });
      await until(() => sdk.launcherSessionId != null);

      writeMessage(peer, {
        'type': 'request',
        'id': 'raw-1-r1',
        'method': kMethodVersionStatus,
      });
      expect(await iterator.moveNext(), isTrue);
      final response = iterator.current;
      expect(response['id'], 'raw-1-r1');
      expect(response['error'], isNull);
      expect(
        (response['result'] as Map)['state'],
        VersionQueryState.unsupported.toJson(),
      );
      await iterator.cancel();
    });
  });
}
