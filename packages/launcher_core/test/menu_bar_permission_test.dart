import 'dart:async';
import 'dart:io';

import 'package:launcher_core/launcher_core.dart';
import 'package:maclauncher_sdk/maclauncher_sdk.dart';
import 'package:test/test.dart';

import 'support.dart';

void main() {
  late Directory temp;
  late PreferenceStore preferences;
  late LauncherServer server;
  late EntryHandoffCoordinator handoff;

  setUp(() async {
    temp = Directory.systemTemp.createTempSync('menu-bar-permission-');
    preferences = await PreferenceStore.load('${temp.path}/preferences.json');
    server = await LauncherServer.start(
      layout: EndpointLayout(directory: '${temp.path}/endpoint'),
      bindings: InMemoryBindingLookup({'vpn', 'other'}),
    );
    handoff = EntryHandoffCoordinator(
      server: server,
      preferences: preferences,
      statusQuery: (_) async => true,
      requestTimeout: const Duration(milliseconds: 200),
    );
  });

  tearDown(() async {
    await handoff.dispose();
    await server.close();
    temp.deleteSync(recursive: true);
  });

  MacLauncherSdk connect({
    String projectId = 'vpn',
    Future<bool> Function(bool)? callback,
  }) {
    final sdk = MacLauncherSdk.connect(
      projectId: projectId,
      socketPath: server.layout.socketPath,
      retryInterval: const Duration(milliseconds: 30),
      services: {
        'svc': ServiceCallbacks(
          name: 'Svc',
          onStatus: () async => ServiceStatus(state: ServiceState.running),
        ),
      },
      app: AppCallbacks(onSetEntryManaged: callback),
    );
    addTearDown(sdk.dispose);
    return sdk;
  }

  for (final allowed in [false, true]) {
    for (final appWantsVisible in [false, true]) {
      test(
        'permission $allowed respects app setting $appWantsVisible',
        () async {
          await handoff.setMenuBarAllowed('vpn', allowed);
          var visible = appWantsVisible;
          final calls = <bool>[];
          connect(
            callback: (managed) async {
              calls.add(managed);
              visible = !managed && appWantsVisible;
              return true;
            },
          );
          await until(
            () =>
                handoff.statusOf('vpn') ==
                (allowed
                    ? EntryHandoffStatus.allowed
                    : EntryHandoffStatus.managed),
          );
          expect(calls, [!allowed]);
          expect(visible, allowed && appWantsVisible);
          expect(server.registry.isActive('vpn'), isTrue);
          final status = await server
              .sessionFor('vpn')!
              .sendRequest(
                kMethodStatus,
                serviceId: 'svc',
                timeout: const Duration(seconds: 1),
              );
          expect(status['error'], isNull);
        },
      );
    }
  }

  test(
    'online permission changes affect only their project and survive reconnect',
    () async {
      final vpnCalls = <bool>[];
      final otherCalls = <bool>[];
      final sdk = connect(
        callback: (managed) async {
          vpnCalls.add(managed);
          return true;
        },
      );
      connect(
        projectId: 'other',
        callback: (managed) async {
          otherCalls.add(managed);
          return true;
        },
      );
      await until(
        () =>
            handoff.statusOf('vpn') == EntryHandoffStatus.managed &&
            handoff.statusOf('other') == EntryHandoffStatus.managed,
      );
      await handoff.setMenuBarAllowed('vpn', true);
      expect(handoff.statusOf('vpn'), EntryHandoffStatus.allowed);
      expect(vpnCalls, [true, false]);
      expect(otherCalls, [true]);
      final previousSession = sdk.launcherSessionId;
      await server.sessionFor('vpn')!.close();
      await until(
        () =>
            sdk.launcherSessionId != null &&
            sdk.launcherSessionId != previousSession &&
            handoff.statusOf('vpn') == EntryHandoffStatus.allowed,
      );
      expect(vpnCalls, [true, false, false]);
      expect(otherCalls, [true]);
    },
  );

  test('a refused change preserves selection and can be retried', () async {
    var confirm = true;
    connect(callback: (_) async => confirm);
    await until(() => handoff.statusOf('vpn') == EntryHandoffStatus.managed);
    confirm = false;
    await handoff.setMenuBarAllowed('vpn', true);
    expect(handoff.statusOf('vpn'), EntryHandoffStatus.failed);
    expect(preferences.isMenuBarAllowed('vpn'), isTrue);
    final reloaded = await PreferenceStore.load(
      '${temp.path}/preferences.json',
    );
    expect(reloaded.isMenuBarAllowed('vpn'), isTrue);
    confirm = true;
    await handoff.retry('vpn');
    expect(handoff.statusOf('vpn'), EntryHandoffStatus.allowed);
  });

  test('latest selection wins after a timed-out asynchronous hide', () async {
    final gate = Completer<void>();
    addTearDown(() {
      if (!gate.isCompleted) gate.complete();
    });
    final calls = <bool>[];
    var hidden = false;
    connect(
      callback: (managed) async {
        calls.add(managed);
        if (managed) await gate.future;
        hidden = managed;
        return true;
      },
    );
    await until(() => handoff.statusOf('vpn') == EntryHandoffStatus.failed);
    final changes = <EntryHandoffStatus>[];
    final subscription = handoff.states.listen(
      (state) => changes.add(state.status),
    );
    addTearDown(subscription.cancel);
    final change = handoff.setMenuBarAllowed('vpn', true);
    await until(() => preferences.isMenuBarAllowed('vpn'));
    gate.complete();
    await change;
    expect(calls, [true, false]);
    expect(hidden, isFalse);
    expect(handoff.statusOf('vpn'), EntryHandoffStatus.allowed);
    expect(changes, isNot(contains(EntryHandoffStatus.managed)));
  });

  test(
    'rapid toggles skip superseded requests and persist the latest choice',
    () async {
      final gate = Completer<void>();
      addTearDown(() {
        if (!gate.isCompleted) gate.complete();
      });
      final calls = <bool>[];
      connect(
        callback: (managed) async {
          calls.add(managed);
          if (managed) await gate.future;
          return true;
        },
      );
      await until(() => calls.isNotEmpty);
      final changes = Future.wait([
        handoff.setMenuBarAllowed('vpn', true),
        handoff.setMenuBarAllowed('vpn', false),
        handoff.setMenuBarAllowed('vpn', true),
      ]);
      gate.complete();
      await changes;
      expect(calls, [true, false]);
      expect(handoff.statusOf('vpn'), EntryHandoffStatus.allowed);
      final reloaded = await PreferenceStore.load(
        '${temp.path}/preferences.json',
      );
      expect(reloaded.isMenuBarAllowed('vpn'), isTrue);
    },
  );

  test(
    'unsupported application stays connected and receives no menu-bar request',
    () async {
      connect();
      await until(
        () => handoff.statusOf('vpn') == EntryHandoffStatus.notManageable,
      );
      await handoff.retry('vpn');
      expect(handoff.statusOf('vpn'), EntryHandoffStatus.notManageable);
      expect(server.registry.isActive('vpn'), isTrue);
    },
  );
}
