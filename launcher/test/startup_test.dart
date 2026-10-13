import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maclauncher/main.dart' as launcher;

import 'launcher_test_harness.dart';

class _BlockedStartupFile implements File {
  final read = Completer<String>();
  bool readStarted = false;

  @override
  bool existsSync() => true;

  @override
  Future<String> readAsString({Encoding encoding = utf8}) {
    readStarted = true;
    return read.future;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnsupportedError('Unexpected file operation: $invocation');
}

void main() {
  testWidgets('cold startup paints a page while storage is still loading', (
    tester,
  ) async {
    final blockedFile = _BlockedStartupFile();
    unawaited(
      IOOverrides.runZoned(launcher.main, createFile: (_) => blockedFile),
    );
    await tester.pump();

    // Exercise the real entry point with unfinished I/O. A visible Scaffold
    // means Flutter has content to paint instead of the native black surface.
    try {
      expect(blockedFile.readStarted, isTrue);
      expect(blockedFile.read.isCompleted, isFalse);
      expect(find.byType(Scaffold), findsOneWidget);
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      expect(find.text('正在启动…'), findsOneWidget);
    } finally {
      blockedFile.read.completeError(
        const FileSystemException('startup test read failure'),
      );
      await tester.pump();
    }

    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(find.textContaining('启动失败：'), findsOneWidget);
    expect(find.textContaining('startup test read failure'), findsOneWidget);
  });

  testWidgets('completed startup replaces loading with the management page', (
    tester,
  ) async {
    final harness = (await tester.runAsync(LauncherTestHarness.create))!;
    try {
      final initialization = Completer<launcher.MacLauncherApp>();
      await tester.pumpWidget(
        launcher.LauncherStartupApp(initialization: initialization.future),
      );
      expect(find.text('正在启动…'), findsOneWidget);

      initialization.complete(harness.app());
      await tester.pump();
      expect(find.byType(launcher.ManagementPage), findsOneWidget);
      expect(find.text('正在启动…'), findsNothing);
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.runAsync(harness.dispose);
    }
  });
}
