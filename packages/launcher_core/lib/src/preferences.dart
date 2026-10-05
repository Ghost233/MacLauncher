import 'dart:convert';
import 'dart:io';

import 'storage_corruption.dart';

/// Launcher-local login-start preferences.
///
/// Preferences live in the launcher's own storage only — never written back
/// into project configuration. Recycling a running service never clears
/// them, and disabling a preference never stops a running business: this
/// store simply has no interaction with business operations.
class PreferenceStore {
  PreferenceStore._(this._file, this._prefs, this._updatePrefs,
      this.corruptionReport);

  /// Reserved top-level key for launcher-wide update preferences. Every
  /// other top-level key is a projectId; the '@' prefix keeps this key
  /// distinct from project-id keys.
  static const _updatesKey = '@updates';

  static const _keyCheckOnLaunch = 'checkOnLaunch';
  static const _keyAutoDownload = 'autoDownload';
  static const _keyAutoInstall = 'autoInstall';

  final File _file;

  /// projectId → serviceId → loginStart enabled.
  final Map<String, Map<String, bool>> _prefs;

  /// Launcher-wide update preferences; only explicitly set keys are stored.
  /// Keys absent from an old preference file fall back to their defaults.
  final Map<String, bool> _updatePrefs;

  /// Damage found while loading, or null when the file was fully healthy.
  final StorageCorruptionReport? corruptionReport;

  /// Loads the store, tolerating damage: unparseable JSON or a non-map top
  /// level moves the original aside to `.corrupt-<timestamp>` and starts
  /// empty; individually invalid entries are skipped while good entries
  /// load normally. Either shape is exposed via [corruptionReport];
  /// loading never throws for damaged content.
  static Future<PreferenceStore> load(String filePath) async {
    final file = File(filePath);
    if (!file.existsSync()) return PreferenceStore._(file, {}, {}, null);
    final Object? decoded;
    try {
      decoded = jsonDecode(await file.readAsString());
    } on FormatException {
      return PreferenceStore._(file, {}, {}, await _wholeFileCorruption(file));
    }
    if (decoded is! Map) {
      return PreferenceStore._(file, {}, {}, await _wholeFileCorruption(file));
    }
    final prefs = <String, Map<String, bool>>{};
    final updatePrefs = <String, bool>{};
    var skipped = 0;
    for (final entry in decoded.cast<String, Object?>().entries) {
      if (entry.value is! Map) {
        skipped++;
        continue;
      }
      final record = (entry.value! as Map).cast<String, Object?>();
      if (entry.key == _updatesKey) {
        for (final pref in record.entries) {
          if (pref.value is bool) updatePrefs[pref.key] = pref.value! as bool;
        }
        continue;
      }
      final services = <String, bool>{};
      for (final service in record.entries) {
        if (service.value == true) services[service.key] = true;
      }
      if (services.isNotEmpty) prefs[entry.key] = services;
    }
    return PreferenceStore._(
      file,
      prefs,
      updatePrefs,
      skipped > 0
          ? StorageCorruptionReport(
              filePath: file.path,
              backupPath: null,
              skippedRecords: skipped,
            )
          : null,
    );
  }

  static Future<StorageCorruptionReport> _wholeFileCorruption(
    File file,
  ) async => StorageCorruptionReport(
    filePath: file.path,
    backupPath: await backupCorruptedFile(file),
    skippedRecords: 0,
  );

  bool isLoginStartEnabled(String projectId, String serviceId) =>
      _prefs[projectId]?[serviceId] ?? false;

  /// Services with login start enabled for [projectId].
  Set<String> enabledServices(String projectId) =>
      Set.unmodifiable(_prefs[projectId]?.keys ?? const <String>{});

  /// Projects with any enabled service.
  Set<String> get projects => Set.unmodifiable(_prefs.keys);

  Future<void> setLoginStartEnabled(
    String projectId,
    String serviceId,
    bool enabled,
  ) async {
    if (enabled) {
      _prefs.putIfAbsent(projectId, () => {})[serviceId] = true;
    } else {
      final services = _prefs[projectId];
      if (services != null) {
        services.remove(serviceId);
        if (services.isEmpty) _prefs.remove(projectId);
      }
    }
    await _save();
  }

  /// Drops all preferences for a project (used by unbind).
  Future<void> removeProject(String projectId) async {
    if (_prefs.remove(projectId) != null) await _save();
  }

  // ---- launcher-wide update preferences ----
  // Defaults follow ADR 0002: check on launch is on, downloads stay manual,
  // and automatic install stays off until a signing certificate exists.

  /// Check for new versions when the launcher starts. Default: on.
  bool get updateCheckOnLaunch => _updatePrefs[_keyCheckOnLaunch] ?? true;

  /// Download new versions automatically. Default: off.
  bool get updateAutoDownload => _updatePrefs[_keyAutoDownload] ?? false;

  /// Reserved for automatic install (needs a signing certificate; not yet
  /// available). Default: off.
  bool get updateAutoInstall => _updatePrefs[_keyAutoInstall] ?? false;

  Future<void> setUpdateCheckOnLaunch(bool enabled) =>
      _setUpdatePreference(_keyCheckOnLaunch, enabled);

  Future<void> setUpdateAutoDownload(bool enabled) =>
      _setUpdatePreference(_keyAutoDownload, enabled);

  Future<void> setUpdateAutoInstall(bool enabled) =>
      _setUpdatePreference(_keyAutoInstall, enabled);

  Future<void> _setUpdatePreference(String key, bool value) async {
    final previous = _updatePrefs[key];
    _updatePrefs[key] = value;
    try {
      await _save();
    } catch (_) {
      // Keep the in-memory state consistent with what is on disk.
      if (previous == null) {
        _updatePrefs.remove(key);
      } else {
        _updatePrefs[key] = previous;
      }
      rethrow;
    }
  }

  Future<void> _save() async {
    await _file.parent.create(recursive: true);
    final tmp = File('${_file.path}.tmp');
    await tmp.writeAsString(
      const JsonEncoder.withIndent('  ').convert({
        if (_updatePrefs.isNotEmpty) _updatesKey: _updatePrefs,
        ..._prefs,
      }),
      flush: true,
    );
    await tmp.rename(_file.path);
    final result = await Process.run('chmod', ['600', _file.path]);
    if (result.exitCode != 0) {
      throw StateError('chmod 600 ${_file.path} failed: ${result.stderr}');
    }
  }
}
