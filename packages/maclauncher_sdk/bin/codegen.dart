// `dart run maclauncher_sdk:codegen`：把 maclauncher.json（schemaVersion 1）
// 直译为 Dart 常量文件。本文件只做文件读写与退出码；转换逻辑见
// lib/src/codegen/manifest_codegen.dart 的纯函数 generateManifestConstants。
import 'dart:io';

import 'package:maclauncher_sdk/src/codegen/manifest_codegen.dart';

// sysexits 风格退出码。
const int _exitUsage = 64; // 命令行用法错误
const int _exitData = 65; // 配置内容非法
const int _exitNoInput = 66; // 输入不可读

const String _usage = '''
Usage: dart run maclauncher_sdk:codegen [options]

Reads maclauncher.json (schemaVersion 1) and writes Dart manifest constants
(projectId, service ids and display names). The output contains no launch
entry and no assertion boilerplate (ADR 0005).

Options:
  -i, --input <path>   maclauncher.json path (default: ./maclauncher.json)
  -o, --output <path>  output file (default: ./lib/maclauncher_manifest.g.dart)
  -h, --help           show this help
''';

Future<void> main(List<String> args) async {
  var input = 'maclauncher.json';
  var output = 'lib/maclauncher_manifest.g.dart';

  for (var i = 0; i < args.length; i++) {
    final arg = args[i];
    // 先把每个参数解析成 (flag, value)，再统一按 flag 赋值。
    final String flag;
    final String? value;
    if (arg == '-h' || arg == '--help') {
      stdout.write(_usage);
      return;
    } else if (arg == '-i' || arg == '--input') {
      flag = 'input';
      value = ++i < args.length ? args[i] : null;
    } else if (arg == '-o' || arg == '--output') {
      flag = 'output';
      value = ++i < args.length ? args[i] : null;
    } else if (arg.startsWith('--input=')) {
      flag = 'input';
      value = arg.substring('--input='.length);
    } else if (arg.startsWith('--output=')) {
      flag = 'output';
      value = arg.substring('--output='.length);
    } else {
      stderr.writeln('codegen: unknown argument: $arg');
      stderr.write(_usage);
      exitCode = _exitUsage;
      return;
    }
    if (value == null || value.isEmpty) {
      stderr.writeln('codegen: missing value for $arg');
      stderr.write(_usage);
      exitCode = _exitUsage;
      return;
    }
    if (flag == 'input') {
      input = value;
    } else {
      output = value;
    }
  }

  final String source;
  try {
    source = await File(input).readAsString();
  } on FileSystemException catch (e) {
    stderr.writeln('codegen: cannot read $input: ${e.message}');
    exitCode = _exitNoInput;
    return;
  }

  final String dartSource;
  try {
    dartSource = generateManifestConstants(source);
  } on ManifestCodegenException catch (e) {
    stderr.writeln('codegen: $input: ${e.message}');
    exitCode = _exitData;
    return;
  }

  final outFile = File(output);
  try {
    await outFile.parent.create(recursive: true);
    await outFile.writeAsString(dartSource);
  } on FileSystemException catch (e) {
    stderr.writeln('codegen: cannot write $output: ${e.message}');
    exitCode = _exitNoInput;
    return;
  }
  stdout.writeln('codegen: wrote $output');
}
