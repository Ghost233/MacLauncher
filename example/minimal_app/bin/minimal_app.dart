import 'dart:async';
import 'dart:io';

import 'package:maclauncher_sdk/maclauncher_sdk.dart';
import 'package:minimal_app/fake_business.dart';
import 'package:minimal_app/fake_version_status.dart';

/// Minimal controlled peer: registers two fake services and stays connected.
///
/// Usage: `dart run bin/minimal_app.dart <projectId> [socketPath]`
/// `[--version-status=success|failure|unsupported]`
///
/// The version status mode may also be set via the
/// MACLAUNCHER_VERSION_STATUS environment variable (the flag wins).
Future<void> main(List<String> args) async {
  final positional = [
    for (final a in args)
      if (!a.startsWith('--')) a,
  ];
  if (positional.isEmpty) {
    stderr.writeln(
      'usage: minimal_app <projectId> [socketPath] '
      '[--$kVersionStatusFlag=success|failure|unsupported]',
    );
    exitCode = 64;
    return;
  }
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
  final projectId = positional[0];
  final socketPath = positional.length > 1 ? positional[1] : null;

  final sdk = MacLauncherSdk.connect(
    projectId: projectId,
    socketPath: socketPath,
    services: {
      'demo': FakeBusiness(name: '演示服务').callbacks(),
      'worker': FakeBusiness(name: '后台服务').callbacks(),
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
