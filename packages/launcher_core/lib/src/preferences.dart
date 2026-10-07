import 'dart:convert';
import 'dart:io';

import 'storage_corruption.dart';

/// Launcher-local login-start, menu-bar and update preferences.
///
/// Preferences live in the launcher's own storage only — never written back
/// into project configuration. Recycling a running service never clears
/// them, and disabling a preference never stops a running business: this
/// store simply has no interaction with business operations.
class PreferenceStore {
  PreferenceStore._(
    this._file,
    this._prefs,
    this._updatePrefs,
    this._guidance,
    this._ignoredDiscovery,
    this._menuBarAllowed,
    this.corruptionReport,
  );

  /// Reserved top-level key for launcher-wide update preferences. Every
  /// other top-level key is a projectId; the '@' prefix keeps this key
  /// distinct from project-id keys.
  static const _updatesKey = '@updates';

  /// Reserved top-level key for one-shot launcher guidance flags (e.g. the
  /// invalid-config explainer is shown at most once).
  static const _guidanceKey = '@guidance';

  /// Reserved top-level key for runtime-discovery state (the ignore list).
  static const _discoveryKey = '@discovery';

  static const _menuBarKey = '@menuBar';

  static const _keyCheckOnLaunch = 'checkOnLaunch';
  static const _keyAutoDownload = 'autoDownload';
  static const _keyAutoInstall = 'autoInstall';

  static const _keyInvalidConfigGuidanceSeen = 'invalidConfigSeen';

  static const _keyIgnoredProjects = 'ignored';

  final File _file;

  /// projectId → serviceId → loginStart enabled.
  final Map<String, Map<String, bool>> _prefs;

  /// Launcher-wide update preferences; only explicitly set keys are stored.
  /// Keys absent from an old preference file fall back to their defaults.
  final Map<String, bool> _updatePrefs;

  /// One-shot guidance flags; absent keys fall back to their defaults.
  final Map<String, bool> _guidance;

  /// Discovery-ignored projectIds: rejected as unknown-project without
  /// ever surfacing a pending card again.
  final Set<String> _ignoredDiscovery;

  /// projectId → permission to follow the application's own menu-bar setting.
  final Map<String, bool> _menuBarAllowed;
  final _menuBarRevisions = <String, int>{};
  Future<void> _pendingSave = Future.value();

  /// Damage found while loading, or null when the file was fully healthy.
  final StorageCorruptionReport? corruptionReport;

  /// Loads the store, tolerating damage: unparseable JSON or a non-map top
  /// level moves the original aside to `.corrupt-<timestamp>` and starts
  /// empty; individually invalid entries are skipped while good entries
  /// load normally. Either shape is exposed via [corruptionReport];
  /// loading never throws for damaged content.
  static Future<PreferenceStore> load(String filePath) async {
    final file = File(filePath);
    if (!file.existsSync()) {
      return PreferenceStore._(file, {}, {}, {}, {}, {}, null);
    }
    final decode = await decodeStoreFile(
      file,
      isValidTopLevel: (decoded) => decoded is Map,
    );
    final wholeFileDamage = decode.wholeFileDamage;
    if (wholeFileDamage != null) {
      return PreferenceStore._(file, {}, {}, {}, {}, {}, wholeFileDamage);
    }
    final prefs = <String, Map<String, bool>>{};
    final updatePrefs = <String, bool>{};
    final guidance = <String, bool>{};
    final ignoredDiscovery = <String>{};
    final menuBarAllowed = <String, bool>{};
    var skipped = 0;
    for (final entry
        in (decode.decoded! as Map).cast<String, Object?>().entries) {
      if (entry.value is! Map) {
        skipped++;
        continue;
      }
      final record = (entry.value! as Map).cast<String, Object?>();
      if (entry.key == _menuBarKey) {
        for (final permission in record.entries) {
          if (permission.value is! bool) {
            skipped++;
          } else if (permission.value == true) {
            menuBarAllowed[permission.key] = true;
          }
        }
        continue;
      }
      if (entry.key == _updatesKey || entry.key == _guidanceKey) {
        final target = entry.key == _updatesKey ? updatePrefs : guidance;
        for (final pref in record.entries) {
          if (pref.value is bool) target[pref.key] = pref.value! as bool;
        }
        continue;
      }
      if (entry.key == _discoveryKey) {
        final ignored = record[_keyIgnoredProjects];
        if (ignored is List) {
          for (final id in ignored) {
            if (id is String && id.isNotEmpty) ignoredDiscovery.add(id);
          }
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
      guidance,
      ignoredDiscovery,
      menuBarAllowed,
      skippedRecordsReport(file, skipped),
    );
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
    final hadServices = _prefs.remove(projectId) != null;
    final hadMenuBarPermission = _menuBarAllowed.remove(projectId) != null;
    _menuBarRevisions[projectId] = (_menuBarRevisions[projectId] ?? 0) + 1;
    if (hadServices || hadMenuBarPermission) await _save();
  }

  /// Default: hidden by the launcher, including preference files predating it.
  bool isMenuBarAllowed(String projectId) =>
      _menuBarAllowed[projectId] ?? false;

  Future<void> setMenuBarAllowed(String projectId, bool allowed) async {
    final previous = _menuBarAllowed[projectId];
    final revision = (_menuBarRevisions[projectId] ?? 0) + 1;
    _menuBarRevisions[projectId] = revision;
    if (allowed) {
      _menuBarAllowed[projectId] = true;
    } else {
      _menuBarAllowed.remove(projectId);
    }
    try {
      await _save();
    } catch (_) {
      if (_menuBarRevisions[projectId] == revision) {
        if (previous == null) {
          _menuBarAllowed.remove(projectId);
        } else {
          _menuBarAllowed[projectId] = previous;
        }
      }
      rethrow;
    }
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

  // ---- one-shot guidance flags ----

  /// Whether the invalid-config explainer has already been shown. Default:
  /// false, including on preference files written before this flag existed.
  bool get invalidConfigGuidanceSeen =>
      _guidance[_keyInvalidConfigGuidanceSeen] ?? false;

  /// Records that the invalid-config explainer was shown; it never appears
  /// again afterwards.
  Future<void> markInvalidConfigGuidanceSeen() =>
      _setGuidanceFlag(_keyInvalidConfigGuidanceSeen, true);

  Future<void> _setGuidanceFlag(String key, bool value) async {
    final previous = _guidance[key];
    _guidance[key] = value;
    try {
      await _save();
    } catch (_) {
      // Keep the in-memory state consistent with what is on disk.
      if (previous == null) {
        _guidance.remove(key);
      } else {
        _guidance[key] = previous;
      }
      rethrow;
    }
  }

  // ---- runtime discovery ignore list ----

  /// ProjectIds the user chose to ignore during runtime discovery.
  Set<String> get ignoredDiscoveryProjects =>
      Set.unmodifiable(_ignoredDiscovery);

  Future<void> setDiscoveryIgnored(String projectId, bool ignored) async {
    final had = _ignoredDiscovery.contains(projectId);
    if (ignored == had) return;
    if (ignored) {
      _ignoredDiscovery.add(projectId);
    } else {
      _ignoredDiscovery.remove(projectId);
    }
    try {
      await _save();
    } catch (_) {
      // Keep the in-memory state consistent with what is on disk.
      if (ignored) {
        _ignoredDiscovery.remove(projectId);
      } else {
        _ignoredDiscovery.add(projectId);
      }
      rethrow;
    }
  }

  Future<void> _save() {
    // Snapshot each edit and serialize writes to the shared temporary file.
    // Rapid menu-bar toggles must persist in order, alongside other preferences.
    final contents = const JsonEncoder.withIndent('  ').convert({
      if (_updatePrefs.isNotEmpty) _updatesKey: _updatePrefs,
      if (_guidance.isNotEmpty) _guidanceKey: _guidance,
      if (_menuBarAllowed.isNotEmpty) _menuBarKey: _menuBarAllowed,
      if (_ignoredDiscovery.isNotEmpty)
        _discoveryKey: {
          _keyIgnoredProjects: _ignoredDiscovery.toList()..sort(),
        },
      ..._prefs,
    });
    final save = _pendingSave.then((_) => _write(contents));
    _pendingSave = save.catchError((Object _) {});
    return save;
  }

  Future<void> _write(String contents) async {
    await _file.parent.create(recursive: true);
    final tmp = File('${_file.path}.tmp');
    await tmp.writeAsString(contents, flush: true);
    await tmp.rename(_file.path);
    final result = await Process.run('chmod', ['600', _file.path]);
    if (result.exitCode != 0) {
      throw StateError('chmod 600 ${_file.path} failed: ${result.stderr}');
    }
  }
}
