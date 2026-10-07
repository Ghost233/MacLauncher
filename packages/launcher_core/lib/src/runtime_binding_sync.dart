import 'package:maclauncher_sdk/maclauncher_sdk.dart';

import 'binding_store.dart';
import 'config_refresh.dart';
import 'manifest.dart';

/// Keeps a runtime binding in step with its application's handshakes.
///
/// For a runtime binding the handshake is the authority: each successful
/// hello refreshes the declared service set (added services join, vanished
/// ones become retained read-only records with pruned preferences) and
/// self-heals the learned entry when the application moved on disk. Config
/// bindings and unknown projects are ignored — their manifest stays the
/// authority.
class RuntimeBindingSync {
  const RuntimeBindingSync({required this.bindings, required this.refresher});

  final BindingStore bindings;
  final ConfigRefresher refresher;

  /// Applies one successful handshake. No-op unless [projectId] is a runtime
  /// binding.
  Future<void> afterHandshake(
    String projectId,
    CapabilitySet capabilities,
    SdkEntry? entry, {
    String? projectName,
  }) async {
    final binding = bindings.byProjectId(projectId);
    if (binding == null || binding.origin != BindingOrigin.runtime) return;

    await refresher.applyRuntimeHello(projectId, [
      for (final s in capabilities.services)
        ManifestService(id: s.id, name: s.name),
    ], projectName: projectName);

    // Entry self-heal: a moved app reports its new path on the next hello.
    // The service diff above may have replaced the record; re-read it.
    if (entry != null) {
      final current = bindings.byProjectId(projectId);
      final learned = current?.learnedEntry;
      if (current != null && (learned == null || !_sameEntry(learned, entry))) {
        await bindings.replace(
          ProjectBinding(
            projectId: current.projectId,
            name: current.name,
            manifestPath: current.manifestPath,
            services: current.services,
            boundAt: current.boundAt,
            origin: current.origin,
            learnedEntry: entry,
          ),
        );
      }
    }
  }

  static bool _sameEntry(SdkEntry a, SdkEntry b) {
    if (a.kind != b.kind ||
        a.path != b.path ||
        a.workingDirectory != b.workingDirectory ||
        a.args.length != b.args.length) {
      return false;
    }
    for (var i = 0; i < a.args.length; i++) {
      if (a.args[i] != b.args[i]) return false;
    }
    return true;
  }
}
