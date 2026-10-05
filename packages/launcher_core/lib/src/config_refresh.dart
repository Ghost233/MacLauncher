import 'dart:convert';
import 'dart:io';

import 'binding_store.dart';
import 'manifest.dart';
import 'storage_corruption.dart';

/// Outcome of re-reading one binding's manifest.
sealed class RefreshResult {
  const RefreshResult();
}

/// The re-read manifest was valid and the binding record now reflects it.
class RefreshApplied extends RefreshResult {
  const RefreshApplied({
    required this.added,
    required this.removed,
    required this.nameChanged,
  });

  /// Newly declared services.
  final List<ManifestService> added;

  /// Services whose declaration disappeared. Their records are retained as
  /// read-only (removal never proves a run terminated); they simply stop
  /// being start/recycle/notification targets.
  final List<ManifestService> removed;

  final bool nameChanged;
}

/// The manifest still says exactly what the binding already records.
class RefreshUnchanged extends RefreshResult {
  const RefreshUnchanged();
}

/// The manifest is missing, unreadable or invalid. The binding, its last
/// valid display data and every confirmed run record are KEPT — a broken
/// configuration never deletes a binding, never prunes a preference and
/// never touches a running business. New starts stay paused until a valid
/// refresh clears the reason.
class RefreshInvalid extends RefreshResult {
  const RefreshInvalid(this.reason, this.detail);

  final ManifestRejection reason;
  final String detail;
}

/// The manifest at the bound path now declares a DIFFERENT project identity.
/// The binding is kept untouched; resolving this is the explicit
/// migrate/new-project flow, never an automatic rewrite.
class RefreshIdentityMismatch extends RefreshResult {
  const RefreshIdentityMismatch(this.declaredProjectId);

  final String declaredProjectId;
}

/// No binding exists for the requested project.
class RefreshNotBound extends RefreshResult {
  const RefreshNotBound();
}

/// Read-only record of a service whose declaration was removed. It remains
/// visible so users can tell "declaration removed" apart from "run
/// terminated"; while the app still offers the capability, status/logs stay
/// queryable through the operations layer.
class RetainedService {
  const RetainedService({
    required this.id,
    required this.name,
    required this.removedAt,
  });

  final String id;
  final String name;
  final DateTime removedAt;

  Map<String, Object?> toJson() => {
    'id': id,
    'name': name,
    'removedAt': removedAt.toUtc().toIso8601String(),
  };

  static RetainedService fromJson(Map<String, Object?> json) => RetainedService(
    id: json['id'] as String? ?? '',
    name: json['name'] as String? ?? '',
    removedAt:
        DateTime.tryParse(json['removedAt'] as String? ?? '')?.toUtc() ??
        DateTime.fromMillisecondsSinceEpoch(0, isUtc: true),
  );
}

/// Re-reads project manifests and applies configuration changes to the
/// binding store.
///
/// Pure metadata maintenance: it holds no reference to operations, sessions
/// or the registry, so a refresh — including one that observes UNKNOWN or
/// failed service states — can never auto-start, auto-recycle or otherwise
/// touch a running business. Fixing a configuration restores start
/// eligibility; it never triggers an implicit recycle or restart.
///
/// Preferences integration is injected: [prunePreferences] receives the
/// removed service ids after an applied refresh. Note the autostart path
/// already filters out declarations that disappeared, so a conservative
/// adapter may keep preferences intact against accidental edits.
class ConfigRefresher {
  ConfigRefresher._(
    this._store,
    this._stateFile,
    this._prunePreferences,
    this._invalid,
    this._retained,
    this.corruptionReport,
  );

  final BindingStore _store;
  final File _stateFile;
  final Future<void> Function(String projectId, Set<String> removedServiceIds)?
  _prunePreferences;

  /// projectId → why its manifest is currently unusable.
  final Map<String, RefreshInvalid> _invalid;

  /// projectId → retained read-only records of removed services.
  final Map<String, List<RetainedService>> _retained;

  /// Damage found while loading, or null when the file was fully healthy.
  final StorageCorruptionReport? corruptionReport;

  /// Loads the refresh state, tolerating damage: unparseable JSON or a
  /// non-map top level moves the original aside to `.corrupt-<timestamp>`
  /// and starts empty; individually invalid entries are skipped while good
  /// entries load normally. Either shape is exposed via
  /// [corruptionReport]; loading never throws for damaged content.
  static Future<ConfigRefresher> load(
    BindingStore store,
    String stateFilePath, {
    Future<void> Function(String projectId, Set<String> removedServiceIds)?
    prunePreferences,
  }) async {
    final file = File(stateFilePath);
    final invalid = <String, RefreshInvalid>{};
    final retained = <String, List<RetainedService>>{};
    StorageCorruptionReport? report;
    if (file.existsSync()) {
      Object? decoded;
      try {
        decoded = jsonDecode(await file.readAsString());
      } on FormatException {
        decoded = null;
      }
      if (decoded is! Map) {
        report = StorageCorruptionReport(
          filePath: file.path,
          backupPath: file.existsSync()
              ? await backupCorruptedFile(file)
              : null,
          skippedRecords: 0,
        );
      } else {
        var skipped = 0;
        final map = decoded.cast<String, Object?>();
        for (final entry
            in (map['invalid'] as Map? ?? {}).cast<String, Object?>().entries) {
          if (entry.value is! Map) {
            skipped++;
            continue;
          }
          final value = (entry.value! as Map).cast<String, Object?>();
          invalid[entry.key] = RefreshInvalid(
            ManifestRejection.values.asNameMap()[value['reason']] ??
                ManifestRejection.invalidStructure,
            value['detail'] as String? ?? '',
          );
        }
        for (final entry
            in (map['retained'] as Map? ?? {})
                .cast<String, Object?>()
                .entries) {
          if (entry.value is! List) {
            skipped++;
            continue;
          }
          final services = <RetainedService>[];
          for (final element in entry.value! as List) {
            if (element is! Map) {
              skipped++;
              continue;
            }
            try {
              services.add(
                RetainedService.fromJson(element.cast<String, Object?>()),
              );
            } catch (_) {
              skipped++;
            }
          }
          if (services.isNotEmpty) retained[entry.key] = services;
        }
        if (skipped > 0) {
          report = StorageCorruptionReport(
            filePath: file.path,
            backupPath: null,
            skippedRecords: skipped,
          );
        }
      }
    }
    return ConfigRefresher._(
      store,
      file,
      prunePreferences,
      invalid,
      retained,
      report,
    );
  }

  /// Why [projectId]'s manifest is currently unusable, or null when valid.
  RefreshInvalid? invalidReason(String projectId) => _invalid[projectId];

  /// Read-only records of services removed from the declaration.
  List<RetainedService> retainedServices(String projectId) =>
      List.unmodifiable(_retained[projectId] ?? const []);

  /// Re-reads and applies the manifest for one bound project.
  Future<RefreshResult> refresh(String projectId) async {
    final binding = _store.byProjectId(projectId);
    if (binding == null) return const RefreshNotBound();

    final ProjectManifest manifest;
    try {
      manifest = await ProjectManifest.read(binding.manifestPath);
    } on ManifestException catch (e) {
      final result = RefreshInvalid(e.reason, e.detail);
      _invalid[projectId] = result;
      await _saveState();
      return result;
    }

    if (manifest.projectId != projectId) {
      // Identity drift is not an "edit": keep everything, surface for the
      // explicit migration/new-project choice.
      return RefreshIdentityMismatch(manifest.projectId);
    }

    final oldById = {for (final s in binding.services) s.id: s};
    final newById = {for (final s in manifest.services) s.id: s};
    final added = [
      for (final s in manifest.services)
        if (!oldById.containsKey(s.id)) s,
    ];
    final removed = [
      for (final s in binding.services)
        if (!newById.containsKey(s.id)) s,
    ];
    final nameChanged = manifest.projectName != binding.name;

    if (added.isEmpty && removed.isEmpty && !nameChanged) {
      // A previously invalid configuration that now matches the binding is
      // valid again: clear the reason, nothing else changes.
      if (_invalid.remove(projectId) != null) await _saveState();
      return const RefreshUnchanged();
    }

    await _store.replace(
      ProjectBinding(
        projectId: binding.projectId,
        name: manifest.projectName,
        manifestPath: binding.manifestPath,
        services: manifest.services,
        // The stable record: preferences and run history hang off it.
        boundAt: binding.boundAt,
      ),
    );

    var retainedChanged = false;
    if (removed.isNotEmpty) {
      final retained = _retained.putIfAbsent(projectId, () => []);
      for (final service in removed) {
        if (!retained.any((r) => r.id == service.id)) {
          retained.add(
            RetainedService(
              id: service.id,
              name: service.name,
              removedAt: DateTime.now().toUtc(),
            ),
          );
          retainedChanged = true;
        }
      }
      await _prunePreferences?.call(projectId, {for (final s in removed) s.id});
    }
    if (added.isNotEmpty) {
      // A service that comes back is a live declaration again, not a
      // read-only leftover.
      final retained = _retained[projectId];
      if (retained != null) {
        final before = retained.length;
        retained.removeWhere((r) => added.any((a) => a.id == r.id));
        retainedChanged = retainedChanged || retained.length != before;
      }
    }
    final hadInvalid = _invalid.remove(projectId) != null;
    if (hadInvalid || retainedChanged) await _saveState();

    return RefreshApplied(
      added: added,
      removed: removed,
      nameChanged: nameChanged,
    );
  }

  /// Refreshes every binding, keyed by project identity.
  Future<Map<String, RefreshResult>> refreshAll() async {
    final results = <String, RefreshResult>{};
    for (final binding in _store.bindings) {
      results[binding.projectId] = await refresh(binding.projectId);
    }
    return results;
  }

  Future<void> _saveState() async {
    await _stateFile.parent.create(recursive: true);
    final tmp = File('${_stateFile.path}.tmp');
    await tmp.writeAsString(
      const JsonEncoder.withIndent('  ').convert({
        'invalid': {
          for (final entry in _invalid.entries)
            entry.key: {
              'reason': entry.value.reason.name,
              'detail': entry.value.detail,
            },
        },
        'retained': {
          for (final entry in _retained.entries)
            if (entry.value.isNotEmpty)
              entry.key: [for (final s in entry.value) s.toJson()],
        },
      }),
      flush: true,
    );
    await tmp.rename(_stateFile.path);
    final result = await Process.run('chmod', ['600', _stateFile.path]);
    if (result.exitCode != 0) {
      throw StateError('chmod 600 ${_stateFile.path} failed: ${result.stderr}');
    }
  }
}
