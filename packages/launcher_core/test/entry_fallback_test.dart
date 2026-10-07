import 'dart:async';
import 'dart:io';

import 'package:launcher_core/launcher_core.dart';
import 'package:maclauncher_sdk/maclauncher_sdk.dart';
import 'package:test/test.dart';

import 'support.dart';

void main() {
  late Directory temp;
  late LauncherServer server;

  setUp(() async {
    temp = Directory.systemTemp.createTempSync('entry-fallback-');
    server = await LauncherServer.start(
      layout: EndpointLayout(directory: '${temp.path}/endpoint'),
      bindings: InMemoryBindingLookup({'app'}),
    );
  });

  tearDown(() async {
    await server.close();
    temp.deleteSync(recursive: true);
  });

  Future<MacLauncherSdk> connect(Future<bool> Function(bool) callback) async {
    final sdk = MacLauncherSdk.connect(
      projectId: 'app',
      socketPath: server.layout.socketPath,
      services: {},
      app: AppCallbacks(onSetEntryManaged: callback),
    );
    addTearDown(sdk.dispose);
    await until(() => server.registry.isActive('app'));
    return sdk;
  }

  test(
    'SDK dispose restores entry without waiting for business shutdown',
    () async {
      final calls = <bool>[];
      final sdk = await connect((managed) async {
        calls.add(managed);
        return true;
      });
      await server
          .sessionFor('app')!
          .sendRequest(
            kMethodSetEntryManaged,
            params: {'managed': true},
            timeout: const Duration(seconds: 1),
          );
      await sdk.dispose();
      await until(() => calls.length == 2);
      expect(calls, [true, false]);
    },
  );

  test(
    'connection loss restores entry after a delayed hide callback',
    () async {
      final gate = Completer<void>();
      var hidden = false;
      final calls = <bool>[];
      await connect((managed) async {
        calls.add(managed);
        if (managed) await gate.future;
        hidden = managed;
        return true;
      });
      final request = server
          .sessionFor('app')!
          .sendRequest(
            kMethodSetEntryManaged,
            params: {'managed': true},
            timeout: const Duration(seconds: 1),
          )
          .catchError((Object _) => <String, Object?>{});
      await until(() => calls.isNotEmpty);
      await server.close();
      gate.complete();
      await request;
      await until(() => calls.length == 2 && !hidden);
      expect(calls, [true, false]);
    },
  );

  test(
    'malformed managed values do not change the application constraint',
    () async {
      final calls = <bool>[];
      await connect((managed) async {
        calls.add(managed);
        return true;
      });
      final response = await server
          .sessionFor('app')!
          .sendRequest(
            kMethodSetEntryManaged,
            params: {'managed': 'yes'},
            timeout: const Duration(seconds: 1),
          );
      expect((response['error'] as Map)['code'], ProtocolError.invalid);
      expect(calls, isEmpty);
    },
  );

  test(
    'menu-bar callbacks are serial even when the first request times out',
    () async {
      final gate = Completer<void>();
      var hidden = false;
      final calls = <bool>[];
      await connect((managed) async {
        calls.add(managed);
        if (managed) await gate.future;
        hidden = managed;
        return true;
      });
      final session = server.sessionFor('app')!;
      final hide = session.sendRequest(
        kMethodSetEntryManaged,
        params: {'managed': true},
        timeout: const Duration(milliseconds: 100),
      );
      await expectLater(hide, throwsA(isA<TimeoutException>()));
      final allow = session.sendRequest(
        kMethodSetEntryManaged,
        params: {'managed': false},
        timeout: const Duration(seconds: 1),
      );
      // A later response proves the SDK has received allow while its callback
      // must still wait behind the earlier asynchronous hide.
      await session.sendRequest(
        kMethodVersionStatus,
        timeout: const Duration(seconds: 1),
      );
      expect(calls, [true]);
      gate.complete();
      await allow;
      expect(calls, [true, false]);
      expect(hidden, isFalse);
    },
  );
}
