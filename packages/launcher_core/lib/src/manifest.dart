import 'dart:convert';
import 'dart:io';

/// The fixed contract name users pick inside a project directory.
const String kManifestFileName = 'maclauncher.json';
const int kManifestSchemaVersion = 1;

/// Why a manifest cannot be used. Surfaced to the user as the concrete
/// reason; an invalid manifest never creates or replaces a binding.
enum ManifestRejection {
  unreadable,
  invalidJson,
  unknownVersion,
  invalidStructure,
  emptyProjectId,
  emptyServiceId,
  duplicateServiceId,
  reservedProjectId,
}

class ManifestException implements Exception {
  ManifestException(this.reason, this.detail);

  final ManifestRejection reason;
  final String detail;

  @override
  String toString() => '$reason: $detail';
}

class ManifestService {
  const ManifestService({required this.id, required this.name});

  /// Stable service identity, unique within the project.
  final String id;

  /// Display name only; never part of identity.
  final String name;

  Map<String, Object?> toJson() => {'id': id, 'name': name};

  static ManifestService fromJson(Map<String, Object?> json) => ManifestService(
    id: json['id'] as String? ?? '',
    name: json['name'] as String? ?? '',
  );
}

/// How the launcher may open the application when a start notification
/// arrives but no control entry is connected. Opening an entry never means
/// the business has started.
enum EntryKind { app, executable }

class ManifestEntry {
  const ManifestEntry({
    required this.kind,
    required this.path,
    this.args = const [],
    this.workingDirectory,
  });

  final EntryKind kind;

  /// App bundle path (kind=app) or executable program (kind=executable).
  /// Relative values resolve against the manifest's directory.
  final String path;

  /// Arguments for kind=executable. Opened detached, never via a shell.
  final List<String> args;

  /// Working directory for kind=executable; relative to the manifest
  /// directory when not absolute.
  final String? workingDirectory;

  Map<String, Object?> toJson() => {
    'kind': kind.name,
    'path': path,
    'args': args,
    if (workingDirectory != null) 'workingDirectory': workingDirectory,
  };

  static ManifestEntry fromJson(Map<String, Object?> json) {
    final kind = switch (json['kind']) {
      'app' => EntryKind.app,
      'executable' => EntryKind.executable,
      _ => throw ManifestException(
        ManifestRejection.invalidStructure,
        'entry.kind must be app or executable',
      ),
    };
    final path = (json['path'] ?? json['program']) as String? ?? '';
    if (path.isEmpty) {
      throw ManifestException(
        ManifestRejection.invalidStructure,
        'entry path/program is required',
      );
    }
    return ManifestEntry(
      kind: kind,
      path: path,
      args: [for (final a in (json['args'] as List? ?? const [])) '$a'],
      workingDirectory: json['workingDirectory'] as String?,
    );
  }
}

/// Parsed `maclauncher.json` (schemaVersion 1).
class ProjectManifest {
  const ProjectManifest({
    required this.projectId,
    required this.projectName,
    required this.services,
    this.entry,
    this.integrationType = 'sdk',
  });

  final String projectId;
  final String projectName;
  final List<ManifestService> services;
  final ManifestEntry? entry;
  final String integrationType;

  /// Parses and validates manifest text. Throws [ManifestException] with the
  /// concrete reason on any violation.
  static ProjectManifest parse(String source) {
    final Object? decoded;
    try {
      decoded = jsonDecode(source);
    } on FormatException catch (e) {
      throw ManifestException(ManifestRejection.invalidJson, '$e');
    }
    if (decoded is! Map) {
      throw ManifestException(
        ManifestRejection.invalidStructure,
        'top level must be an object',
      );
    }
    final json = decoded.cast<String, Object?>();

    final version = json['schemaVersion'];
    if (version != kManifestSchemaVersion) {
      throw ManifestException(
        ManifestRejection.unknownVersion,
        'schemaVersion: $version',
      );
    }

    final project = (json['project'] as Map?)?.cast<String, Object?>() ?? {};
    final projectId = project['id'] as String? ?? '';
    if (projectId.isEmpty) {
      throw ManifestException(
        ManifestRejection.emptyProjectId,
        'project.id is required',
      );
    }
    // PreferenceStore keys its map by project id and reserves '@'-prefixed
    // top-level keys (e.g. '@updates') for launcher-level preferences.
    if (projectId.startsWith('@')) {
      throw ManifestException(
        ManifestRejection.reservedProjectId,
        "project.id must not start with '@' (reserved for launcher-level keys)",
      );
    }

    final services = <ManifestService>[];
    final seen = <String>{};
    for (final raw in (json['services'] as List? ?? const [])) {
      if (raw is! Map) {
        throw ManifestException(
          ManifestRejection.invalidStructure,
          'service entries must be objects',
        );
      }
      final service = ManifestService.fromJson(raw.cast<String, Object?>());
      if (service.id.isEmpty) {
        throw ManifestException(
          ManifestRejection.emptyServiceId,
          'every service needs a non-empty id',
        );
      }
      if (!seen.add(service.id)) {
        throw ManifestException(
          ManifestRejection.duplicateServiceId,
          'duplicate service id: ${service.id}',
        );
      }
      services.add(service);
    }

    final integration =
        (json['integration'] as Map?)?.cast<String, Object?>() ?? {};
    final integrationType = integration['type'] as String? ?? 'sdk';

    final entryJson = (json['entry'] as Map?)?.cast<String, Object?>();
    return ProjectManifest(
      projectId: projectId,
      projectName: project['name'] as String? ?? projectId,
      services: services,
      entry: entryJson == null ? null : ManifestEntry.fromJson(entryJson),
      integrationType: integrationType,
    );
  }

  /// Reads and parses the manifest at [path].
  static Future<ProjectManifest> read(String path) async {
    final String source;
    try {
      source = await File(path).readAsString();
    } catch (e) {
      throw ManifestException(ManifestRejection.unreadable, '$e');
    }
    return parse(source);
  }
}
