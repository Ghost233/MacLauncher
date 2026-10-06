import 'dart:async';
import 'dart:io';

import 'package:launcher_core/launcher_core.dart';
import 'package:maclauncher_sdk/maclauncher_sdk.dart';
import 'package:test/test.dart';

import 'support.dart';

/// 记录入口回调调用的受控应用侧。
class RecordingEntryCallbacks {
  final events = <String>[];
  bool confirmTakeover = true;
  Completer<void>? setEntryGate;

  Future<bool> setEntryManaged(bool managed) async {
    events.add('setEntryManaged($managed)');
    await setEntryGate?.future;
    return confirmTakeover;
  }

  Future<void> openWindow() async {
    events.add('openWindow()');
  }
}

void main() {
  late Directory temp;
  late EndpointLayout layout;

  setUp(() {
    temp = Directory.systemTemp.createTempSync('launcher-handoff-test');
    layout = EndpointLayout(directory: '${temp.path}/endpoint');
  });

  tearDown(() {
    if (temp.existsSync()) temp.deleteSync(recursive: true);
  });

  Future<LauncherServer> startServer() => LauncherServer.start(
    layout: layout,
    bindings: InMemoryBindingLookup({'proj-1'}),
  );

  MacLauncherSdk connectApp(
    RecordingEntryCallbacks entry, {
    bool declareEntryManaged = true,
    bool declareOpenWindow = true,
    Duration retry = const Duration(milliseconds: 100),
  }) {
    return MacLauncherSdk.connect(
      projectId: 'proj-1',
      socketPath: layout.socketPath,
      retryInterval: retry,
      services: {
        'svc': ServiceCallbacks(
          name: 'Svc',
          onStatus: () async {
            return ServiceStatus(state: ServiceState.running);
          },
        ),
      },
      app: AppCallbacks(
        onSetEntryManaged: declareEntryManaged ? entry.setEntryManaged : null,
        onOpenWindow: declareOpenWindow ? entry.openWindow : null,
      ),
    );
  }

  test('状态查询先于接管请求，确认后才宣告 managed', () async {
    final server = await startServer();
    addTearDown(server.close);
    final order = <String>[];
    final coordinator = EntryHandoffCoordinator(
      server: server,
      statusQuery: (_) async {
        order.add('statusQuery');
        return true;
      },
    );
    addTearDown(coordinator.dispose);

    final entry = RecordingEntryCallbacks();
    final probe = entry.events;
    final sdk = connectApp(entry);
    addTearDown(sdk.dispose);

    await until(
      () => coordinator.statusOf('proj-1') == EntryHandoffStatus.managed,
    );
    expect(order, ['statusQuery']);
    expect(probe, ['setEntryManaged(true)']);
  });

  test('确认失败保持 unmanaged，应用入口不被触碰', () async {
    final server = await startServer();
    addTearDown(server.close);
    final coordinator = EntryHandoffCoordinator(
      server: server,
      statusQuery: (_) async => true,
    );
    addTearDown(coordinator.dispose);

    final entry = RecordingEntryCallbacks()..confirmTakeover = false;
    final sdk = connectApp(entry);
    addTearDown(sdk.dispose);

    await until(() => entry.events.isNotEmpty);
    // 给协调器留出处理应答的时间。
    await Future<void>.delayed(const Duration(milliseconds: 200));
    expect(entry.events, ['setEntryManaged(true)']);
    expect(coordinator.statusOf('proj-1'), EntryHandoffStatus.unmanaged);
  });

  test('未声明 setEntryManaged 能力：notManageable 且不发请求', () async {
    final server = await startServer();
    addTearDown(server.close);
    var statusQueries = 0;
    final coordinator = EntryHandoffCoordinator(
      server: server,
      statusQuery: (_) async {
        statusQueries++;
        return true;
      },
    );
    addTearDown(coordinator.dispose);

    final entry = RecordingEntryCallbacks();
    final sdk = connectApp(entry, declareEntryManaged: false);
    addTearDown(sdk.dispose);

    await until(
      () => coordinator.statusOf('proj-1') == EntryHandoffStatus.notManageable,
    );
    await Future<void>.delayed(const Duration(milliseconds: 200));
    expect(entry.events, isEmpty);
    expect(statusQueries, 0);
  });

  test('断连后 managed 清除，重连重新握手并重新请求', () async {
    final server = await startServer();
    addTearDown(server.close);
    final coordinator = EntryHandoffCoordinator(
      server: server,
      statusQuery: (_) async => true,
    );
    addTearDown(coordinator.dispose);

    var entry = RecordingEntryCallbacks();
    var sdk = connectApp(entry);
    await until(
      () => coordinator.statusOf('proj-1') == EntryHandoffStatus.managed,
    );

    await sdk.dispose();
    await until(
      () => coordinator.statusOf('proj-1') == EntryHandoffStatus.unmanaged,
    );

    entry = RecordingEntryCallbacks();
    sdk = connectApp(entry);
    addTearDown(sdk.dispose);
    await until(
      () => coordinator.statusOf('proj-1') == EntryHandoffStatus.managed,
    );
    expect(entry.events, ['setEntryManaged(true)']);
  });

  test('旧会话的迟到确认不能标记新会话', () async {
    final server = await startServer();
    addTearDown(server.close);
    final coordinator = EntryHandoffCoordinator(
      server: server,
      statusQuery: (_) async => true,
    );
    addTearDown(coordinator.dispose);

    // 会话 A：接管回调被闸门挡住，请求在途。
    final entryA = RecordingEntryCallbacks()..setEntryGate = Completer<void>();
    final sdkA = connectApp(entryA);
    await until(() => entryA.events.isNotEmpty);
    expect(coordinator.statusOf('proj-1'), EntryHandoffStatus.unmanaged);

    // A 断开（请求仍在途），B 重新接入。
    await sdkA.dispose();
    await until(() => !server.registry.isActive('proj-1'));

    final entryB = RecordingEntryCallbacks();
    final sdkB = connectApp(entryB);
    addTearDown(sdkB.dispose);
    await until(
      () => coordinator.statusOf('proj-1') == EntryHandoffStatus.managed,
    );
    final managedSession = server.registry.byProject('proj-1')!;
    expect(entryB.events, ['setEntryManaged(true)']);

    // A 的回调迟到完成：不影响 B 的 managed 状态。
    entryA.setEntryGate!.complete();
    await Future<void>.delayed(const Duration(milliseconds: 200));
    expect(coordinator.statusOf('proj-1'), EntryHandoffStatus.managed);
    expect(
      server.registry.byProject('proj-1')!.launcherSessionId,
      managedSession.launcherSessionId,
    );
  });

  test('openWindow 只在声明能力时发送', () async {
    final server = await startServer();
    addTearDown(server.close);
    final coordinator = EntryHandoffCoordinator(
      server: server,
      statusQuery: (_) async => true,
    );
    addTearDown(coordinator.dispose);

    final entry = RecordingEntryCallbacks();
    final sdk = connectApp(entry);
    addTearDown(sdk.dispose);
    await until(
      () => coordinator.statusOf('proj-1') == EntryHandoffStatus.managed,
    );

    expect(
      await coordinator.openWindow('proj-1'),
      HandoffRequestOutcome.acknowledged,
    );
    expect(entry.events, contains('openWindow()'));

    expect(
      await coordinator.openWindow('stranger'),
      HandoffRequestOutcome.unavailable,
    );
  });

  test('openWindow 未声明时返回 unsupported 且不发请求', () async {
    final server = await startServer();
    addTearDown(server.close);
    final coordinator = EntryHandoffCoordinator(
      server: server,
      statusQuery: (_) async => true,
    );
    addTearDown(coordinator.dispose);

    final entry = RecordingEntryCallbacks();
    final sdk = connectApp(entry, declareOpenWindow: false);
    addTearDown(sdk.dispose);
    await until(
      () => coordinator.statusOf('proj-1') == EntryHandoffStatus.managed,
    );

    expect(
      await coordinator.openWindow('proj-1'),
      HandoffRequestOutcome.unsupported,
    );
    expect(entry.events, isNot(contains('openWindow()')));
  });

  test('releaseAll 尽力归还且从不发送 recycle', () async {
    final server = await startServer();
    addTearDown(server.close);
    final coordinator = EntryHandoffCoordinator(
      server: server,
      statusQuery: (_) async => true,
      releaseTimeout: const Duration(milliseconds: 300),
    );
    addTearDown(coordinator.dispose);

    var recycleCalls = 0;
    final entryA = RecordingEntryCallbacks();
    final sdkA = MacLauncherSdk.connect(
      projectId: 'proj-1',
      socketPath: layout.socketPath,
      services: {
        'svc': ServiceCallbacks(
          name: 'Svc',
          onStatus: () async {
            return ServiceStatus(state: ServiceState.running);
          },
          onRecycle: () async {
            recycleCalls++;
          },
        ),
      },
      app: AppCallbacks(onSetEntryManaged: entryA.setEntryManaged),
    );
    await until(
      () => coordinator.statusOf('proj-1') == EntryHandoffStatus.managed,
    );

    // 一个会话正常 managed；随后断开模拟死亡，再加入新会话。
    await sdkA.dispose();
    await until(
      () => coordinator.statusOf('proj-1') == EntryHandoffStatus.unmanaged,
    );

    final entryB = RecordingEntryCallbacks();
    final sdkB = connectApp(entryB);
    addTearDown(sdkB.dispose);
    await until(
      () => coordinator.statusOf('proj-1') == EntryHandoffStatus.managed,
    );

    await coordinator.releaseAll();
    expect(entryB.events, contains('setEntryManaged(false)'));
    expect(coordinator.statusOf('proj-1'), EntryHandoffStatus.unmanaged);
    expect(recycleCalls, 0);

    // 死会话上的 releaseAll 直接容忍。
    await sdkB.dispose();
    await coordinator.releaseAll();
    expect(recycleCalls, 0);
  });

  group('release（解除绑定路径）', () {
    test('向在线受管会话发送 managed:false 并清除状态', () async {
      final server = await startServer();
      addTearDown(server.close);
      final coordinator = EntryHandoffCoordinator(
        server: server,
        statusQuery: (_) async => true,
        releaseTimeout: const Duration(milliseconds: 300),
      );
      addTearDown(coordinator.dispose);

      final entry = RecordingEntryCallbacks();
      final sdk = connectApp(entry);
      addTearDown(sdk.dispose);
      await until(
        () => coordinator.statusOf('proj-1') == EntryHandoffStatus.managed,
      );

      await coordinator.release('proj-1');

      expect(entry.events, contains('setEntryManaged(false)'));
      expect(coordinator.statusOf('proj-1'), EntryHandoffStatus.unmanaged);
    });

    test('应用迟迟不确认归还：短超时后返回，状态仍清除', () async {
      final server = await startServer();
      addTearDown(server.close);
      final coordinator = EntryHandoffCoordinator(
        server: server,
        statusQuery: (_) async => true,
        releaseTimeout: const Duration(milliseconds: 100),
      );
      addTearDown(coordinator.dispose);

      final entry = RecordingEntryCallbacks()..setEntryGate = Completer<void>();
      final sdk = connectApp(entry);
      addTearDown(sdk.dispose);
      // 先让接管确认完成（闸门只挡第二次调用）。
      entry.setEntryGate!.complete();
      await until(
        () => coordinator.statusOf('proj-1') == EntryHandoffStatus.managed,
      );
      entry.setEntryGate = Completer<void>();
      addTearDown(() {
        if (!entry.setEntryGate!.isCompleted) entry.setEntryGate!.complete();
      });

      await coordinator.release('proj-1');

      expect(coordinator.statusOf('proj-1'), EntryHandoffStatus.unmanaged);
    });

    test('对未受管或离线的项目是 no-op，不报错、不发请求', () async {
      final server = await startServer();
      addTearDown(server.close);
      final coordinator = EntryHandoffCoordinator(
        server: server,
        statusQuery: (_) async => true,
        releaseTimeout: const Duration(milliseconds: 300),
      );
      addTearDown(coordinator.dispose);

      // 完全未连接的项目。
      await coordinator.release('ghost');

      // 已连接但能力不含 setEntryManaged（从未受管）。
      final entry = RecordingEntryCallbacks();
      final sdk = connectApp(entry, declareEntryManaged: false);
      addTearDown(sdk.dispose);
      await until(
        () =>
            coordinator.statusOf('proj-1') == EntryHandoffStatus.notManageable,
      );

      await coordinator.release('proj-1');

      expect(entry.events, isNot(contains('setEntryManaged(false)')));
    });
  });
}
