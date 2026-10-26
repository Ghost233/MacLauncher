import 'dart:convert';

/// The only manifest schema version this generator understands.
const int kManifestSchemaVersion = 1;

/// Why codegen failed. The [message] is printed to stderr by the bin
/// command; every failure is a build-time config error with a readable
/// reason, never a silent fallback.
class ManifestCodegenException implements Exception {
  ManifestCodegenException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// Pure seam of the codegen command: translates `maclauncher.json` text
/// (schemaVersion 1) into Dart source defining the manifest constants
/// (`maclauncherProjectId`, `maclauncherServices`).
///
/// The output deliberately contains no launch entry (unknown at build time;
/// inferred at runtime via `SdkEntry.currentAppBundle()`) and no assertion
/// boilerplate — drift is caught by the dev-time handshake consistency
/// check (ADR 0005).
///
/// Throws [ManifestCodegenException] with a readable reason on invalid
/// JSON, unknown schemaVersion, or missing required fields.
String generateManifestConstants(String jsonText) {
  final Object? decoded;
  try {
    decoded = jsonDecode(jsonText);
  } on FormatException catch (e) {
    throw ManifestCodegenException('invalid JSON: $e');
  }
  if (decoded is! Map) {
    throw ManifestCodegenException('top level must be an object');
  }
  final json = decoded.cast<String, Object?>();

  final version = json['schemaVersion'];
  if (version != kManifestSchemaVersion) {
    throw ManifestCodegenException(
      'unknown schemaVersion: $version (expected $kManifestSchemaVersion)',
    );
  }

  final project = switch (json['project']) {
    null => const <String, Object?>{},
    final Map m => m.cast<String, Object?>(),
    _ => throw ManifestCodegenException('project must be an object'),
  };
  final projectId = switch (project['id']) {
    null => '',
    final String s => s,
    _ => throw ManifestCodegenException('project.id must be a string'),
  };
  if (projectId.isEmpty) {
    throw ManifestCodegenException('project.id is required (non-empty string)');
  }
  // '@'-prefixed top-level keys are reserved for launcher-level
  // preferences; such an id can never be bound, so fail at build time.
  if (projectId.startsWith('@')) {
    throw ManifestCodegenException(
      "project.id must not start with '@' (reserved by launcher preferences)",
    );
  }

  final rawServices = json['services'];
  if (rawServices is! List) {
    throw ManifestCodegenException('services is required (list of objects)');
  }
  final services = <String, String>{};
  for (final raw in rawServices) {
    if (raw is! Map) {
      throw ManifestCodegenException('service entries must be objects');
    }
    final entry = raw.cast<String, Object?>();
    final id = switch (entry['id']) {
      null => '',
      final String s => s,
      _ => throw ManifestCodegenException('service id must be a string'),
    };
    if (id.isEmpty) {
      throw ManifestCodegenException('every service needs a non-empty id');
    }
    final name = switch (entry['name']) {
      null => '',
      final String s => s,
      _ => throw ManifestCodegenException(
        'service "$id" name must be a string',
      ),
    };
    if (name.isEmpty) {
      throw ManifestCodegenException(
        'service "$id" needs a non-empty name (display name)',
      );
    }
    if (services.containsKey(id)) {
      throw ManifestCodegenException('duplicate service id: $id');
    }
    services[id] = name;
  }

  final buffer = StringBuffer()
    ..writeln('// GENERATED CODE — DO NOT EDIT.')
    ..writeln('// Source: maclauncher.json (schemaVersion 1).')
    ..writeln('// Regenerate: dart run maclauncher_sdk:codegen')
    ..writeln()
    ..writeln('/// 项目标识：maclauncher.json 的 project.id。')
    ..writeln('const String maclauncherProjectId = ${_dartString(projectId)};')
    ..writeln()
    ..writeln('/// 服务清单：服务 id → 显示名。');
  if (services.isEmpty) {
    buffer.writeln('const Map<String, String> maclauncherServices = {};');
    return buffer.toString();
  }
  buffer.writeln('const Map<String, String> maclauncherServices = {');
  for (final entry in services.entries) {
    buffer.writeln('  ${_dartString(entry.key)}: ${_dartString(entry.value)},');
  }
  buffer.writeln('};');
  return buffer.toString();
}

/// Renders [value] as a single-quoted Dart string literal, escaping the
/// characters that would otherwise terminate the literal, start an
/// interpolation, or be illegal raw control characters.
String _dartString(String value) {
  final buffer = StringBuffer("'");
  for (final rune in value.runes) {
    switch (rune) {
      case 0x5C: // backslash
        buffer.write(r'\\');
      case 0x27: // single quote
        buffer.write(r"\'");
      case 0x24: // dollar
        buffer.write(r'\$');
      case 0x0A:
        buffer.write(r'\n');
      case 0x0D:
        buffer.write(r'\r');
      case 0x09:
        buffer.write(r'\t');
      default:
        if (rune < 0x20 || rune == 0x7F) {
          buffer.write('\\u{${rune.toRadixString(16)}}');
        } else {
          buffer.writeCharCode(rune);
        }
    }
  }
  buffer.write("'");
  return buffer.toString();
}
