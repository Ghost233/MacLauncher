import 'dart:convert';
import 'dart:io';

import 'package:maclauncher_sdk/maclauncher_sdk.dart';

import 'binding_lookup.dart';
import 'manifest.dart';
import 'storage_corruption.dart';

/// How a binding came to exist.
enum BindingOrigin {
  /// Associated from a `maclauncher.json` configuration file.
  config,

  /// Approved from a live runtime handshake (socket self-discovery); the
  /// project owns no configuration file.
  runtime,
}

/// A registered association between a project and its manifest, kept in the
/// launcher's own local storage. Never written back into the project
/// configuration.
class ProjectBinding {
  const ProjectBinding({
    required this.projectId,
    required this.name,
    this.manifestPath,
    required this.services,
    required this.boundAt,
    this.origin = BindingOrigin.config,
    this.learnedEntry,
  });

  final String projectId;
  final String name;

  /// Canonical absolute path of the associated maclauncher.json, or null for
  /// [BindingOrigin.runtime] bindings, which own no configuration file.
  final String? manifestPath;

  final List<ManifestService> services;
  final DateTime boundAt;

  /// How this binding was created. Records written before runtime discovery
  /// existed carry no `origin` field and load as [BindingOrigin.config].
  final BindingOrigin origin;

  /// Entry self-reported by the application over the handshake; only
  /// meaningful for [BindingOrigin.runtime] bindings. May be null even for a
  /// runtime binding: approval without an entry is allowed (observe/recycle
  /// only). Refreshed from later handshakes when the app moves on disk.
  final SdkEntry? learnedEntry;

  Map<String, Object?> toJson() => {
    'projectId': projectId,
    'name': name,
    'manifestPath': ?manifestPath,
    'origin': origin.name,
    'learnedEntry': ?learnedEntry?.toJson(),
    'services': [for (final s in services) s.toJson()],
    'boundAt': boundAt.toUtc().toIso8601String(),
  };

  static ProjectBinding fromJson(Map<String, Object?> json) {
    final rawPath = json['manifestPath'] as String?;
    final learned = json['learnedEntry'];
    return ProjectBinding(
      projectId: json['projectId'] as String? ?? '',
      name: json['name'] as String? ?? '',
      manifestPath: rawPath == null || rawPath.isEmpty ? null : rawPath,
      origin: json['origin'] == 'runtime'
          ? BindingOrigin.runtime
          : BindingOrigin.config,
      learnedEntry: learned is Map
          ? SdkEntry.fromJson(learned.cast<String, Object?>())
          : null,
      services: [
        for (final s in (json['services'] as List? ?? const []))
          ManifestService.fromJson((s as Map).cast<String, Object?>()),
      ],
      boundAt:
          DateTime.tryParse(json['boundAt'] as String? ?? '')?.toUtc() ??
          DateTime.fromMillisecondsSinceEpoch(0, isUtc: true),
    );
  }
}

/// Local, launcher-owned store of project bindings.
class BindingStore implements BindingLookup {
  BindingStore._(this._file, this._bindings, this.corruptionReport);

  final File _file;
  final List<ProjectBinding> _bindings;

  /// Damage found while loading, or null when the file was fully healthy.
  final StorageCorruptionReport? corruptionReport;

  /// Loads the store, tolerating damage: unparseable JSON or a non-list
  /// top level moves the original aside to `.corrupt-<timestamp>` and
  /// starts empty; individually invalid records are skipped while good
  /// records load normally. Either shape is exposed via
  /// [corruptionReport]; loading never throws for damaged content.
  static Future<BindingStore> load(String filePath) async {
    final file = File(filePath);
    if (!file.existsSync()) {
      return BindingStore._(file, [], null);
    }
    final decode = await decodeStoreFile(
      file,
      isValidTopLevel: (decoded) => decoded is List,
    );
    final wholeFileDamage = decode.wholeFileDamage;
    if (wholeFileDamage != null) {
      return BindingStore._(file, [], wholeFileDamage);
    }
    final bindings = <ProjectBinding>[];
    var skipped = 0;
    for (final element in decode.decoded! as List) {
      final binding = _tryParseBinding(element);
      if (binding == null) {
        skipped++;
      } else {
        bindings.add(binding);
      }
    }
    return BindingStore._(file, bindings, skippedRecordsReport(file, skipped));
  }

  /// A record is usable only when it parses and carries a project identity
  /// and — for config bindings — a manifest path; runtime bindings own no
  /// path by design. Anything less is damage, not a binding.
  static ProjectBinding? _tryParseBinding(Object? element) {
    try {
      if (element is! Map) return null;
      final binding = ProjectBinding.fromJson(element.cast<String, Object?>());
      if (binding.projectId.isEmpty) return null;
      if (binding.origin == BindingOrigin.config &&
          binding.manifestPath == null) {
        return null;
      }
      return binding;
    } catch (_) {
      return null;
    }
  }

  List<ProjectBinding> get bindings => List.unmodifiable(_bindings);

  /// Canonicalizes a manifest path for identity and path comparison.
  static String canonicalPath(String path) => _canonical(path);

  /// Low-level insert used by the association flow. Enforces the core
  /// invariants: no two bindings share a project identity, and no two
  /// bindings share a canonical manifest path. Throws [StateError] on any
  /// violation instead of silently duplicating.
  Future<ProjectBinding> insert(ProjectBinding binding) async {
    if (byProjectId(binding.projectId) != null) {
      throw StateError('duplicate project identity: ${binding.projectId}');
    }
    final path = binding.manifestPath;
    if (path != null && byManifestPath(path) != null) {
      throw StateError('duplicate manifest path: $path');
    }
    _bindings.add(binding);
    await _save();
    return binding;
  }

  /// Low-level replace used by migration: swaps the record for the same
  /// project identity. Throws [StateError] when no such identity exists.
  Future<ProjectBinding> replace(ProjectBinding binding) async {
    final index = _bindings.indexWhere((b) => b.projectId == binding.projectId);
    if (index < 0) {
      throw StateError('no binding for project identity: ${binding.projectId}');
    }
    _bindings[index] = binding;
    await _save();
    return binding;
  }

  /// Low-level removal used by the unbind flow: drops the record for the
  /// project identity. Throws [StateError] when no such identity exists.
  Future<void> remove(String projectId) async {
    final index = _bindings.indexWhere((b) => b.projectId == projectId);
    if (index < 0) {
      throw StateError('no binding for project identity: $projectId');
    }
    _bindings.removeAt(index);
    await _save();
  }

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
  ///
  /// Identity/path collisions throw here; the structured flow that surfaces
  /// them for user choice (migrate vs. new project) lives in
  /// `association.dart` (`AssociationFlow`).
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
        'project identity already bound at '
        '${byId.manifestPath ?? '(runtime binding, no manifest)'}',
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
