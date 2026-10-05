import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:launcher_core/launcher_core.dart';
import 'package:test/test.dart';

import 'support.dart';

/// End-to-end coverage for issue #35: the launcher asks the real
/// `example/minimal_app` binary (spawned as a subprocess) for its 版本状况
/// over a real socket and receives each of the three configurable states.
///
/// The expected fake values below mirror
/// `example/minimal_app/lib/fake_version_status.dart`; keep them in sync.
void main() {
  const timeout = Timeout(Duration(minutes: 2));

  /// The demo's fixed fake values (see fake_version_status.dart).
  const demoCurrentVersion = '1.0.0';
  const demoLatestVersion = '1.1.0';
  const demoDownloadUrl =
      'https://example.invalid/minimal_app/minimal_app-1.1.0.dmg';
  const demoSha256 =
      '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef';
  const demoFailureReason = 'mock 网络失败：更新源不可达';

  group('demo minimal_app version status (real subprocess)', () {
    late Directory temp;
    late EndpointLayout layout;
    late BindingStore store;
    late LauncherServer server;

    /// Locates the repository root by walking up from the current working
    /// directory until the workspace marker is found, so the test works no
    /// matter which directory `dart test` is invoked from.
    Directory repoRoot() {
      var dir = Directory.current.absolute;
      while (true) {
        if (File('${dir.path}/example/minimal_app/bin/minimal_app.dart')
            .existsSync()) {
          return dir;
        }
        final parent = dir.parent;
        if (parent.path == dir.path) {
          fail('repository root not found above ${Directory.current.path}');
        }
        dir = parent;
      }
    }

    setUp(() async {
      temp = Directory.systemTemp.createTempSync('demo-version-status-test');
      layout = EndpointLayout(directory: '${temp.path}/endpoint');
      store = await BindingStore.load('${temp.path}/bindings.json');

      final dir = Directory('${temp.path}/proj')..createSync(recursive: true);
      // Service ids must match the two FakeBusiness services minimal_app
      // registers, or the handshake is rejected.
      File('${dir.path}/$kManifestFileName').writeAsStringSync('''
{
  "schemaVersion": 1,
  "project": {"id": "proj-a", "name": "演示项目"},
  "services": [
    {"id": "demo", "name": "演示服务"},
    {"id": "worker", "name": "后台服务"}
  ]
}
''');
      await store.associate('${dir.path}/$kManifestFileName');

      server = await LauncherServer.start(layout: layout, bindings: store);
      addTearDown(server.close);
    });

    tearDown(() {
      if (temp.existsSync()) temp.deleteSync(recursive: true);
    });

    /// Spawns the real minimal_app and waits until the launcher registers
    /// the connection. Returns the running process; teardown stops it.
    Future<Process> runDemoApp({
      List<String> extraArgs = const [],
      Map<String, String> environment = const {},
    }) async {
      final root = repoRoot();
      final process = await Process.start(
        Platform.resolvedExecutable,
        [
          'run',
          'example/minimal_app/bin/minimal_app.dart',
          'proj-a',
          layout.socketPath,
          ...extraArgs,
        ],
        workingDirectory: root.path,
        environment: environment,
      );
      final out = <String>[];
      final err = <String>[];
      process.stdout.transform(utf8.decoder).listen(out.add);
      process.stderr.transform(utf8.decoder).listen(err.add);
      addTearDown(() async {
        process.kill(ProcessSignal.sigint);
        try {
          await process.exitCode.timeout(const Duration(seconds: 5));
        } on TimeoutException {
          process.kill(ProcessSignal.sigkill);
          await process.exitCode;
        }
      });
      try {
        await until(
          () => server.registry.isActive('proj-a'),
          timeout: const Duration(seconds: 60),
        );
      } catch (_) {
        fail('minimal_app did not connect.\nstdout: $out\nstderr: $err');
      }
      return process;
    }

    ServiceOperations ops() => ServiceOperations(
      server: server,
      scope: BindingServiceScope(store),
      timeout: const Duration(seconds: 10),
    );

    test('success: full fake update answer arrives verbatim', () async {
      await runDemoApp(extraArgs: ['--version-status=success']);

      final result = await ops().versionStatus('proj-a');

      final status = (result as VersionStatusSnapshot).status;
      expect(status.state.name, 'success');
      expect(status.currentVersion, demoCurrentVersion);
      expect(status.hasUpdate, isTrue);
      expect(status.latestVersion, demoLatestVersion);
      expect(status.downloadUrl, demoDownloadUrl);
      expect(status.sha256, demoSha256);
      expect(status.failureReason, isNull);
    }, timeout: timeout);

    test(
      'failure: query failure arrives as a failure answer with reason',
      () async {
        await runDemoApp(extraArgs: ['--version-status=failure']);

        final result = await ops().versionStatus('proj-a');

        final status = (result as VersionStatusSnapshot).status;
        expect(status.state.name, 'failure');
        expect(status.currentVersion, demoCurrentVersion);
        expect(status.failureReason, demoFailureReason);
      },
      timeout: timeout,
    );

    test('unsupported: no capability declared, launcher never asks', () async {
      await runDemoApp(extraArgs: ['--version-status=unsupported']);

      expect(
        server.registry
            .byProject('proj-a')!
            .capabilities
            .supportsApp('versionStatus'),
        isFalse,
      );
      // The launcher never sends the request to an app without the
      // capability; the SDK-level auto-answer for stray requests is
      // covered in version_status_test.dart.
      expect(
        await ops().versionStatus('proj-a'),
        isA<VersionStatusUnsupported>(),
      );
    }, timeout: timeout);

    test(
      'environment variable selects the mode when no flag is given',
      () async {
        await runDemoApp(
          environment: {
            ...Platform.environment,
            'MACLAUNCHER_VERSION_STATUS': 'failure',
          },
        );

        final result = await ops().versionStatus('proj-a');

        final status = (result as VersionStatusSnapshot).status;
        expect(status.state.name, 'failure');
        expect(status.failureReason, demoFailureReason);
      },
      timeout: timeout,
    );

    test('unknown mode fails loudly with a usage error', () async {
      final root = repoRoot();
      final process = await Process.start(Platform.resolvedExecutable, [
        'run',
        'example/minimal_app/bin/minimal_app.dart',
        'proj-a',
        '--version-status=bogus',
      ], workingDirectory: root.path);
      final err = await process.stderr.transform(utf8.decoder).join();
      final exitCode = await process.exitCode;

      expect(exitCode, 64);
      expect(err, contains('bogus'));
    }, timeout: timeout);
  });
}
