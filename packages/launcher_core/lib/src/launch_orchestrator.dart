import 'dart:async';
import 'dart:io';

import 'package:maclauncher_sdk/maclauncher_sdk.dart';

import 'binding_store.dart';
import 'discovery_approval.dart';
import 'entry_launcher.dart';
import 'manifest.dart';
import 'registry.dart';
import 'server.dart';

/// Outcome of trying to make an application's control entry reachable.
///
/// Opening an entry never means the business has started; it only gives the
/// application a chance to connect its SDK.
sealed class LaunchResult {
  const LaunchResult();
}

/// The application was already connected; nothing was opened.
class LaunchAlreadyConnected extends LaunchResult {
  const LaunchAlreadyConnected(this.project);
  final ConnectedProject project;
}

/// The entry was opened and the SDK connection was established in time.
class LaunchConnected extends LaunchResult {
  const LaunchConnected(this.project);
  final ConnectedProject project;
}

/// The entry was opened but no SDK connection arrived within the timeout.
/// The business state is unknown; never presented as started.
class LaunchUnknown extends LaunchResult {
  const LaunchUnknown(this.detail);
  final String detail;
}

/// No usable entry exists: the application can still run on its own and
/// connect later; while offline it simply cannot be pulled up.
class LaunchUnavailable extends LaunchResult {
  const LaunchUnavailable(this.detail);
  final String detail;
}

/// The current configuration is unusable (missing/invalid/identity
/// mismatch). Nothing is launched from a cached or invalid configuration.
class LaunchConfigBlocked extends LaunchResult {
  const LaunchConfigBlocked(this.reason, this.detail);
  final ManifestRejection reason;
  final String detail;
}

/// The configured entry exists but could not be opened.
class LaunchOpenFailed extends LaunchResult {
  const LaunchOpenFailed(this.error);
  final EntryOpenException error;
}

/// The project is not bound at all.
class LaunchUnbound extends LaunchResult {
  const LaunchUnbound(this.projectId);
  final String projectId;
}

/// Decides whether a start notification can be delivered: an already
/// connected application is used directly; otherwise the configured entry is
/// opened once and the SDK connection is awaited.
class LaunchOrchestrator {
  const LaunchOrchestrator({
    required this.server,
    required this.store,
    this.connectTimeout = const Duration(seconds: 30),
  });

  final LauncherServer server;
  final BindingStore store;
  final Duration connectTimeout;

  /// Ensures the control entry for [projectId] is connected, opening the
  /// configured entry when necessary. Querying, recycling and window opening
  /// must never call this — they never pull up an application that is not
  /// running.
  Future<LaunchResult> ensureEntryConnected(String projectId) async {
    final active = server.registry.byProject(projectId);
    if (active != null) return LaunchAlreadyConnected(active);

    final binding = store.byProjectId(projectId);
    if (binding == null) return LaunchUnbound(projectId);

    if (binding.origin == BindingOrigin.runtime) {
      return _openLearnedEntry(binding);
    }

    // Re-read the configuration fresh; a cached configuration must never be
    // used to launch. Config bindings always carry a manifest path (store
    // invariant).
    final ProjectManifest manifest;
    try {
      manifest = await ProjectManifest.read(binding.manifestPath!);
    } on ManifestException catch (e) {
      return LaunchConfigBlocked(e.reason, e.detail);
    }
    if (manifest.projectId != projectId) {
      return LaunchConfigBlocked(
        ManifestRejection.invalidStructure,
        '配置中的项目身份已变为 ${manifest.projectId}，与绑定 $projectId 不符',
      );
    }

    final entry = manifest.entry;
    if (entry == null) {
      return const LaunchUnavailable('配置中没有可拉起的应用入口');
    }

    try {
      final manifestDir = File(binding.manifestPath!).parent.path;
      await const EntryLauncher().open(entry, manifestDir: manifestDir);
    } on EntryOpenException catch (e) {
      return LaunchOpenFailed(e);
    }

    final project = await _waitForConnection(projectId);
    if (project == null) {
      return LaunchUnknown('入口已打开，但 ${connectTimeout.inSeconds} 秒内未建立 SDK 连接');
    }
    return LaunchConnected(project);
  }

  /// Opens a runtime binding's self-reported entry. No manifest is
  /// involved: the learned entry is the only launch recipe, a missing entry
  /// means the app can never be pulled up (observe/recycle only), and a
  /// vanished path is surfaced as 「入口失效」 without recycling anything.
  Future<LaunchResult> _openLearnedEntry(ProjectBinding binding) async {
    final learned = binding.learnedEntry;
    if (learned == null) {
      return const LaunchUnavailable('该应用没有可拉起的入口（运行时关联未提供入口）');
    }
    final invalid = entryInvalidReason(learned);
    if (invalid != null) {
      return LaunchUnavailable('入口失效：$invalid');
    }
    try {
      await const EntryLauncher().open(
        ManifestEntry(
          kind: learned.kind == SdkEntryKind.app
              ? EntryKind.app
              : EntryKind.executable,
          path: learned.path,
          args: learned.args,
          workingDirectory: learned.workingDirectory,
        ),
        // Self-reported paths are absolute; the entry's own directory is
        // the default working directory when none was reported.
        manifestDir: File(learned.path).parent.path,
      );
    } on EntryOpenException catch (e) {
      return LaunchOpenFailed(e);
    }

    final project = await _waitForConnection(binding.projectId);
    if (project == null) {
      return LaunchUnknown('入口已打开，但 ${connectTimeout.inSeconds} 秒内未建立 SDK 连接');
    }
    return LaunchConnected(project);
  }

  Future<ConnectedProject?> _waitForConnection(String projectId) {
    final existing = server.registry.byProject(projectId);
    if (existing != null) return Future.value(existing);
    final completer = Completer<ConnectedProject?>();
    final subscription = server.registry.changes.listen((_) {
      final project = server.registry.byProject(projectId);
      if (project != null && !completer.isCompleted) {
        completer.complete(project);
      }
    });
    final timer = Timer(connectTimeout, () {
      if (!completer.isCompleted) completer.complete(null);
    });
    return completer.future.whenComplete(() async {
      timer.cancel();
      await subscription.cancel();
    });
  }
}
