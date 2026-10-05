import 'dart:async';
import 'dart:io';

import 'app_update_service.dart';
import 'chunked_downloader.dart';
import 'endpoint.dart';
import 'update_checker.dart';

/// Resolves the running launcher's own version string (e.g. `1.2.0+4`).
///
/// The launcher learns its version from the existing build channel: the
/// macOS bundle's Info.plist is populated by `flutter build` from the pubspec
/// `version` (`CFBundleShortVersionString`/`CFBundleVersion`), surfaced
/// through the `maclauncher/native` channel by the launcher app. This typedef
/// is the seam (E08): production reads the bundle, tests inject a constant.
/// Returns null when no build channel is available.
typedef SelfUpdateVersionResolver = Future<String?> Function();

/// Relaunches the launcher process. Returns null once the relaunch is
/// initiated (the current process is terminating), or a short error text.
/// Production goes through the `maclauncher/native` channel; tests inject a
/// recorder. Installation itself always stays with the user (ADR 0002).
typedef SelfUpdateRelauncher = Future<String?> Function();

/// Outcome of one [SelfUpdateService.downloadUpdate] call.
sealed class SelfUpdateDownloadOutcome {
  const SelfUpdateDownloadOutcome();
}

/// The package is complete on disk and [openError] reports whether the
/// platform handler accepted it (null = opened). Installing stays manual.
final class SelfUpdateDownloadCompleted extends SelfUpdateDownloadOutcome {
  const SelfUpdateDownloadCompleted({required this.result, this.openError});

  final DownloadResult result;
  final String? openError;

  bool get opened => openError == null;
}

/// The user cancelled; persisted chunks stay on disk for a later resume.
final class SelfUpdateDownloadCancelled extends SelfUpdateDownloadOutcome {
  const SelfUpdateDownloadCancelled();
}

/// The downloaded payload does not match the published digest. Typed
/// separately from [SelfUpdateDownloadFailed] so the UI can offer the two
/// distinct follow-ups issue #31 requires: retry, or skip verification.
final class SelfUpdateDownloadChecksumMismatch
    extends SelfUpdateDownloadOutcome {
  const SelfUpdateDownloadChecksumMismatch({
    required this.expected,
    required this.actual,
  });

  final String expected;
  final String actual;
}

/// The download itself failed (HTTP, transfer, unexpected). [reason] is
/// user-presentable and shown verbatim.
final class SelfUpdateDownloadFailed extends SelfUpdateDownloadOutcome {
  const SelfUpdateDownloadFailed(this.reason);

  final String reason;
}

/// Launcher-side orchestration of the launcher's own update (自更新):
/// silent check → download → verify → open the DMG. Replacing the installed
/// `.app` always stays with the user (ADR 0002); this service never installs,
/// and every version/URL/digest it reports comes from [UpdateChecker] — it
/// never invents state.
///
/// Dependencies are injected (E08): the version resolver, the checker
/// factory, the downloader and the opener all have production defaults and
/// test fakes. The checker factory is invoked per check with the freshly
/// resolved version, so the resolved-at-check-time version never goes stale.
class SelfUpdateService {
  SelfUpdateService({
    required EndpointLayout layout,
    required SelfUpdateVersionResolver versionResolver,
    UpdateChecker Function(String currentVersion)? checkerFactory,
    UpdatePackageDownloader? downloader,
    UpdatePackageOpener? opener,
  }) : _downloadsDirectory = '${layout.directory}/downloads/self',
       // ignore: prefer_initializing_formals
       _versionResolver = versionResolver,
       _checkerFactory =
           checkerFactory ??
           ((version) => UpdateChecker(currentVersion: version)),
       _downloader = downloader ?? ChunkedUpdateDownloader(),
       _opener = opener ?? _openWithMacOS;

  final String _downloadsDirectory;
  final SelfUpdateVersionResolver _versionResolver;
  final UpdateChecker Function(String currentVersion) _checkerFactory;
  final UpdatePackageDownloader _downloader;
  final UpdatePackageOpener _opener;

  /// Self-update package directory under the EndpointLayout convention:
  /// `<layout>/downloads/self`.
  String get downloadsDirectory => _downloadsDirectory;

  /// Resolves the current version through the build channel and runs one
  /// [UpdateChecker] query. Never throws; an unresolvable or non-semver
  /// current version is reported as an [UpdateCheckFailure] (silent on
  /// launch, visible on a manual check).
  Future<UpdateCheckResult> checkForUpdate() async {
    final String? version;
    try {
      version = await _versionResolver();
    } catch (_) {
      return const UpdateCheckFailure('读取当前版本失败。');
    }
    if (version == null) {
      return const UpdateCheckFailure('无法确定当前版本（构建通道不可用）。');
    }
    if (SemVer.tryParse(version) == null) {
      return UpdateCheckFailure('当前版本「$version」不是语义化版本，无法比较更新。');
    }
    return _checkerFactory(version).checkForUpdate();
  }

  /// Deterministic target path for one download URL:
  /// `<downloads/self>/<sanitized file name>`. Resume depends on the path
  /// staying stable for the same URL.
  String targetPathFor(Uri source) {
    final segment = source.pathSegments.isEmpty ? '' : source.pathSegments.last;
    final sanitized = segment.replaceAll(RegExp('[^A-Za-z0-9._-]'), '_');
    final fileName = sanitized.isEmpty ? 'self-update.dmg' : sanitized;
    return '$_downloadsDirectory/$fileName';
  }

  /// Downloads the launcher update package from [source], verifies it
  /// against [expectedSha256] when one was published (unless verification is
  /// explicitly skipped after a mismatch), then opens the DMG with the
  /// platform handler. Installing stays manual (ADR 0002).
  ///
  /// Never throws: cancellation, checksum mismatch and other failures map to
  /// typed outcomes. After a checksum mismatch the persisted `.part` state is
  /// discarded so a retry re-downloads instead of failing identically on the
  /// corrupt chunks.
  Future<SelfUpdateDownloadOutcome> downloadUpdate({
    required Uri source,
    String? expectedSha256,
    bool skipVerification = false,
    DownloadProgressCallback? onProgress,
    DownloadCancellationToken? cancellationToken,
  }) async {
    final targetPath = targetPathFor(source);
    final DownloadResult result;
    try {
      result = await _downloader.download(
        source,
        targetPath,
        expectedSha256: expectedSha256,
        verifyChecksum: expectedSha256 != null && !skipVerification,
        onProgress: onProgress,
        cancellationToken: cancellationToken,
      );
    } on DownloadCancelledException {
      return const SelfUpdateDownloadCancelled();
    } on DownloadChecksumMismatchException catch (e) {
      // Corrupt chunks would fail every retry identically; wipe them so the
      // next attempt starts clean.
      await ChunkedDownloader.discardResumableState(targetPath);
      return SelfUpdateDownloadChecksumMismatch(
        expected: e.expected,
        actual: e.actual,
      );
    } on DownloadException catch (e) {
      return SelfUpdateDownloadFailed(e.message);
    } catch (e) {
      return SelfUpdateDownloadFailed('$e');
    }
    final openError = await _opener(result.path);
    return SelfUpdateDownloadCompleted(result: result, openError: openError);
  }
}

Future<String?> _openWithMacOS(String path) async {
  try {
    final result = await Process.run('open', [path]);
    if (result.exitCode == 0) return null;
    return 'open 退出码 ${result.exitCode}：${result.stderr}';
  } catch (e) {
    return '$e';
  }
}
