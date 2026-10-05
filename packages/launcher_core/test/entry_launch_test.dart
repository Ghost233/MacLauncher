import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:launcher_core/launcher_core.dart';
import 'package:maclauncher_sdk/maclauncher_sdk.dart';
import 'package:test/test.dart';

/// Raw-protocol peer fixture: connects to the launcher endpoint, performs a
/// valid hello, reports its argv/cwd/pid to a file, then stays alive.
/// Written to a temp directory and compiled once per test run, so no package
/// resolution is needed.
const _fixtureSource = r'''
import 'dart:async';
import 'dart:convert';
import 'dart:io';

Future<void> main(List<String> args) async {
  // args: projectId socketPath reportFile
  File(args[2]).writeAsStringSync(jsonEncode({
    'argv': args,
    'cwd': Directory.current.path,
    'pid': pid,
  }));
  final socket = await Socket.connect(
      InternetAddress(args[1], type: InternetAddressType.unix), 0);
  socket.writeln(jsonEncode({
    'type': 'hello',
    'protocolVersion': 1,
    'projectId': args[0],
    'appSessionId': 'fixture-$pid',
    'capabilities': {
      'services': [
        {'id': 'svc', 'name': 'Svc', 'methods': ['status']},
      ],
      'app': <String>[],
    },
  }));
  await socket.flush();
  await socket.first; // welcome
  await Completer<void>().future; // stay alive
}
''';

void main() {
  final dartBin = File(Platform.resolvedExecutable).path;
  late Directory temp;
  late String fixtureExe;

  /// Compiles the fixture once for the whole run.
  setUpAll(() async {
    final buildDir = Directory.systemTemp.createTempSync(
      'entry-launch-fixture-',
    );
    final source = File('${buildDir.path}/peer.dart')
      ..writeAsStringSync(_fixtureSource);
    fixtureExe = '${buildDir.path}/peer';
    final result = await Process.run(dartBin, [
      'compile',
      'exe',
      source.path,
      '-o',
      fixtureExe,
    ]);
    if (result.exitCode != 0) {
      fail('fixture compilation failed: ${result.stderr}');
    }
  });

  setUp(() {
    temp = Directory.systemTemp.createTempSync('entry-launch-test-');
  });

  tearDown(() {
    if (temp.existsSync()) temp.deleteSync(recursive: true);
  });

  Future<(LauncherServer, BindingStore, LaunchOrchestrator)> setup({
    required Map<String, Object?> manifest,
    String projectDirName = 'proj',
  }) async {
    final projectDir = Directory('${temp.path}/$projectDirName')..createSync();
    File('${projectDir.path}/$kManifestFileName')
        .writeAsStringSync(jsonEncode(manifest));
    final store = await BindingStore.load(
      '${temp.path}/$projectDirName.store.json',
    );
    await store.associate('${projectDir.path}/$kManifestFileName');
    final server = await LauncherServer.start(
      layout: EndpointLayout(
        directory: '${temp.path}/endpoint-$projectDirName',
      ),
      bindings: store,
    );
    final orchestrator = LaunchOrchestrator(
      server: server,
      store: store,
      connectTimeout: const Duration(seconds: 15),
    );
    return (server, store, orchestrator);
  }

  Map<String, Object?> manifest({
    String projectId = 'proj-launch',
    Map<String, Object?>? entry,
  }) => {
    'schemaVersion': 1,
    'project': {'id': projectId, 'name': '拉起测试'},
    'services': [
      {'id': 'svc', 'name': '服务'},
    ],
    'integration': {'type': 'sdk'},
    if (entry != null) 'entry': entry,
  };

  void killReportedPid(String reportPath) {
    final report =
        jsonDecode(File(reportPath).readAsStringSync()) as Map<String, Object?>;
    final childPid = report['pid'] as int?;
    if (childPid != null) Process.killPid(childPid);
  }

  test(
    'not running: opens the real entry, SDK connects, capabilities usable',
    () async {
      final minimalApp = File(
        '${Directory.current.path}/../../example/minimal_app/build/minimal_app',
      );
      final useRealSdkPeer = minimalApp.existsSync();

      late final Map<String, Object?> entry;
      String? reportPath;
      if (useRealSdkPeer) {
        entry = {
          'kind': 'executable',
          // Absolute path; args carry the socket to connect to.
          'path': minimalApp.absolute.path,
          'args': ['proj-launch', '${temp.path}/endpoint-proj/sdk-v1.sock'],
        };
      } else {
        reportPath = '${temp.path}/report.json';
        entry = {
          'kind': 'executable',
          'path': fixtureExe,
          'args': [
            'proj-launch',
            '${temp.path}/endpoint-proj/sdk-v1.sock',
            reportPath,
          ],
        };
      }

      final (server, _, orchestrator) = await setup(
        manifest: manifest(entry: entry),
      );
      addTearDown(server.close);
      // The detached peer keeps running after the test; kill it by matching
      // the unique socket path it was launched with.
      addTearDown(() async {
        await Process.run('pkill', ['-f', server.layout.socketPath]);
      });

      final result = await orchestrator.ensureEntryConnected('proj-launch');

      expect(result, isA<LaunchConnected>());
      expect(server.registry.isActive('proj-launch'), isTrue);
      final project = server.registry.byProject('proj-launch')!;
      // Capability check is possible right after the connection: only the
      // declared capabilities are visible.
      if (useRealSdkPeer) {
        expect(
          project.capabilities.serviceById('demo')?.methods,
          contains(kMethodStatus),
        );
      } else {
        expect(project.capabilities.serviceById('svc')?.methods, ['status']);
        killReportedPid(reportPath!);
      }
    },
  );

  test('already connected: never opens the entry', () async {
    final (server, _, orchestrator) = await setup(
      manifest: manifest(
        entry: {
          'kind': 'executable',
          // Would fail loudly if a launch were attempted.
          'path': 'does-not-exist-anywhere',
        },
      ),
    );
    addTearDown(server.close);

    final sdk = MacLauncherSdk.connect(
      projectId: 'proj-launch',
      socketPath: server.layout.socketPath,
      services: {
        'svc': ServiceCallbacks(
          name: '服务',
          onStatus: () async => ServiceStatus(state: ServiceState.running),
        ),
      },
    );
    addTearDown(sdk.dispose);
    await untilActive(server, 'proj-launch');

    final result = await orchestrator.ensureEntryConnected('proj-launch');
    expect(result, isA<LaunchAlreadyConnected>());
  });

  test('no entry configured: LaunchUnavailable, nothing spawned', () async {
    final (server, _, orchestrator) = await setup(manifest: manifest());
    addTearDown(server.close);

    final result = await orchestrator.ensureEntryConnected('proj-launch');
    expect(result, isA<LaunchUnavailable>());
    expect(server.registry.isActive('proj-launch'), isFalse);
  });

  test('invalid configuration at the binding path blocks launching', () async {
    final marker = '${temp.path}/spawned.marker';
    final (server, _, orchestrator) = await setup(
      manifest: manifest(
        entry: {
          'kind': 'executable',
          'path': '/usr/bin/touch',
          'args': [marker],
        },
      ),
    );
    addTearDown(server.close);

    // The configuration turns invalid after association.
    final binding = (await BindingStore.load('${temp.path}/proj.store.json'))
        .byProjectId('proj-launch')!;
    File(binding.manifestPath).writeAsStringSync(
      jsonEncode({
        'schemaVersion': 99,
        'project': {'id': 'proj-launch', 'name': 'x'},
        'services': const [],
      }),
    );

    final result = await orchestrator.ensureEntryConnected('proj-launch');
    expect(result, isA<LaunchConfigBlocked>());
    expect(
      (result as LaunchConfigBlocked).reason,
      ManifestRejection.unknownVersion,
    );
    expect(File(marker).existsSync(), isFalse);
  });

  test(
    'identity mismatch between config and binding blocks launching',
    () async {
      final (server, _, orchestrator) = await setup(
        manifest: manifest(
          entry: {'kind': 'executable', 'path': '/usr/bin/true'},
        ),
      );
      addTearDown(server.close);
      final binding = (await BindingStore.load('${temp.path}/proj.store.json'))
          .byProjectId('proj-launch')!;
      final source =
          jsonDecode(File(binding.manifestPath).readAsStringSync()) as Map;
      (source['project'] as Map)['id'] = 'someone-else';
      File(binding.manifestPath).writeAsStringSync(jsonEncode(source));

      final result = await orchestrator.ensureEntryConnected('proj-launch');
      expect(result, isA<LaunchConfigBlocked>());
    },
  );

  test('nonexistent program surfaces a concrete reason', () async {
    final (server, _, orchestrator) = await setup(
      manifest: manifest(
        entry: {'kind': 'executable', 'path': 'no/such/program'},
      ),
    );
    addTearDown(server.close);

    final result = await orchestrator.ensureEntryConnected('proj-launch');
    expect(result, isA<LaunchOpenFailed>());
    final error = (result as LaunchOpenFailed).error;
    expect(error.reason, EntryOpenFailure.missingProgram);
    expect(error.detail, contains('no/such/program'));
  });

  test('executable receives args and working directory; paths resolve against the manifest directory', () async {
    final reportPath = '${temp.path}/report.json';
    final workSub = Directory('${temp.path}/proj/work')
      ..createSync(recursive: true);
    final (server, _, orchestrator) = await setup(
      manifest: manifest(
        entry: {
          'kind': 'executable',
          // Relative to the manifest directory.
          'path': 'peer',
          'args': [
            'proj-launch',
            '${temp.path}/endpoint-proj/sdk-v1.sock',
            reportPath,
          ],
          'workingDirectory': 'work',
        },
      ),
    );
    addTearDown(server.close);
    // Place the compiled fixture inside the manifest directory.
    File(fixtureExe).copySync('${temp.path}/proj/peer');

    final result = await orchestrator.ensureEntryConnected('proj-launch');

    expect(result, isA<LaunchConnected>());
    final report =
        jsonDecode(File(reportPath).readAsStringSync()) as Map<String, Object?>;
    expect(report['argv'], [
      'proj-launch',
      '${temp.path}/endpoint-proj/sdk-v1.sock',
      reportPath,
    ]);
    expect(
      report['cwd'],
      // Directory.current may resolve symlinks (e.g. /var → /private/var).
      Directory(workSub.path).resolveSymbolicLinksSync(),
    );
    killReportedPid(reportPath);
  });

  test(
    'connection timeout after opening the entry is unknown, never started',
    () async {
      final (server, store, _) = await setup(
        manifest: manifest(
          // /usr/bin/true opens fine but never connects.
          entry: {'kind': 'executable', 'path': '/usr/bin/true'},
        ),
      );
      addTearDown(server.close);
      final fast = LaunchOrchestrator(
        server: server,
        store: store,
        connectTimeout: const Duration(milliseconds: 300),
      );

      final result = await fast.ensureEntryConnected('proj-launch');
      expect(result, isA<LaunchUnknown>());
      expect(server.registry.isActive('proj-launch'), isFalse);
    },
  );

  test('unbound project is reported without launching', () async {
    final (server, store, _) = await setup(manifest: manifest());
    addTearDown(server.close);
    final orchestrator = LaunchOrchestrator(server: server, store: store);

    final result = await orchestrator.ensureEntryConnected('stranger');
    expect(result, isA<LaunchUnbound>());
  });

  group('EntryLauncher', () {
    test('kind app with a missing bundle fails concretely', () async {
      expect(
        () => const EntryLauncher().open(
          const ManifestEntry(kind: EntryKind.app, path: 'Nope.app'),
          manifestDir: temp.path,
        ),
        throwsA(
          isA<EntryOpenException>().having(
            (e) => e.reason,
            'reason',
            EntryOpenFailure.missingProgram,
          ),
        ),
      );
    });

    test('kind app surfaces `open` failure for a bogus bundle', () async {
      Directory('${temp.path}/Fake.app').createSync();
      expect(
        () => const EntryLauncher().open(
          const ManifestEntry(kind: EntryKind.app, path: 'Fake.app'),
          manifestDir: temp.path,
        ),
        throwsA(
          isA<EntryOpenException>().having(
            (e) => e.reason,
            'reason',
            EntryOpenFailure.openFailed,
          ),
        ),
      );
    });
  });
}

Future<void> untilActive(
  LauncherServer server,
  String projectId, {
  Duration timeout = const Duration(seconds: 10),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (!server.registry.isActive(projectId)) {
    if (DateTime.now().isAfter(deadline)) {
      throw TimeoutException('project $projectId never connected');
    }
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
}
