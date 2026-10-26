import 'dart:async';
import 'dart:io';

import 'package:maclauncher_sdk/maclauncher_sdk.dart';
import 'package:minimal_app/fake_business.dart';
import 'package:minimal_app/fake_version_status.dart';
import 'package:minimal_app/maclauncher_manifest.g.dart';

/// Minimal controlled peer: registers two fake services and stays connected.
///
/// Usage: `dart run bin/minimal_app.dart [projectId] [socketPath]`
/// `[--version-status=success|failure|unsupported]`
///
/// `projectId` defaults to the generated [maclauncherProjectId] constant
/// (from `maclauncher.json` via `dart run maclauncher_sdk:codegen`); pass an
/// explicit value only when a test config declares a different identity.
///
/// The version status mode may also be set via the
/// MACLAUNCHER_VERSION_STATUS environment variable (the flag wins).
Future<void> main(List<String> args) async {
  final positional = [
    for (final a in args)
      if (!a.startsWith('--')) a,
  ];
  final DemoVersionStatusMode versionStatusMode;
  try {
    versionStatusMode = resolveDemoVersionStatusMode(
      args,
      Platform.environment,
    );
  } on FormatException catch (e) {
    stderr.writeln(e.message);
    exitCode = 64;
    return;
  }
  final projectId = positional.isNotEmpty
      ? positional[0]
      : maclauncherProjectId;
  final socketPath = positional.length > 1 ? positional[1] : null;

  final sdk = MacLauncherSdk.connect(
    projectId: projectId,
    socketPath: socketPath,
    services: {
      for (final entry in maclauncherServices.entries)
        entry.key: FakeBusiness(name: entry.value).callbacks(),
    },
    app: demoVersionStatusCallbacks(versionStatusMode),
  );

  sdk.states.listen((s) {
    stdout.writeln(
      'sdk state: ${s.state.name}'
      '${s.reason != null ? ' (${s.reason})' : ''}',
    );
  });

  stdout.writeln(
    'minimal_app running for project "$projectId" '
    '(version status: ${versionStatusMode.name}); ctrl-c to exit',
  );
  await ProcessSignal.sigint.watch().first;
  await sdk.dispose();
}
