import 'package:maclauncher_sdk/maclauncher_sdk.dart';
import 'package:test/test.dart';

void main() {
  group('SdkEntry 序列化', () {
    test('app bundle 往返', () {
      final entry = SdkEntry.appBundle('/Applications/Foo.app');
      final restored = SdkEntry.fromJson(entry.toJson());
      expect(restored, isNotNull);
      expect(restored!.kind, SdkEntryKind.app);
      expect(restored.path, '/Applications/Foo.app');
      expect(restored.args, isEmpty);
      expect(restored.workingDirectory, isNull);
    });

    test('executable 带 args 与 workingDirectory 往返', () {
      final entry = SdkEntry.executable(
        '/tmp/proj/run.sh',
        args: ['--serve', '8080'],
        workingDirectory: '/tmp/proj',
      );
      final restored = SdkEntry.fromJson(entry.toJson());
      expect(restored, isNotNull);
      expect(restored!.kind, SdkEntryKind.executable);
      expect(restored.path, '/tmp/proj/run.sh');
      expect(restored.args, ['--serve', '8080']);
      expect(restored.workingDirectory, '/tmp/proj');
    });

    test('空 args 与空 workingDirectory 不落盘', () {
      final json = SdkEntry.executable('/tmp/tool').toJson();
      expect(json.containsKey('args'), isFalse);
      expect(json.containsKey('workingDirectory'), isFalse);
    });

    test('非法结构返回 null', () {
      expect(SdkEntry.fromJson({}), isNull);
      expect(SdkEntry.fromJson({'kind': 'app'}), isNull);
      expect(SdkEntry.fromJson({'kind': 'app', 'path': ''}), isNull);
    });
  });

  group('SdkEntry.currentAppBundle 路径推导', () {
    test('.app 内的可执行路径推导出 bundle 路径', () {
      final entry = SdkEntry.currentAppBundle(
        resolvedExecutable: '/Applications/Foo.app/Contents/MacOS/Foo',
      );
      expect(entry, isNotNull);
      expect(entry!.kind, SdkEntryKind.app);
      expect(entry.path, '/Applications/Foo.app');
    });

    test('路径中含空格的 bundle 同样推导', () {
      final entry = SdkEntry.currentAppBundle(
        resolvedExecutable:
            '/Users/x/Build Products/Foo Bar.app/Contents/MacOS/Foo Bar',
      );
      expect(entry, isNotNull);
      expect(entry!.path, '/Users/x/Build Products/Foo Bar.app');
    });

    test('.app 外的可执行路径返回 null', () {
      expect(
        SdkEntry.currentAppBundle(resolvedExecutable: '/usr/local/bin/tool'),
        isNull,
      );
      expect(
        SdkEntry.currentAppBundle(
          resolvedExecutable: '/tmp/proj/build/minimal_app',
        ),
        isNull,
      );
    });

    test('路径开头即 .app 片段（无前缀）返回 null', () {
      expect(
        SdkEntry.currentAppBundle(
          resolvedExecutable: '.app/Contents/MacOS/Foo',
        ),
        isNull,
      );
    });
  });

  group('SdkEntry.currentExecutable', () {
    test('报告给定可执行路径与启动命令', () {
      final entry = SdkEntry.currentExecutable(
        resolvedExecutable: '/tmp/proj/tool',
        args: ['serve'],
        workingDirectory: '/tmp/proj',
      );
      expect(entry.kind, SdkEntryKind.executable);
      expect(entry.path, '/tmp/proj/tool');
      expect(entry.args, ['serve']);
      expect(entry.workingDirectory, '/tmp/proj');
    });
  });
}
