import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'binding_store.dart';
import 'manifest.dart';

/// Why an association cannot be applied silently and needs a user choice.
enum AssociationConflictKind {
  /// The incoming project identity is already bound at another path: the
  /// project was moved or copied. The user chooses migration or a new
  /// project; two bindings never share one identity.
  identityBoundToOtherPath,

  /// The path is already bound to another identity: the directory now hosts
  /// a different project. Never silently swap the binding's identity.
  pathBoundToOtherIdentity,
}

/// Structured outcome of an association attempt, so the UI can act on
/// conflicts instead of catching errors.
sealed class AssociationResult {
  const AssociationResult();
}

/// A new binding was created.
class AssociationCreated extends AssociationResult {
  const AssociationCreated(this.binding);

  final ProjectBinding binding;
}

/// The same configuration was associated again; the existing record is
/// reused, preferences preserved.
class AssociationReused extends AssociationResult {
  const AssociationReused(this.binding);

  final ProjectBinding binding;
}

/// A same-identity or same-path collision that only the user may resolve.
/// Nothing in the store was modified.
class AssociationConflict extends AssociationResult {
  const AssociationConflict({
    required this.kind,
    required this.existingBinding,
    required this.incomingManifest,
    required this.incomingManifestPath,
  });

  final AssociationConflictKind kind;

  /// The binding that blocks the association.
  final ProjectBinding existingBinding;

  /// The validated manifest that could not be associated.
  final ProjectManifest incomingManifest;

  /// Canonical path of the incoming manifest.
  final String incomingManifestPath;
}

/// The user-facing association flow: collisions become structured results,
/// and the two resolutions (migration, new project) are explicit methods.
class AssociationFlow {
  AssociationFlow(this._store);

  final BindingStore _store;

  /// Associates the manifest at [manifestPath], surfacing conflicts as
  /// [AssociationConflict] instead of throwing. Invalid manifests still
  /// throw [ManifestException]; no outcome other than [AssociationCreated]
  /// mutates the store.
  Future<AssociationResult> associate(String manifestPath) async {
    final canonical = BindingStore.canonicalPath(manifestPath);
    // Read and validate first: rejections never touch the store.
    final manifest = await ProjectManifest.read(canonical);

    final byPath = _store.byManifestPath(canonical);
    if (byPath != null) {
      if (byPath.projectId == manifest.projectId) {
        return AssociationReused(byPath);
      }
      return AssociationConflict(
        kind: AssociationConflictKind.pathBoundToOtherIdentity,
        existingBinding: byPath,
        incomingManifest: manifest,
        incomingManifestPath: canonical,
      );
    }
    final byId = _store.byProjectId(manifest.projectId);
    if (byId != null) {
      return AssociationConflict(
        kind: AssociationConflictKind.identityBoundToOtherPath,
        existingBinding: byId,
        incomingManifest: manifest,
        incomingManifestPath: canonical,
      );
    }

    final binding = ProjectBinding(
      projectId: manifest.projectId,
      name: manifest.projectName,
      manifestPath: canonical,
      services: manifest.services,
      boundAt: DateTime.now().toUtc(),
    );
    return AssociationCreated(await _store.insert(binding));
  }

  /// Migration resolution: the binding keeps its project identity and
  /// [ProjectBinding.boundAt] (preferences hang off that stable record) and
  /// now points at [newManifestPath]. The manifest at the new path is
  /// re-read and validated; it must declare the same identity. Afterwards
  /// the old path no longer resolves to the binding.
  ///
  /// Throws [StateError] when no binding exists for [projectId], and
  /// [ManifestException] when the new manifest is unusable, declares a
  /// different identity, or its path is bound to another project. No failure
  /// mutates the store.
  Future<ProjectBinding> migrateBinding(
    String projectId,
    String newManifestPath,
  ) async {
    final existing = _store.byProjectId(projectId);
    if (existing == null) {
      throw StateError('no binding for project identity: $projectId');
    }
    final canonical = BindingStore.canonicalPath(newManifestPath);
    final manifest = await ProjectManifest.read(canonical);
    if (manifest.projectId != projectId) {
      throw ManifestException(
        ManifestRejection.invalidStructure,
        'migration requires the same project identity: '
        'expected $projectId, got ${manifest.projectId}',
      );
    }
    final occupying = _store.byManifestPath(canonical);
    if (occupying != null && occupying.projectId != projectId) {
      throw ManifestException(
        ManifestRejection.invalidStructure,
        'path already bound to project ${occupying.projectId}',
      );
    }

    return _store.replace(
      ProjectBinding(
        projectId: projectId,
        name: manifest.projectName,
        manifestPath: canonical,
        services: manifest.services,
        boundAt: existing.boundAt,
      ),
    );
  }

  /// New-project resolution: rewrites ONLY `project.id` inside the incoming
  /// manifest with a fresh stable identity — an explicit one-time user
  /// choice, distinct from the never-write-back rule for preferences — then
  /// associates it as an independent binding. The generated identity is
  /// guaranteed unique against all existing bindings.
  ///
  /// Throws [StateError] when the path is already bound (resolve the path
  /// conflict first) and [ManifestException] when the manifest is unusable.
  Future<ProjectBinding> associateAsNewProject(
    String incomingManifestPath,
  ) async {
    final canonical = BindingStore.canonicalPath(incomingManifestPath);
    if (_store.byManifestPath(canonical) != null) {
      throw StateError('path already bound; resolve the path conflict first');
    }
    // Validate before rewriting: an unusable manifest is never modified.
    await ProjectManifest.read(canonical);

    String newId;
    do {
      newId = generateProjectId();
    } while (_store.byProjectId(newId) != null);

    await rewriteProjectId(canonical, newId);

    // Re-read the rewritten file so the binding reflects what is on disk.
    final manifest = await ProjectManifest.read(canonical);
    final binding = ProjectBinding(
      projectId: newId,
      name: manifest.projectName,
      manifestPath: canonical,
      services: manifest.services,
      boundAt: DateTime.now().toUtc(),
    );
    return _store.insert(binding);
  }
}

/// Generates a fresh stable project identity (UUIDv4 shape).
String generateProjectId() {
  final rand = Random.secure();
  final bytes = List<int>.generate(16, (_) => rand.nextInt(256));
  bytes[6] = (bytes[6] & 0x0F) | 0x40; // version 4
  bytes[8] = (bytes[8] & 0x3F) | 0x80; // variant 10
  final h = bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  return '${h.substring(0, 8)}-${h.substring(8, 12)}-${h.substring(12, 16)}-'
      '${h.substring(16, 20)}-${h.substring(20)}';
}

/// Rewrites ONLY `project.id` in the manifest at [canonicalPath] to
/// [newProjectId], preserving every other field and, where practical, the
/// original formatting. Falls back to a full re-encode (field order
/// preserved) when the surgical edit cannot locate the id value, e.g. when
/// it contains escaped characters.
///
/// The write is atomic (temp file + rename, original permission bits
/// preserved): this is the user's manifest, a torn write must never leave
/// it unreadable.
Future<void> rewriteProjectId(String canonicalPath, String newProjectId) async {
  final file = File(canonicalPath);
  final source = await file.readAsString();
  final manifest = ProjectManifest.parse(source);

  final projectStart = RegExp('"project"\\s*:\\s*\\{').firstMatch(source);
  if (projectStart != null) {
    final idPattern = RegExp(
      '("id"\\s*:\\s*)"${RegExp.escape(manifest.projectId)}"',
    );
    final idMatch = idPattern.firstMatch(source.substring(projectStart.end));
    if (idMatch != null) {
      final start = projectStart.end + idMatch.start;
      final end = projectStart.end + idMatch.end;
      await _atomicRewrite(
        file,
        source.replaceRange(
          start,
          end,
          '${idMatch[1]}${jsonEncode(newProjectId)}',
        ),
      );
      return;
    }
  }

  // Fallback: ordered re-encode with only project.id changed.
  final decoded = (jsonDecode(source) as Map).cast<String, Object?>();
  final project = (decoded['project'] as Map).cast<String, Object?>();
  project['id'] = newProjectId;
  await _atomicRewrite(
    file,
    const JsonEncoder.withIndent('  ').convert(decoded),
  );
}

/// Writes [content] to [file] atomically: temp sibling + rename, keeping
/// the original file's permission bits on the replacement.
Future<void> _atomicRewrite(File file, String content) async {
  final originalMode = (await file.stat()).mode;
  final tmp = File('${file.path}.rewrite-tmp');
  await tmp.writeAsString(content, flush: true);
  final chmod = await Process.run('chmod', [
    (originalMode & 0xFFF).toRadixString(8),
    tmp.path,
  ]);
  if (chmod.exitCode != 0) {
    await tmp.delete().then((_) {}, onError: (_) {});
    throw StateError('chmod ${tmp.path} failed: ${chmod.stderr}');
  }
  await tmp.rename(file.path);
}
