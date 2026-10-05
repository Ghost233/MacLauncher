import 'binding_store.dart';
import 'manifest.dart';
import 'operations.dart';
import 'preferences.dart';

/// One notification attempt made during a launcher start.
class AutostartNotification {
  const AutostartNotification({
    required this.projectId,
    required this.serviceId,
    required this.outcome,
  });

  final String projectId;
  final String serviceId;

  /// The delivery outcome. Acknowledged never means the business started.
  final OperationOutcome outcome;
}

/// A service that was not notified, with the concrete reason.
class AutostartSkip {
  const AutostartSkip({
    required this.projectId,
    required this.serviceId,
    required this.reason,
  });

  final String projectId;
  final String serviceId;
  final String reason;
}

class AutostartReport {
  const AutostartReport({
    required this.notified,
    required this.skipped,
    required this.alreadyRan,
  });

  final List<AutostartNotification> notified;
  final List<AutostartSkip> skipped;

  /// True when this call was a no-op because the notifier already ran in
  /// this process. A restarted launcher is a new process and runs once more;
  /// reopening within the same process never resends notifications.
  final bool alreadyRan;
}

/// Fires login-start notifications once per launcher run.
///
/// Only services that (a) have an enabled personal preference, (b) are still
/// declared by a currently valid manifest, are notified. Invalid or missing
/// configuration blocks the notification and is reported, never silently
/// skipped. Whether the application is connected is left to the [startService]
/// seam: the entry-opening path lives behind it, and query-like operations
/// must never imply an entry open.
class AutostartNotifier {
  AutostartNotifier({required this._preferences});

  final PreferenceStore _preferences;
  var _ran = false;

  /// Runs the notification pass. Idempotent within one process: subsequent
  /// calls return a report with [AutostartReport.alreadyRan] set.
  Future<AutostartReport> runOnce({
    required BindingStore bindings,
    required Future<OperationOutcome> Function(
      String projectId,
      String serviceId,
    )
    startService,
  }) async {
    if (_ran) {
      return const AutostartReport(notified: [], skipped: [], alreadyRan: true);
    }
    _ran = true;

    final notified = <AutostartNotification>[];
    final skipped = <AutostartSkip>[];

    for (final binding in bindings.bindings) {
      final enabled = _preferences.enabledServices(binding.projectId);
      if (enabled.isEmpty) continue;

      // The current manifest decides: invalid or missing configuration
      // blocks notification; a removed declaration is no longer a target.
      ProjectManifest manifest;
      try {
        manifest = await ProjectManifest.read(binding.manifestPath);
      } on ManifestException catch (e) {
        for (final serviceId in enabled) {
          skipped.add(
            AutostartSkip(
              projectId: binding.projectId,
              serviceId: serviceId,
              reason: 'manifest unusable: ${e.reason}',
            ),
          );
        }
        continue;
      }
      if (manifest.projectId != binding.projectId) {
        for (final serviceId in enabled) {
          skipped.add(
            AutostartSkip(
              projectId: binding.projectId,
              serviceId: serviceId,
              reason: 'manifest identity mismatch: ${manifest.projectId}',
            ),
          );
        }
        continue;
      }
      final declared = {for (final s in manifest.services) s.id};

      for (final serviceId in enabled) {
        if (!declared.contains(serviceId)) {
          skipped.add(
            AutostartSkip(
              projectId: binding.projectId,
              serviceId: serviceId,
              reason: 'service no longer declared',
            ),
          );
          continue;
        }
        final outcome = await startService(binding.projectId, serviceId);
        notified.add(
          AutostartNotification(
            projectId: binding.projectId,
            serviceId: serviceId,
            outcome: outcome,
          ),
        );
      }
    }

    return AutostartReport(
      notified: notified,
      skipped: skipped,
      alreadyRan: false,
    );
  }
}
