// codegen 纯转换层测试：只测「JSON 文本 → Dart 源码文本」接缝的外部
// 行为，不碰文件系统、不启动进程。
import 'package:maclauncher_sdk/src/codegen/manifest_codegen.dart';
import 'package:test/test.dart';

void main() {
  group('合法清单', () {
    test('生成 projectId 与服务 id/显示名常量', () {
      final source = generateManifestConstants('''
{
  "schemaVersion": 1,
  "project": { "id": "demo-project", "name": "示例项目" },
  "services": [
    { "id": "demo", "name": "演示服务" },
    { "id": "worker", "name": "后台 worker" }
  ]
}
''');
      expect(
        source,
        contains("const String maclauncherProjectId = 'demo-project';"),
      );
      expect(source, contains("'demo': '演示服务'"));
      expect(source, contains("'worker': '后台 worker'"));
      // 顺序与配置一致。
      expect(source.indexOf("'demo'"), lessThan(source.indexOf("'worker'")));
    });

    test('entry 与未识别字段被忽略，产物不含拉起入口', () {
      final source = generateManifestConstants('''
{
  "schemaVersion": 1,
  "project": { "id": "demo-project", "name": "示例项目" },
  "services": [ { "id": "demo", "name": "演示服务" } ],
  "entry": { "kind": "executable", "path": "build/app" },
  "futureField": { "anything": true }
}
''');
      expect(source, contains("'demo-project'"));
      expect(source, isNot(contains('entry')));
      expect(source, isNot(contains('build/app')));
    });

    test('只产常量：不生成断言样板，projectName 不进入产物', () {
      final source = generateManifestConstants('''
{
  "schemaVersion": 1,
  "project": { "id": "demo-project", "name": "示例项目" },
  "services": [ { "id": "demo", "name": "演示服务" } ]
}
''');
      expect(source, isNot(contains('assert')));
      expect(source, isNot(contains('示例项目')));
    });

    test('特殊字符转义后仍是合法 Dart 字符串字面量', () {
      // JSON 解码后的显示名：a\tb$c\\d（\ 是单反斜杠，$ 是字面美元符）。
      final source = generateManifestConstants(r'''
{
  "schemaVersion": 1,
  "project": { "id": "it's", "name": "x" },
  "services": [ { "id": "demo", "name": "a\\tb$c\\\\d" } ]
}
''');
      expect(source, contains(r"const String maclauncherProjectId = 'it\'s';"));
      expect(source, contains(r"'demo': 'a\\tb\$c\\\\d'"));
    });

    test('空服务清单生成空 map', () {
      final source = generateManifestConstants('''
{
  "schemaVersion": 1,
  "project": { "id": "demo-project", "name": "示例项目" },
  "services": []
}
''');
      expect(
        source,
        contains('const Map<String, String> maclauncherServices = {};'),
      );
    });
  });

  group('失败分支', () {
    test('非法 JSON', () {
      expect(
        () => generateManifestConstants('{ not json'),
        throwsA(
          isA<ManifestCodegenException>().having(
            (e) => e.message,
            'message',
            contains('invalid JSON'),
          ),
        ),
      );
    });

    test('顶层不是对象', () {
      expect(
        () => generateManifestConstants('[1, 2]'),
        throwsA(
          isA<ManifestCodegenException>().having(
            (e) => e.message,
            'message',
            contains('top level must be an object'),
          ),
        ),
      );
    });

    test('未知 schemaVersion', () {
      for (final version in ['2', '"1"', 'null']) {
        final json =
            '{"schemaVersion": $version, "project": {"id": "p"}, "services": []}';
        expect(
          () => generateManifestConstants(json),
          throwsA(
            isA<ManifestCodegenException>().having(
              (e) => e.message,
              'message',
              contains('schemaVersion'),
            ),
          ),
          reason: 'schemaVersion=$version 应被拒绝',
        );
      }
    });

    test('缺失 schemaVersion', () {
      expect(
        () => generateManifestConstants(
          '{"project": {"id": "p"}, "services": []}',
        ),
        throwsA(isA<ManifestCodegenException>()),
      );
    });

    test('project.id 缺失或为空', () {
      for (final json in [
        '{"schemaVersion": 1, "services": []}',
        '{"schemaVersion": 1, "project": {}, "services": []}',
        '{"schemaVersion": 1, "project": {"id": ""}, "services": []}',
      ]) {
        expect(
          () => generateManifestConstants(json),
          throwsA(
            isA<ManifestCodegenException>().having(
              (e) => e.message,
              'message',
              contains('project.id'),
            ),
          ),
          reason: json,
        );
      }
    });

    test('project.id 以 @ 开头（启动器保留前缀）', () {
      expect(
        () => generateManifestConstants(
          '{"schemaVersion": 1, "project": {"id": "@reserved"}, "services": []}',
        ),
        throwsA(
          isA<ManifestCodegenException>().having(
            (e) => e.message,
            'message',
            contains('@'),
          ),
        ),
      );
    });

    test('services 缺失或不是列表', () {
      for (final json in [
        '{"schemaVersion": 1, "project": {"id": "p"}}',
        '{"schemaVersion": 1, "project": {"id": "p"}, "services": {}}',
      ]) {
        expect(
          () => generateManifestConstants(json),
          throwsA(
            isA<ManifestCodegenException>().having(
              (e) => e.message,
              'message',
              contains('services'),
            ),
          ),
          reason: json,
        );
      }
    });

    test('服务条目缺 id 或缺显示名', () {
      for (final service in [
        '{}',
        '{"name": "演示服务"}',
        '{"id": "", "name": "演示服务"}',
        '{"id": "demo"}',
        '{"id": "demo", "name": ""}',
      ]) {
        final json =
            '{"schemaVersion": 1, "project": {"id": "p"}, "services": [$service]}';
        expect(
          () => generateManifestConstants(json),
          throwsA(isA<ManifestCodegenException>()),
          reason: service,
        );
      }
    });

    test('重复服务 id', () {
      expect(
        () => generateManifestConstants('''
{
  "schemaVersion": 1,
  "project": { "id": "p" },
  "services": [
    { "id": "demo", "name": "甲" },
    { "id": "demo", "name": "乙" }
  ]
}
'''),
        throwsA(
          isA<ManifestCodegenException>().having(
            (e) => e.message,
            'message',
            contains('duplicate'),
          ),
        ),
      );
    });
  });
}
