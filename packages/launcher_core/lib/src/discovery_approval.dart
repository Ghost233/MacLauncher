import 'dart:io';

import 'package:maclauncher_sdk/maclauncher_sdk.dart';

import 'binding_store.dart';
import 'manifest.dart';
import 'pending_registry.dart';

/// Approving a pending project failed. Surfaced to the user as the concrete
/// reason; a failed approval never creates a binding and never drops the
/// pending record.
class DiscoveryApprovalException implements Exception {
  DiscoveryApprovalException(this.detail);

  final String detail;

  @override
  String toString() => 'DiscoveryApprovalException: $detail';
}

/// Default on-disk existence check for entry paths.
bool _defaultPathExists(String path) =>
    FileSystemEntity.typeSync(path) != FileSystemEntityType.notFound;

/// Why a self-reported entry is unusable right now, or null when it points
/// at something real. Used both at approval time and to surface 「入口失效」
/// for an already-approved runtime binding whose entry vanished on disk —
/// a vanished path is a display/launch blocker, never a reason to recycle.
String? entryInvalidReason(
  SdkEntry entry, {
  bool Function(String path)? pathExists,
}) {
  final exists = pathExists ?? _defaultPathExists;
  switch (entry.kind) {
    case SdkEntryKind.app:
      if (!exists(entry.path)) {
        return '应用包不存在：${entry.path}';
      }
      if (!File('${entry.path}/Contents/Info.plist').existsSync()) {
        return '不是有效的应用包（缺少 Contents/Info.plist）：${entry.path}';
      }
      return null;
    case SdkEntryKind.executable:
      if (!exists(entry.path)) {
        return '可执行文件不存在：${entry.path}';
      }
      return null;
  }
}

/// Turns an approved pending project into a runtime binding.
///
/// The handshake is the authority: the binding's name, service declarations
/// and entry all come from what the application self-reported while pending.
/// Approving without an entry is allowed — the project stays observable and
/// recyclable, it simply cannot be pulled up (decision ① of #45).
class DiscoveryApproval {
  const DiscoveryApproval({
    required this.bindings,
    required this.pending,
    this.pathExists,
  });

  final BindingStore bindings;
  final PendingRegistry pending;

  /// Injectable existence check, for tests. Defaults to on-disk checks.
  final bool Function(String path)? pathExists;

  /// Approves [projectId]: validates the self-reported entry (when any),
  /// inserts a runtime binding, and only then drops the pending record.
  ///
  /// Throws [StateError] when the project is not pending or its identity is
  /// already bound (the pending record is kept in every failure), and
  /// [DiscoveryApprovalException] when the entry no longer points at
  /// something real.
  Future<ProjectBinding> approve(String projectId) async {
    final record = pending.byProject(projectId);
    if (record == null) {
      throw StateError('not pending: $projectId');
    }
    final entry = record.entry;
    if (entry != null) {
      final invalid = entryInvalidReason(entry, pathExists: pathExists);
      if (invalid != null) throw DiscoveryApprovalException(invalid);
    }
    final binding = ProjectBinding(
      projectId: record.projectId,
      name: record.displayName,
      services: [
        for (final s in record.services)
          ManifestService(id: s.id, name: s.name),
      ],
      boundAt: DateTime.now().toUtc(),
      origin: BindingOrigin.runtime,
      learnedEntry: entry,
    );
    // Insert first (enforces the unique-identity invariant); only a
    // persisted binding may clear the pending record.
    await bindings.insert(binding);
    pending.remove(projectId);
    return binding;
  }
}
