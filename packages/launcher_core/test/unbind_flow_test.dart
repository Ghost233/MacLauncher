import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:launcher_core/launcher_core.dart';
import 'package:maclauncher_sdk/maclauncher_sdk.dart';
import 'package:test/test.dart';

import 'support.dart';

/// 记录入口回调调用的受控应用侧。
class RecordingEntryCallbacks {
  final events = <String>[];

  Future<bool> setEntryManaged(bool managed) async {
    events.add('setEntryManaged($managed)');
    return true;
  }
}

void main() {
  late Directory temp;
  late EndpointLayout layout;
  late BindingStore store;
  late PreferenceStore prefs;
  late ConfigRefresher refresher;

  String storePath() => '${temp.path}/bindings.json';
  String prefsPath() => '${temp.path}/preferences.json';
  String statePath() => '${temp.path}/config_refresh_state.json';

  setUp(() async {
    temp = Directory.systemTemp.createTempSync('unbind-flow-test');
    layout = EndpointLayout(directory: '${temp.path}/endpoint');
    store = await BindingStore.load(storePath());
    prefs = await PreferenceStore.load(prefsPath());
    refresher = await ConfigRefresher.load(store, statePath());
  });

  tearDown(() {
    if (temp.existsSync()) temp.deleteSync(recursive: true);
  });

  /// 写入（或覆盖）项目清单；同一项目始终落在同一路径。
  String writeManifest(Map<String, Object?> content) {
    final dir = Directory('${temp.path}/proj')..createSync();
    final file = File('${dir.path}/$kManifestFileName');
    file.writeAsStringSync(const JsonEncoder.withIndent('  ').convert(content));
    return file.path;
  }

  Map<String, Object?> manifest({
    List<Map<String, String>> services = const [
      {'id': 'svc-1', 'name': '服务一'},
      {'id': 'svc-2', 'name': '服务二'},
    ],
  }) => {
    'schemaVersion': 1,
    'project': {'id': 'proj-a', 'name': '项目 A'},
    'services': services,
    'integration': {'type': 'sdk'},
  };

  /// 绑定项目并造好登录启动偏好与 invalid/retained 残留。
  Future<String> seedProject() async {
    final manifestPath = writeManifest(manifest());
    await store.associate(manifestPath);
    await prefs.setLoginStartEnabled('proj-a', 'svc-1', true);

    // retained：svc-1 声明被移除。
    writeManifest(
      manifest(
        services: [
          {'id': 'svc-2', 'name': '服务二'},
        ],
      ),
    );
    await refresher.refresh('proj-a');
    // invalid：清单不可读。
    File(manifestPath).deleteSync();
    await refresher.refresh('proj-a');

    expect(refresher.retainedServices('proj-a'), hasLength(1));
    expect(refresher.invalidReason('proj-a'), isNotNull);
    return manifestPath;
  }

  void expectLocalStateCleared() {
    expect(store.bindings, isEmpty);
    expect(prefs.enabledServices('proj-a'), isEmpty);
    expect(refresher.invalidReason('proj-a'), isNull);
    expect(refresher.retainedServices('proj-a'), isEmpty);
  }

  Future<void> expectLocalStateClearedAfterReload() async {
    final reloadedStore = await BindingStore.load(storePath());
    expect(reloadedStore.bindings, isEmpty);
    final reloadedPrefs = await PreferenceStore.load(prefsPath());
    expect(reloadedPrefs.enabledServices('proj-a'), isEmpty);
    final reloadedRefresher = await ConfigRefresher.load(
      reloadedStore,
      statePath(),
    );
    expect(reloadedRefresher.invalidReason('proj-a'), isNull);
    expect(reloadedRefresher.retainedServices('proj-a'), isEmpty);
  }

  test('在线受管会话：先归还入口，随后关会话并清全部本地状态', () async {
    await seedProject();
    final server = await LauncherServer.start(layout: layout, bindings: store);
    addTearDown(server.close);
    final coordinator = EntryHandoffCoordinator(
      server: server,
      statusQuery: (_) async => true,
      releaseTimeout: const Duration(milliseconds: 300),
    );
    addTearDown(coordinator.dispose);
    final flow = UnbindFlow(
      bindings: store,
      preferences: prefs,
      refresher: refresher,
      handoff: coordinator,
      server: server,
    );

    final entry = RecordingEntryCallbacks();
    final sdk = MacLauncherSdk.connect(
      projectId: 'proj-a',
      socketPath: layout.socketPath,
      retryInterval: const Duration(milliseconds: 100),
      services: {
        'svc-2': ServiceCallbacks(
          name: '服务二',
          onStatus: () async {
            return ServiceStatus(state: ServiceState.running);
          },
        ),
      },
      app: AppCallbacks(onSetEntryManaged: entry.setEntryManaged),
    );
    addTearDown(sdk.dispose);
    await until(
      () => coordinator.statusOf('proj-a') == EntryHandoffStatus.managed,
    );
    expect(server.registry.isActive('proj-a'), isTrue);

    await flow.unbind('proj-a');

    // 入口先归还，会话随后关闭。
    expect(entry.events.last, 'setEntryManaged(false)');
    await until(() => !server.registry.isActive('proj-a'));

    expectLocalStateCleared();
    await expectLocalStateClearedAfterReload();

    // 重连被按既有 unknown-project 路径拒绝。
    final socket = await connectRaw(layout.socketPath);
    addTearDown(socket.destroy);
    final welcome = await rawHello(socket, helloMessage(projectId: 'proj-a'));
    expect(welcome['accepted'], isFalse);
    expect(welcome['reason'], RejectReason.unknownProject);
  });

  test('应用不在线：解除绑定照样完成且不报错', () async {
    await seedProject();
    final server = await LauncherServer.start(layout: layout, bindings: store);
    addTearDown(server.close);
    final coordinator = EntryHandoffCoordinator(
      server: server,
      statusQuery: (_) async => true,
      releaseTimeout: const Duration(milliseconds: 300),
    );
    addTearDown(coordinator.dispose);
    final flow = UnbindFlow(
      bindings: store,
      preferences: prefs,
      refresher: refresher,
      handoff: coordinator,
      server: server,
    );

    await flow.unbind('proj-a');

    expectLocalStateCleared();
    await expectLocalStateClearedAfterReload();
  });

  test('解除未知项目抛 StateError', () async {
    final server = await LauncherServer.start(layout: layout, bindings: store);
    addTearDown(server.close);
    final coordinator = EntryHandoffCoordinator(
      server: server,
      statusQuery: (_) async => true,
    );
    addTearDown(coordinator.dispose);
    final flow = UnbindFlow(
      bindings: store,
      preferences: prefs,
      refresher: refresher,
      handoff: coordinator,
      server: server,
    );

    expect(
      () => flow.unbind('ghost'),
      throwsA(
        isA<StateError>().having(
          (e) => e.message,
          'message',
          contains('ghost'),
        ),
      ),
    );
  });
}
