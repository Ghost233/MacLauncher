import 'dart:io';

import 'package:launcher_core/launcher_core.dart';

Future<void> main(List<String> args) async {
  try {
    final server = await LauncherServer.start(
      layout: EndpointLayout(directory: args.single),
      bindings: InMemoryBindingLookup({'project'}),
    );
    stdout.writeln('owned');
    await stdin.first;
    await server.close();
  } catch (error) {
    stderr.writeln(error);
    exitCode = 73;
  }
}
