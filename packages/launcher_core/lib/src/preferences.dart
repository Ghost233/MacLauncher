import 'dart:convert';
import 'dart:io';

/// Launcher-local login-start preferences.
///
/// Preferences live in the launcher's own storage only — never written back
/// into project configuration. Recycling a running service never clears
/// them, and disabling a preference never stops a running business: this
/// store simply has no interaction with business operations.
class PreferenceStore {
  PreferenceStore._(this._file, this._prefs, this._updatePrefs);

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

  static Future<PreferenceStore> load(String filePath) async {
    final file = File(filePath);
    if (!file.existsSync()) return PreferenceStore._(file, {}, {});
    final decoded = jsonDecode(await file.readAsString());
    final prefs = <String, Map<String, bool>>{};
    final updatePrefs = <String, bool>{};
    for (final entry in (decoded as Map).cast<String, Object?>().entries) {
      if (entry.key == _updatesKey) {
        for (final pref
            in (entry.value as Map).cast<String, Object?>().entries) {
          if (pref.value is bool) updatePrefs[pref.key] = pref.value! as bool;
        }
        continue;
      }
      final services = <String, bool>{};
      for (final service
          in (entry.value as Map).cast<String, Object?>().entries) {
        if (service.value == true) services[service.key] = true;
      }
      if (services.isNotEmpty) prefs[entry.key] = services;
    }
    return PreferenceStore._(file, prefs, updatePrefs);
  }

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
    _updatePrefs[key] = value;
    await _save();
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
