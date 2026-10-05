import 'dart:async';

import 'package:flutter/material.dart';
import 'package:launcher_core/launcher_core.dart';
import 'package:maclauncher_sdk/maclauncher_sdk.dart';

import 'theme.dart';

/// Application-level version status (版本状况) and the 代下载 entry.
///
/// Every displayed value comes from the application's answer to
/// [ServiceOperations.versionStatus]; the widget never invents versions,
/// failure reasons or update availability. The query runs once when the
/// connection comes up and again on the manual refresh button. The download
/// itself goes through the injected [AppUpdateService]: the launcher
/// downloads the package to the EndpointLayout downloads directory and opens
/// it; replacing the installed application stays manual (ADR 0002).
class AppUpdateSection extends StatefulWidget {
  const AppUpdateSection({
    super.key,
    required this.projectId,
    this.registry,
    this.operations,
    this.updateService,
  });

  final String projectId;
  final ConnectionRegistry? registry;
  final ServiceOperations? operations;

  /// Download orchestration. When null the 下载更新 button stays hidden —
  /// the version status itself still renders.
  final AppUpdateService? updateService;

  @override
  State<AppUpdateSection> createState() => _AppUpdateSectionState();
}

class _AppUpdateSectionState extends State<AppUpdateSection> {
  StreamSubscription<ConnectedProject?>? _registrySub;
  VersionStatusResult? _result;
  var _querying = false;
  var _wasConnected = false;

  var _downloading = false;
  var _downloadedBytes = 0;
  int? _totalBytes;
  DownloadCancellationToken? _cancelToken;
  String? _downloadNote;
  var _downloadFailed = false;

  bool get _connected => widget.registry?.isActive(widget.projectId) ?? false;

  @override
  void initState() {
    super.initState();
    _wasConnected = _connected;
    _registrySub = widget.registry?.changes.listen((_) {
      final now = _connected;
      final edge = now && !_wasConnected;
      _wasConnected = now;
      if (!mounted) return;
      // Connection state decides whether a stale snapshot may be shown.
      setState(() {});
      // Auto-query once per connection establishment.
      if (edge) _refresh();
    });
    // Already connected when the card appears: query once immediately.
    if (_connected) {
      _querying = true;
      unawaited(_runQuery());
    }
  }

  @override
  void dispose() {
    _registrySub?.cancel();
    _cancelToken?.cancel();
    super.dispose();
  }

  void _refresh() {
    if (_querying || widget.operations == null) return;
    setState(() => _querying = true);
    unawaited(_runQuery());
  }

  /// versionStatus never throws (every failure maps to a typed result), so
  /// this background run needs no additional error handling (E03).
  Future<void> _runQuery() async {
    final operations = widget.operations;
    if (operations == null) {
      // initState may have marked a query in flight before knowing the
      // operations seam is absent; never leave the spinner stuck.
      if (mounted && _querying) setState(() => _querying = false);
      return;
    }
    final result = await operations.versionStatus(widget.projectId);
    if (!mounted) return;
    setState(() {
      _querying = false;
      _result = result;
    });
  }

  Future<void> _onDownloadPressed(VersionStatus status) async {
    if (status.sha256 == null) {
      final proceed = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('未提供校验值'),
          content: const Text('应用未提供更新包的 sha256 校验值，无法验证下载完整性。是否继续下载？'),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(context).pop(true),
              child: const Text('继续下载'),
            ),
          ],
        ),
      );
      if (proceed != true || !mounted) return;
    }
    await _runDownload(status);
  }

  Future<void> _runDownload(VersionStatus status) async {
    final service = widget.updateService;
    final url = status.downloadUrl;
    if (service == null || url == null || _downloading) return;
    final source = Uri.tryParse(url);
    if (source == null) {
      setState(() {
        _downloadFailed = true;
        _downloadNote = '下载失败：下载地址无效（$url）';
      });
      return;
    }
    final token = DownloadCancellationToken();
    setState(() {
      _downloading = true;
      _downloadedBytes = 0;
      _totalBytes = null;
      _cancelToken = token;
      _downloadNote = null;
      _downloadFailed = false;
    });
    final outcome = await service.downloadUpdate(
      projectId: widget.projectId,
      source: source,
      expectedSha256: status.sha256,
      onProgress: (downloaded, total) {
        if (!mounted) return;
        setState(() {
          _downloadedBytes = downloaded;
          _totalBytes = total;
        });
      },
      cancellationToken: token,
    );
    if (!mounted) return;
    setState(() {
      _downloading = false;
      _cancelToken = null;
      switch (outcome) {
        case AppUpdateDownloadCompleted():
          _downloadNote = null;
          _downloadFailed = false;
        case AppUpdateDownloadCancelled():
          _downloadNote = '已取消下载；再次下载可从断点续传。';
          _downloadFailed = false;
        case AppUpdateDownloadFailed(:final reason):
          _downloadNote = '下载失败：$reason';
          _downloadFailed = true;
      }
    });
    if (outcome is AppUpdateDownloadCompleted) {
      await _showCompletionDialog(outcome);
    }
  }

  /// ADR 0002: the launcher delivers the package to the door; replacing the
  /// installed application is always the user's manual step.
  Future<void> _showCompletionDialog(AppUpdateDownloadCompleted done) {
    final verified = done.result.checksumVerified;
    return showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(done.opened ? '已下载并打开更新包' : '下载完成'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              verified ? 'sha256 校验通过。' : '应用未提供校验值，未做完整性校验。',
              style: AppTheme.caption,
            ),
            if (!done.opened)
              Padding(
                padding: const EdgeInsets.only(top: AppTheme.gapSm),
                child: Text(
                  '自动打开失败：${done.openError ?? '原因未知'}，请手动打开下面的文件。',
                  style: AppTheme.caption.copyWith(color: AppTheme.warn),
                ),
              ),
            const SizedBox(height: AppTheme.gapSm),
            SelectableText(done.result.path, style: AppTheme.mono),
            const SizedBox(height: AppTheme.gapSm),
            const Text(
              '请在打开的 DMG 中手动完成替换安装；启动器不会改动应用目录。',
              style: AppTheme.caption,
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('知道了'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final connected = _connected;
    final result = _result;
    return Container(
      margin: const EdgeInsets.only(top: AppTheme.gapMd),
      padding: const EdgeInsets.all(AppTheme.gapMd),
      decoration: BoxDecoration(
        color: AppTheme.surfaceSubtle,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: AppTheme.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Text('版本状况', style: AppTheme.sectionLabel),
              const Spacer(),
              if (_querying)
                const Padding(
                  padding: EdgeInsets.only(right: AppTheme.gapSm),
                  child: SizedBox(
                    width: 12,
                    height: 12,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: AppTheme.accent,
                    ),
                  ),
                ),
              IconButton(
                tooltip: '重新查询版本状况',
                onPressed: _querying ? null : _refresh,
                icon: const Icon(Icons.refresh_rounded),
              ),
            ],
          ),
          const SizedBox(height: AppTheme.gapXs),
          if (!connected)
            _statusLine(
              icon: Icons.help_outline_rounded,
              color: AppTheme.textTertiary,
              text: '状态未知（应用未连接）',
            )
          else if (result == null)
            _statusLine(
              icon: Icons.hourglass_top_rounded,
              color: AppTheme.textTertiary,
              text: _querying ? '正在查询版本状况…' : '尚未查询版本状况',
            )
          else
            _resultLine(result),
          if (_showDownloadButton(result, connected)) ...[
            const SizedBox(height: AppTheme.gapSm),
            _downloadButton((result! as VersionStatusSnapshot).status),
          ],
          if (_downloading) ...[
            const SizedBox(height: AppTheme.gapSm),
            _downloadProgress(),
          ],
          if (_downloadNote != null) ...[
            const SizedBox(height: AppTheme.gapSm),
            _downloadNoteLine(),
          ],
        ],
      ),
    );
  }

  bool _showDownloadButton(VersionStatusResult? result, bool connected) {
    if (!connected || _downloading || widget.updateService == null) {
      return false;
    }
    if (result is! VersionStatusSnapshot) return false;
    final status = result.status;
    return status.state == VersionQueryState.success &&
        status.hasUpdate == true &&
        status.downloadUrl != null;
  }

  Widget _downloadButton(VersionStatus status) {
    return Align(
      alignment: Alignment.centerLeft,
      child: FilledButton.icon(
        onPressed: () => _onDownloadPressed(status),
        icon: const Icon(Icons.download_rounded, size: 15),
        label: const Text('下载更新'),
        style: FilledButton.styleFrom(
          backgroundColor: AppTheme.accent,
          foregroundColor: Colors.white,
          textStyle: const TextStyle(fontSize: 12.5),
          minimumSize: const Size(0, 30),
          padding: const EdgeInsets.symmetric(horizontal: 12),
          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        ),
      ),
    );
  }

  Widget _downloadProgress() {
    final total = _totalBytes;
    final fraction = total != null && total > 0
        ? (_downloadedBytes / total).clamp(0.0, 1.0)
        : null;
    final label = fraction != null
        ? '${(fraction * 100).toStringAsFixed(0)}% · '
              '${_formatBytes(_downloadedBytes)} / ${_formatBytes(total!)}'
        : '已下载 ${_formatBytes(_downloadedBytes)}（总大小未知）';
    return Row(
      children: [
        Expanded(
          child: LinearProgressIndicator(
            value: fraction,
            color: AppTheme.accent,
            backgroundColor: AppTheme.accentSoft,
            minHeight: 4,
            borderRadius: BorderRadius.circular(2),
          ),
        ),
        const SizedBox(width: AppTheme.gapSm),
        Text(label, style: AppTheme.captionMuted),
        TextButton(
          onPressed: () => _cancelToken?.cancel(),
          child: const Text('取消'),
        ),
      ],
    );
  }

  Widget _downloadNoteLine() {
    final failed = _downloadFailed;
    final result = _result;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(
          failed ? Icons.error_outline_rounded : Icons.info_outline_rounded,
          size: 14,
          color: failed ? AppTheme.danger : AppTheme.textTertiary,
        ),
        const SizedBox(width: AppTheme.gapSm),
        Expanded(
          child: Text(
            _downloadNote!,
            style: AppTheme.caption.copyWith(
              color: failed ? AppTheme.danger : AppTheme.textTertiary,
            ),
          ),
        ),
        if (failed && result is VersionStatusSnapshot)
          TextButton(
            // Retry goes through the same consent path as the first click:
            // a missing sha256 must be confirmed again, not silently
            // skipped after the initial consent (P2 review fix).
            onPressed: () => _onDownloadPressed(result.status),
            child: const Text('重试下载'),
          ),
      ],
    );
  }

  Widget _resultLine(VersionStatusResult result) {
    return switch (result) {
      VersionStatusUnsupported() => _statusLine(
        icon: Icons.block_rounded,
        color: AppTheme.neutral,
        text: '不支持更新',
      ),
      VersionStatusUnknown(:final reason) => _statusLine(
        icon: Icons.help_outline_rounded,
        color: AppTheme.textTertiary,
        text: '状态未知（$reason）',
      ),
      VersionStatusSnapshot(:final status) => _snapshotLine(status),
    };
  }

  Widget _snapshotLine(VersionStatus status) {
    return switch (status.state) {
      VersionQueryState.unsupported => _statusLine(
        icon: Icons.block_rounded,
        color: AppTheme.neutral,
        text: '不支持更新',
      ),
      VersionQueryState.failure => _statusLine(
        icon: Icons.error_outline_rounded,
        color: AppTheme.danger,
        text: '查询失败：${status.failureReason ?? '应用未提供失败原因'}',
      ),
      VersionQueryState.success => _successLine(status),
    };
  }

  Widget _successLine(VersionStatus status) {
    final parts = <String>[
      status.currentVersion != null
          ? '当前版本 ${status.currentVersion}'
          : '当前版本：应用未提供',
    ];
    final updateAvailable = status.hasUpdate == true;
    if (updateAvailable) {
      parts.add(
        status.latestVersion != null
            ? '有新版本 ${status.latestVersion}'
            : '有新版本（版本号未提供）',
      );
      if (status.downloadUrl == null) parts.add('应用未提供下载地址');
    } else if (status.hasUpdate == false) {
      parts.add('已是最新');
    }
    return _statusLine(
      icon: updateAvailable
          ? Icons.arrow_circle_down_rounded
          : Icons.check_circle_outline_rounded,
      color: updateAvailable ? AppTheme.accent : AppTheme.ok,
      text: parts.join(' · '),
    );
  }

  Widget _statusLine({
    required IconData icon,
    required Color color,
    required String text,
  }) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(top: 1),
          child: Icon(icon, size: 15, color: color),
        ),
        const SizedBox(width: AppTheme.gapSm),
        Expanded(
          child: Text(text, style: AppTheme.caption.copyWith(color: color)),
        ),
      ],
    );
  }

  static String _formatBytes(int bytes) {
    const mib = 1024 * 1024;
    const kib = 1024;
    if (bytes >= mib) return '${(bytes / mib).toStringAsFixed(1)} MB';
    if (bytes >= kib) return '${(bytes / kib).toStringAsFixed(1)} KB';
    return '$bytes B';
  }
}
