import 'dart:convert';
import 'dart:io';

import 'binding_lookup.dart';
import 'manifest.dart';

/// A registered association between a project and its manifest, kept in the
/// launcher's own local storage. Never written back into the project
/// configuration.
class ProjectBinding {
  const ProjectBinding({
    required this.projectId,
    required this.name,
    required this.manifestPath,
    required this.services,
    required this.boundAt,
  });

  final String projectId;
  final String name;

  /// Canonical absolute path of the associated maclauncher.json.
  final String manifestPath;

  final List<ManifestService> services;
  final DateTime boundAt;

  Map<String, Object?> toJson() => {
    'projectId': projectId,
    'name': name,
    'manifestPath': manifestPath,
    'services': [for (final s in services) s.toJson()],
    'boundAt': boundAt.toUtc().toIso8601String(),
  };

  static ProjectBinding fromJson(Map<String, Object?> json) => ProjectBinding(
    projectId: json['projectId'] as String? ?? '',
    name: json['name'] as String? ?? '',
    manifestPath: json['manifestPath'] as String? ?? '',
    services: [
      for (final s in (json['services'] as List? ?? const []))
        ManifestService.fromJson((s as Map).cast<String, Object?>()),
    ],
    boundAt:
        DateTime.tryParse(json['boundAt'] as String? ?? '')?.toUtc() ??
        DateTime.fromMillisecondsSinceEpoch(0, isUtc: true),
  );
}

/// Local, launcher-owned store of project bindings.
class BindingStore implements BindingLookup {
  BindingStore._(this._file, this._bindings);

  final File _file;
  final List<ProjectBinding> _bindings;

  static Future<BindingStore> load(String filePath) async {
    final file = File(filePath);
    if (!file.existsSync()) {
      return BindingStore._(file, []);
    }
    final decoded = jsonDecode(await file.readAsString());
    final list = (decoded as List)
        .map((e) => ProjectBinding.fromJson((e as Map).cast<String, Object?>()))
        .toList();
    return BindingStore._(file, list);
  }

  List<ProjectBinding> get bindings => List.unmodifiable(_bindings);

  ProjectBinding? byProjectId(String projectId) {
    for (final binding in _bindings) {
      if (binding.projectId == projectId) return binding;
    }
    return null;
  }

  ProjectBinding? byManifestPath(String manifestPath) {
    final canonical = _canonical(manifestPath);
    for (final binding in _bindings) {
      if (binding.manifestPath == canonical) return binding;
    }
    return null;
  }

  /// Associates the manifest at [manifestPath].
  ///
  /// Re-associating the same configuration reuses the existing record: no
  /// duplicate project, preferences preserved. Throws [ManifestException]
  /// with the concrete reason when the configuration is unusable; no binding
  /// is created or modified in that case.
  Future<ProjectBinding> associate(String manifestPath) async {
    final canonical = _canonical(manifestPath);
    final existing = byManifestPath(canonical);
    final manifest = await ProjectManifest.read(canonical);

    if (existing != null) {
      if (existing.projectId != manifest.projectId) {
        // Same path now declares a different identity; conflict resolution
        // (migrate vs. new project) is handled by the identity feature.
        throw ManifestException(
          ManifestRejection.invalidStructure,
          'path already bound to project ${existing.projectId}',
        );
      }
      return existing;
    }
    final byId = byProjectId(manifest.projectId);
    if (byId != null) {
      // Same project identity arriving from another path: the user must
      // choose migration or a new project (identity feature). Never create
      // two bindings with the same identity.
      throw ManifestException(
        ManifestRejection.invalidStructure,
        'project identity already bound at ${byId.manifestPath}',
      );
    }

    final binding = ProjectBinding(
      projectId: manifest.projectId,
      name: manifest.projectName,
      manifestPath: canonical,
      services: manifest.services,
      boundAt: DateTime.now().toUtc(),
    );
    _bindings.add(binding);
    await _save();
    return binding;
  }

  Future<void> _save() async {
    await _file.parent.create(recursive: true);
    final tmp = File('${_file.path}.tmp');
    await tmp.writeAsString(
      const JsonEncoder.withIndent('  ')
          .convert([for (final b in _bindings) b.toJson()]),
      flush: true,
    );
    await tmp.rename(_file.path);
    final result = await Process.run('chmod', ['600', _file.path]);
    if (result.exitCode != 0) {
      throw StateError('chmod 600 ${_file.path} failed: ${result.stderr}');
    }
  }

  static String _canonical(String path) {
    final absolute = File(path).absolute.path;
    try {
      return File(absolute).resolveSymbolicLinksSync();
    } catch (_) {
      return absolute;
    }
  }

  @override
  bool isKnownProject(String projectId) => byProjectId(projectId) != null;
}
