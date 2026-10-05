import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:launcher_core/launcher_core.dart';

/// The one self-update flow state the UI renders. Widgets only present the
/// current state (E05); every transition is decided here.
sealed class SelfUpdateState {
  const SelfUpdateState();
}

/// Nothing to present.
final class SelfUpdateIdle extends SelfUpdateState {
  const SelfUpdateIdle();
}

/// A newer launcher version exists. [downloadUrl] is null when the release
/// ships no DMG — then there is nothing to download and the UI only informs.
final class SelfUpdateAvailable extends SelfUpdateState {
  const SelfUpdateAvailable({
    required this.latestVersion,
    required this.downloadUrl,
    required this.sha256,
  });

  final String latestVersion;
  final Uri? downloadUrl;
  final String? sha256;
}

/// A download is running; [downloadedBytes]/[totalBytes] come from the
/// downloader's progress callback ([totalBytes] null = size unknown).
final class SelfUpdateDownloading extends SelfUpdateState {
  const SelfUpdateDownloading({
    required this.latestVersion,
    required this.downloadedBytes,
    required this.totalBytes,
  });

  final String latestVersion;
  final int downloadedBytes;
  final int? totalBytes;
}

/// The payload did not match the published digest; the UI offers retry,
/// skip-verification and cancel (issue #31).
final class SelfUpdateChecksumFailed extends SelfUpdateState {
  const SelfUpdateChecksumFailed({
    required this.latestVersion,
    required this.downloadUrl,
    required this.sha256,
    required this.expected,
    required this.actual,
  });

  final String latestVersion;
  final Uri downloadUrl;
  final String sha256;
  final String expected;
  final String actual;
}

/// The DMG is on disk and was opened (or [openError] explains why not).
/// [verified] is false when no digest was published or the user skipped
/// verification. The user replaces the `.app` manually, then chooses whether
/// to relaunch (ADR 0002).
final class SelfUpdateReadyToRelaunch extends SelfUpdateState {
  const SelfUpdateReadyToRelaunch({
    required this.latestVersion,
    required this.path,
    required this.verified,
    this.openError,
    this.relaunchError,
  });

  final String latestVersion;
  final String path;
  final bool verified;
  final String? openError;

  /// Set when the user asked to relaunch and it failed; stays on this state
  /// so the user can retry or relaunch manually.
  final String? relaunchError;

  SelfUpdateReadyToRelaunch withRelaunchError(String? error) =>
      SelfUpdateReadyToRelaunch(
        latestVersion: latestVersion,
        path: path,
        verified: verified,
        openError: openError,
        relaunchError: error,
      );
}

/// The download failed for a non-checksum reason; [reason] comes verbatim
/// from the downloader.
final class SelfUpdateFailed extends SelfUpdateState {
  const SelfUpdateFailed({
    required this.latestVersion,
    required this.downloadUrl,
    required this.sha256,
    required this.reason,
  });

  final String latestVersion;
  final Uri downloadUrl;
  final String? sha256;
  final String reason;
}

/// Orchestrates the launcher's self-update flow (issue #31):
/// silent check on launch → prompt before download (unless 自动下载) →
/// chunked download with visible progress → sha256 verification → open the
/// DMG → offer relaunch. Every step past the check waits for the user; the
/// install itself always stays with the user (ADR 0002).
///
/// Pure orchestration with no Flutter context: widgets observe [state] via
/// [ChangeNotifier] and call the intent methods. All external effects go
/// through [SelfUpdateService] and the injected [SelfUpdateRelauncher] (E08).
class SelfUpdateFlow extends ChangeNotifier {
  SelfUpdateFlow({
    required PreferenceStore preferences,
    required SelfUpdateService service,
    SelfUpdateRelauncher? relauncher,
  })
    // ignore: prefer_initializing_formals
    : _preferences = preferences,
       // ignore: prefer_initializing_formals
       _service = service,
       // ignore: prefer_initializing_formals
       _relauncher = relauncher;

  final PreferenceStore _preferences;
  final SelfUpdateService _service;
  final SelfUpdateRelauncher? _relauncher;

  SelfUpdateState _state = const SelfUpdateIdle();
  SelfUpdateState get state => _state;

  DownloadCancellationToken? _cancellation;

  void _set(SelfUpdateState next) {
    _state = next;
    notifyListeners();
  }

  /// The launch-time silent check (受「启动时检查」偏好控制). Failures and
  /// "no update" stay silent; a downloadable update either prompts (default)
  /// or starts downloading immediately (「自动下载」开). Never throws.
  Future<void> checkOnLaunch() async {
    if (!_preferences.updateCheckOnLaunch) return;
    if (_state is! SelfUpdateIdle) return;
    final result = await _service.checkForUpdate();
    switch (result) {
      case UpdateCheckSuccess(
        hasUpdate: true,
        latestVersion: final version,
        dmgDownloadUrl: final url,
        sha256: final sha256,
      ):
        if (url == null) return; // nothing to download: stay silent
        if (_preferences.updateAutoDownload) {
          await startDownload(
            latestVersion: version,
            downloadUrl: url,
            sha256: sha256,
          );
        } else {
          _set(
            SelfUpdateAvailable(
              latestVersion: version,
              downloadUrl: url,
              sha256: sha256,
            ),
          );
        }
      case UpdateCheckSuccess() || UpdateCheckFailure():
        return; // silent by design
    }
  }

  /// The settings page's manual check. Always returns the typed result so
  /// the page can render 有新版 / 已是最新 / 失败 itself; a downloadable
  /// update does not auto-prompt here — the settings row is the entry.
  Future<UpdateCheckResult> checkNow() => _service.checkForUpdate();

  /// User confirmed the download (or 自动下载 triggered it).
  Future<void> startDownload({
    required String latestVersion,
    required Uri downloadUrl,
    String? sha256,
    bool skipVerification = false,
  }) async {
    if (_state is SelfUpdateDownloading) return;
    final cancellation = DownloadCancellationToken();
    _cancellation = cancellation;
    _set(
      SelfUpdateDownloading(
        latestVersion: latestVersion,
        downloadedBytes: 0,
        totalBytes: null,
      ),
    );
    final outcome = await _service.downloadUpdate(
      source: downloadUrl,
      expectedSha256: sha256,
      skipVerification: skipVerification,
      cancellationToken: cancellation,
      onProgress: (downloaded, total) {
        if (_state is SelfUpdateDownloading) {
          _set(
            SelfUpdateDownloading(
              latestVersion: latestVersion,
              downloadedBytes: downloaded,
              totalBytes: total,
            ),
          );
        }
      },
    );
    _cancellation = null;
    switch (outcome) {
      case SelfUpdateDownloadCompleted(:final result, :final openError):
        _set(
          SelfUpdateReadyToRelaunch(
            latestVersion: latestVersion,
            path: result.path,
            verified: result.checksumVerified,
            openError: openError,
          ),
        );
      case SelfUpdateDownloadCancelled():
        _set(const SelfUpdateIdle());
      case SelfUpdateDownloadChecksumMismatch(:final expected, :final actual):
        _set(
          SelfUpdateChecksumFailed(
            latestVersion: latestVersion,
            downloadUrl: downloadUrl,
            sha256: sha256 ?? expected,
            expected: expected,
            actual: actual,
          ),
        );
      case SelfUpdateDownloadFailed(:final reason):
        _set(
          SelfUpdateFailed(
            latestVersion: latestVersion,
            downloadUrl: downloadUrl,
            sha256: sha256,
            reason: reason,
          ),
        );
    }
  }

  /// Retries after a checksum mismatch with verification turned off — the
  /// user's explicit choice in the mismatch dialog.
  Future<void> skipVerificationAndDownload(SelfUpdateChecksumFailed state) =>
      startDownload(
        latestVersion: state.latestVersion,
        downloadUrl: state.downloadUrl,
        sha256: state.sha256,
        skipVerification: true,
      );

  /// Retries a failed download with the same parameters.
  Future<void> retryDownload(SelfUpdateFailed state) => startDownload(
    latestVersion: state.latestVersion,
    downloadUrl: state.downloadUrl,
    sha256: state.sha256,
  );

  /// Cancels the running download; chunks stay on disk for a later resume.
  void cancelDownload() => _cancellation?.cancel();

  /// The user finished replacing the `.app` and asked to relaunch now. A
  /// failure is reported on the same state so the dialog can show it.
  Future<void> relaunchNow() async {
    final current = _state;
    if (current is! SelfUpdateReadyToRelaunch) return;
    final relauncher = _relauncher;
    if (relauncher == null) {
      _set(current.withRelaunchError('重启通道不可用。'));
      return;
    }
    final error = await relauncher();
    // On success the process is terminating; the state change only matters
    // when the relaunch failed.
    _set(current.withRelaunchError(error));
  }

  /// Dismisses the current prompt/result without acting on it.
  void dismiss() {
    if (_state is! SelfUpdateDownloading) _set(const SelfUpdateIdle());
  }
}
