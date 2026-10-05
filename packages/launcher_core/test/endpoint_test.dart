import 'dart:io';

import 'package:launcher_core/launcher_core.dart';
import 'package:test/test.dart';

import 'support.dart';

void main() {
  late Directory temp;
  late EndpointLayout layout;

  setUp(() {
    temp = Directory.systemTemp.createTempSync('launcher-endpoint-test');
    layout = EndpointLayout(directory: '${temp.path}/MacLauncher');
  });

  tearDown(() {
    if (temp.existsSync()) temp.deleteSync(recursive: true);
  });

  test('endpoint directory is 0700 and socket is 0600', () async {
    final server = await LauncherServer.start(
      layout: layout,
      bindings: InMemoryBindingLookup(const {}),
    );
    addTearDown(server.close);

    final dirMode = FileStat.statSync(layout.directory).mode & 0xFFF;
    final socketMode = FileStat.statSync(layout.socketPath).mode & 0xFFF;
    expect(dirMode, int.parse('700', radix: 8));
    expect(socketMode, int.parse('600', radix: 8));
  });

  test('second instance cannot override an active endpoint', () async {
    final first = await LauncherServer.start(
      layout: layout,
      bindings: InMemoryBindingLookup(const {}),
    );
    addTearDown(first.close);

    expect(
      () => LauncherServer.start(
        layout: layout,
        bindings: InMemoryBindingLookup(const {}),
      ),
      throwsStateError,
    );

    // The first endpoint is still intact and accepting.
    expect(File(layout.socketPath).existsSync(), isTrue);
    final probe = await connectRaw(layout.socketPath);
    await probe.close();
  });

  test('after the holder stops, a new instance may take over', () async {
    final first = await LauncherServer.start(
      layout: layout,
      bindings: InMemoryBindingLookup(const {}),
    );
    await first.close();

    final second = await LauncherServer.start(
      layout: layout,
      bindings: InMemoryBindingLookup(const {}),
    );
    addTearDown(second.close);
    expect(File(layout.socketPath).existsSync(), isTrue);
  });
}
