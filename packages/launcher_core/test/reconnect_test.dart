import 'dart:io';

import 'package:launcher_core/launcher_core.dart';
import 'package:maclauncher_sdk/maclauncher_sdk.dart';
import 'package:test/test.dart';

import 'support.dart';

void main() {
  late Directory temp;
  late EndpointLayout layout;

  setUp(() {
    temp = Directory.systemTemp.createTempSync('launcher-reconnect-test');
    layout = EndpointLayout(directory: '${temp.path}/MacLauncher');
  });

  tearDown(() {
    if (temp.existsSync()) temp.deleteSync(recursive: true);
  });

  test('SDK retries while the launcher is absent, without blocking', () async {
    final attemptsBefore = DateTime.now();
    final sdk = MacLauncherSdk.connect(
      projectId: 'proj-1',
      socketPath: layout.socketPath,
      retryInterval: const Duration(milliseconds: 100),
      services: {
        'svc': ServiceCallbacks(
          name: 'Svc',
          onStatus: () async {
            return ServiceStatus(state: ServiceState.stopped);
          },
        ),
      },
    );
    addTearDown(sdk.dispose);

    // The connect call returned immediately; retries accumulate in the
    // background while the app keeps running.
    await Future.delayed(const Duration(milliseconds: 450));
    expect(sdk.connectAttempts, greaterThanOrEqualTo(3));
    expect(DateTime.now().difference(attemptsBefore).inSeconds, lessThan(5));
  });

  test('SDK reconnects and re-handshakes after a launcher restart', () async {
    var server = await LauncherServer.start(
      layout: layout,
      bindings: InMemoryBindingLookup({'proj-1'}),
    );

    final sdk = MacLauncherSdk.connect(
      projectId: 'proj-1',
      socketPath: layout.socketPath,
      retryInterval: const Duration(milliseconds: 100),
      services: {
        'svc': ServiceCallbacks(
          name: 'Svc',
          onStatus: () async {
            return ServiceStatus(state: ServiceState.running);
          },
        ),
      },
    );
    addTearDown(sdk.dispose);

    await until(() => server.registry.isActive('proj-1'));
    final firstSession = sdk.launcherSessionId;

    await server.close();

    server = await LauncherServer.start(
      layout: layout,
      bindings: InMemoryBindingLookup({'proj-1'}),
    );
    addTearDown(server.close);

    await until(() => server.registry.isActive('proj-1'));
    // Server-side registration precedes the client's welcome processing by
    // one async hop; wait on the client-side session id itself.
    await until(() => sdk.launcherSessionId != null);
    expect(sdk.launcherSessionId, isNotNull);
    expect(sdk.launcherSessionId, isNot(firstSession));
  });
}
