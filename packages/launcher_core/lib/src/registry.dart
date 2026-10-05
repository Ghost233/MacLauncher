import 'dart:async';

import 'package:maclauncher_sdk/maclauncher_sdk.dart';

/// An accepted SDK connection, registered for one project identity.
class ConnectedProject {
  ConnectedProject({
    required this.projectId,
    required this.appSessionId,
    required this.launcherSessionId,
    required this.capabilities,
  });

  final String projectId;
  final String appSessionId;
  final String launcherSessionId;
  final CapabilitySet capabilities;
}

/// Registry of currently connected applications.
///
/// A second active connection for the same project identity is a conflict:
/// it is rejected and never preempts the incumbent. New connections after a
/// disconnect replace the old entry, and stale replies from a closed
/// connection can never override a newer session.
class ConnectionRegistry {
  final _byProject = <String, ConnectedProject>{};
  final _changes = StreamController<ConnectedProject?>.broadcast();

  /// Emits the project on connect, or null on disconnect.
  Stream<ConnectedProject?> get changes => _changes.stream;

  bool isActive(String projectId) => _byProject.containsKey(projectId);

  ConnectedProject? byProject(String projectId) => _byProject[projectId];

  List<ConnectedProject> get connected => List.unmodifiable(_byProject.values);

  void register(ConnectedProject project) {
    _byProject[project.projectId] = project;
    if (!_changes.isClosed) _changes.add(project);
  }

  /// Removes the entry only if it is still the same session, so a stale
  /// close event cannot remove a newer connection.
  void unregister(String projectId, String launcherSessionId) {
    final current = _byProject[projectId];
    if (current != null && current.launcherSessionId == launcherSessionId) {
      _byProject.remove(projectId);
      if (!_changes.isClosed) _changes.add(null);
    }
  }

  Future<void> close() => _changes.close();
}
