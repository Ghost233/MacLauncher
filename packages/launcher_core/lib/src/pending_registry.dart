import 'dart:async';

import 'package:maclauncher_sdk/maclauncher_sdk.dart';

/// A project that connected over the SDK socket without a binding and is
/// waiting for the user's approval (runtime discovery).
///
/// Purely in-memory: a launcher restart clears pending cards. The app
/// retries its handshake every few seconds, so the card reappears on its
/// own as long as the app is actually running.
class PendingProject {
  PendingProject({
    required this.projectId,
    this.projectName,
    required this.services,
    this.entry,
    this.sourceProcessPath,
    required this.firstSeenAt,
    required this.lastSeenAt,
  });

  final String projectId;

  /// Self-reported display name; falls back to [projectId] for display.
  final String? projectName;

  /// Service declarations from the hello handshake.
  final List<ServiceDeclaration> services;

  /// Self-reported launch recipe, when the app provided one.
  final SdkEntry? entry;

  /// Best-effort path of the process that connected (display only; the
  /// trust model never depends on it).
  final String? sourceProcessPath;

  final DateTime firstSeenAt;
  final DateTime lastSeenAt;

  String get displayName =>
      projectName != null && projectName!.trim().isNotEmpty
      ? projectName!
      : projectId;
}

/// In-memory registry of projects waiting for approval.
class PendingRegistry {
  final _byProject = <String, PendingProject>{};
  final _changes = StreamController<List<PendingProject>>.broadcast();

  /// Emits the full pending list on every change.
  Stream<List<PendingProject>> get changes => _changes.stream;

  /// Pending projects in first-seen order.
  List<PendingProject> get projects {
    final list = _byProject.values.toList()
      ..sort((a, b) => a.firstSeenAt.compareTo(b.firstSeenAt));
    return List.unmodifiable(list);
  }

  bool has(String projectId) => _byProject.containsKey(projectId);

  PendingProject? byProject(String projectId) => _byProject[projectId];

  /// Upserts the pending entry for [projectId]: firstSeenAt survives
  /// retries, lastSeenAt advances, and already-known fields are kept when
  /// a retry omits them.
  void record({
    required String projectId,
    String? projectName,
    List<ServiceDeclaration> services = const [],
    SdkEntry? entry,
    String? sourceProcessPath,
    DateTime? now,
  }) {
    final existing = _byProject[projectId];
    final at = now ?? DateTime.now();
    _byProject[projectId] = PendingProject(
      projectId: projectId,
      projectName: projectName != null && projectName.trim().isNotEmpty
          ? projectName
          : existing?.projectName,
      services: services.isNotEmpty
          ? List.unmodifiable(services)
          : existing?.services ?? const [],
      entry: entry ?? existing?.entry,
      sourceProcessPath: sourceProcessPath ?? existing?.sourceProcessPath,
      firstSeenAt: existing?.firstSeenAt ?? at,
      lastSeenAt: at,
    );
    _emit();
  }

  /// Removes the pending entry (approve or ignore flows); returns it when
  /// present so the caller can build a binding from the recorded facts.
  PendingProject? remove(String projectId) {
    final removed = _byProject.remove(projectId);
    if (removed != null) _emit();
    return removed;
  }

  void _emit() {
    if (!_changes.isClosed) _changes.add(projects);
  }

  Future<void> close() => _changes.close();
}

/// Optional runtime-discovery hookups for [LauncherServer].
///
/// When absent the server keeps the pre-discovery behavior: unknown
/// projects are rejected as unknown-project and nothing is recorded.
class DiscoveryConfig {
  DiscoveryConfig({
    required this.pending,
    required this.isIgnored,
    this.peerProbe,
  });

  final PendingRegistry pending;

  /// Ignored projectIds are rejected as unknown-project (silently, without
  /// touching the pending registry) so an ignored app cannot nag.
  final bool Function(String projectId) isIgnored;

  /// Best-effort probe for the connecting process's path. Only consulted
  /// for newly seen projects or entries still missing a source path.
  final Future<String?> Function()? peerProbe;
}
