import 'dart:async';
import 'dart:io';

import 'chunked_downloader.dart';
import 'endpoint.dart';

/// The piece of [ChunkedDownloader] the update flow needs. Injected (E08) so
/// tests replace the network download with a controlled fake; the production
/// adapter delegates to [ChunkedDownloader].
abstract class UpdatePackageDownloader {
  Future<DownloadResult> download(
    Uri source,
    String targetPath, {
    String? expectedSha256,
    bool verifyChecksum,
    DownloadProgressCallback? onProgress,
    DownloadCancellationToken? cancellationToken,
  });
}

/// Production [UpdatePackageDownloader]: delegates to [ChunkedDownloader].
class ChunkedUpdateDownloader implements UpdatePackageDownloader {
  ChunkedUpdateDownloader([this._downloader]);

  final ChunkedDownloader? _downloader;

  ChunkedDownloader get _delegate => _downloader ?? ChunkedDownloader();

  @override
  Future<DownloadResult> download(
    Uri source,
    String targetPath, {
    String? expectedSha256,
    bool verifyChecksum = true,
    DownloadProgressCallback? onProgress,
    DownloadCancellationToken? cancellationToken,
  }) => _delegate.download(
    source,
    targetPath,
    expectedSha256: expectedSha256,
    verifyChecksum: verifyChecksum,
    onProgress: onProgress,
    cancellationToken: cancellationToken,
  );
}

/// Opens a downloaded update package with the platform handler. Returns null
/// on success, or a short error text when the package could not be opened.
/// The production implementation runs macOS `open`; tests inject a recorder.
typedef UpdatePackageOpener = Future<String?> Function(String path);

Future<String?> _openWithMacOS(String path) async {
  try {
    final result = await Process.run('open', [path]);
    if (result.exitCode == 0) return null;
    return 'open 退出码 ${result.exitCode}：${result.stderr}';
  } catch (e) {
    return '$e';
  }
}

/// Outcome of a launcher-side update package download (代下载). Downloading,
/// verifying and opening are the launcher's job; replacing the installed
/// application always stays with the user (ADR 0002).
sealed class AppUpdateDownloadOutcome {
  const AppUpdateDownloadOutcome();
}

/// The package is complete on disk. [opened] reports whether the platform
/// handler accepted it; when false, [openError] carries the cause and the
/// user opens [AppUpdateDownloadCompleted.result] `.path` manually.
class AppUpdateDownloadCompleted extends AppUpdateDownloadOutcome {
  const AppUpdateDownloadCompleted({
    required this.result,
    required this.opened,
    this.openError,
  });

  final DownloadResult result;
  final bool opened;
  final String? openError;
}

/// The user cancelled; persisted chunks stay on disk for a later resume.
class AppUpdateDownloadCancelled extends AppUpdateDownloadOutcome {
  const AppUpdateDownloadCancelled();
}

/// The download itself failed (HTTP, transfer, checksum). [reason] is the
/// downloader's message, shown to the user verbatim.
class AppUpdateDownloadFailed extends AppUpdateDownloadOutcome {
  const AppUpdateDownloadFailed(this.reason);

  final String reason;
}

/// Launcher-side orchestration of application update downloads (代下载).
///
/// The service owns the directory convention, the downloader and the
/// platform open; the version-status query itself stays on
/// `ServiceOperations.versionStatus`, and every displayed value still comes
/// from the application's answer — this service never invents versions.
class AppUpdateService {
  AppUpdateService({
    required EndpointLayout layout,
    UpdatePackageDownloader? downloader,
    UpdatePackageOpener? opener,
  }) : _downloadsDirectory = '${layout.directory}/downloads',
       _downloader = downloader ?? ChunkedUpdateDownloader(),
       _opener = opener ?? _openWithMacOS;

  final String _downloadsDirectory;
  final UpdatePackageDownloader _downloader;
  final UpdatePackageOpener _opener;

  /// Update package directory under the EndpointLayout convention:
  /// `<layout>/downloads`, i.e. `~/Library/Application Support/MacLauncher/downloads`
  /// for the per-user layout.
  String get downloadsDirectory => _downloadsDirectory;

  /// Deterministic target path for one project's download URL:
  /// `<downloads>/<projectId>/<sanitized file name>`. Resume depends on the
  /// path staying stable for the same URL.
  String targetPathFor(String projectId, Uri source) {
    final segment = source.pathSegments.isEmpty ? '' : source.pathSegments.last;
    final sanitized = segment.replaceAll(RegExp('[^A-Za-z0-9._-]'), '_');
    final fileName = sanitized.isEmpty ? 'update-package.dmg' : sanitized;
    return '$_downloadsDirectory/$projectId/$fileName';
  }

  /// Downloads the update package from [source] for [projectId], verifies it
  /// when the application provided [expectedSha256], then opens the package
  /// with the platform handler. Installing stays manual (ADR 0002).
  ///
  /// Never throws: every downloader failure becomes
  /// [AppUpdateDownloadFailed], cancellation becomes
  /// [AppUpdateDownloadCancelled]. After a checksum mismatch the persisted
  /// `.part` state is discarded so the next attempt re-downloads instead of
  /// failing identically on the corrupt chunks.
  Future<AppUpdateDownloadOutcome> downloadUpdate({
    required String projectId,
    required Uri source,
    String? expectedSha256,
    DownloadProgressCallback? onProgress,
    DownloadCancellationToken? cancellationToken,
  }) async {
    final targetPath = targetPathFor(projectId, source);
    final DownloadResult result;
    try {
      result = await _downloader.download(
        source,
        targetPath,
        expectedSha256: expectedSha256,
        verifyChecksum: expectedSha256 != null,
        onProgress: onProgress,
        cancellationToken: cancellationToken,
      );
    } on DownloadCancelledException {
      return const AppUpdateDownloadCancelled();
    } on DownloadChecksumMismatchException catch (e) {
      // Corrupt chunks would fail every retry identically; wipe them so the
      // next tap on 下载更新 starts clean.
      await ChunkedDownloader.discardResumableState(targetPath);
      return AppUpdateDownloadFailed(e.message);
    } on DownloadException catch (e) {
      return AppUpdateDownloadFailed(e.message);
    } catch (e) {
      return AppUpdateDownloadFailed('$e');
    }
    final openError = await _opener(result.path);
    return AppUpdateDownloadCompleted(
      result: result,
      opened: openError == null,
      openError: openError,
    );
  }
}
