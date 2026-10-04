import 'dart:async';
import 'dart:io';

import 'package:maclauncher_sdk/maclauncher_sdk.dart';
import 'package:minimal_app/fake_business.dart';

/// Minimal controlled peer: registers one fake service and stays connected.
///
/// Usage: dart run bin/minimal_app.dart <projectId> [socketPath]
Future<void> main(List<String> args) async {
  if (args.isEmpty) {
    stderr.writeln('usage: minimal_app <projectId> [socketPath]');
    exitCode = 64;
    return;
  }
  final projectId = args[0];
  final socketPath = args.length > 1 ? args[1] : null;

  final business = FakeBusiness(name: 'demo-service');
  final sdk = MacLauncherSdk.connect(
    projectId: projectId,
    socketPath: socketPath,
    services: {'demo': business.callbacks()},
  );

  sdk.states.listen((s) {
    stdout.writeln(
      'sdk state: ${s.state.name}'
      '${s.reason != null ? ' (${s.reason})' : ''}',
    );
  });

  stdout.writeln(
    'minimal_app running for project "$projectId"; ctrl-c to exit',
  );
  await ProcessSignal.sigint.watch().first;
  await sdk.dispose();
}
