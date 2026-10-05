import 'package:flutter/material.dart';

import 'self_update_flow.dart';
import 'theme.dart';

/// Presents the one self-update dialog for the flow's current state. The
/// dialog stays open across state transitions (prompt → progress → result)
/// and pops itself when the flow returns to [SelfUpdateIdle]. Widgets only
/// render state; every action is a [SelfUpdateFlow] intent (E05).
Future<void> showSelfUpdateDialog(BuildContext context, SelfUpdateFlow flow) {
  return showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (dialogContext) => ListenableBuilder(
      listenable: flow,
      builder: (context, _) {
        final state = flow.state;
        if (state is SelfUpdateIdle) {
          // Pop on the next frame: popping during build is not allowed.
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (dialogContext.mounted) Navigator.of(dialogContext).pop();
          });
          return const SizedBox.shrink();
        }
        return switch (state) {
          SelfUpdateAvailable() => _AvailableDialog(flow: flow, state: state),
          SelfUpdateDownloading() => _DownloadingDialog(
            flow: flow,
            state: state,
          ),
          SelfUpdateChecksumFailed() => _ChecksumDialog(
            flow: flow,
            state: state,
          ),
          SelfUpdateReadyToRelaunch() => _RelaunchDialog(
            flow: flow,
            state: state,
          ),
          SelfUpdateFailed() => _FailedDialog(flow: flow, state: state),
          SelfUpdateIdle() => const SizedBox.shrink(),
        };
      },
    ),
  );
}

class _AvailableDialog extends StatelessWidget {
  const _AvailableDialog({required this.flow, required this.state});

  final SelfUpdateFlow flow;
  final SelfUpdateAvailable state;

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('发现新版本'),
      content: Text('最新版本 ${state.latestVersion} 已发布。是否下载更新包？'),
      actions: [
        TextButton(onPressed: flow.dismiss, child: const Text('稍后')),
        FilledButton(
          onPressed: () => unawaitedDownload(flow, state),
          child: const Text('下载'),
        ),
      ],
    );
  }
}

class _DownloadingDialog extends StatelessWidget {
  const _DownloadingDialog({required this.flow, required this.state});

  final SelfUpdateFlow flow;
  final SelfUpdateDownloading state;

  @override
  Widget build(BuildContext context) {
    final total = state.totalBytes;
    final progress = total == null || total <= 0
        ? null
        : state.downloadedBytes / total;
    final percent = progress == null
        ? null
        : '${(progress * 100).clamp(0, 100).toStringAsFixed(0)}%';
    return AlertDialog(
      title: Text('正在下载 ${state.latestVersion}'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          LinearProgressIndicator(value: progress),
          const SizedBox(height: AppTheme.gapSm),
          Text(
            percent == null
                ? '已下载 ${_formatBytes(state.downloadedBytes)}'
                : '$percent · ${_formatBytes(state.downloadedBytes)} / ${_formatBytes(total!)}',
            style: AppTheme.captionMuted,
          ),
        ],
      ),
      actions: [
        TextButton(onPressed: flow.cancelDownload, child: const Text('取消')),
      ],
    );
  }
}

class _ChecksumDialog extends StatelessWidget {
  const _ChecksumDialog({required this.flow, required this.state});

  final SelfUpdateFlow flow;
  final SelfUpdateChecksumFailed state;

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('校验失败'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('下载的安装包未通过 sha256 校验，可能已损坏或被篡改。'),
          const SizedBox(height: AppTheme.gapSm),
          SelectableText(
            '期望：${state.expected}\n实际：${state.actual}',
            style: AppTheme.monoMuted,
          ),
        ],
      ),
      actions: [
        TextButton(onPressed: flow.dismiss, child: const Text('取消')),
        TextButton(
          onPressed: () => unawaitedSkip(flow, state),
          child: const Text('跳过校验继续'),
        ),
        FilledButton(
          onPressed: () => unawaitedRetryChecksum(flow, state),
          child: const Text('重试下载'),
        ),
      ],
    );
  }
}

class _RelaunchDialog extends StatelessWidget {
  const _RelaunchDialog({required this.flow, required this.state});

  final SelfUpdateFlow flow;
  final SelfUpdateReadyToRelaunch state;

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('已打开安装包'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            state.verified ? 'sha256 校验通过。' : '未做 sha256 完整性校验。',
            style: AppTheme.caption.copyWith(
              color: state.verified ? AppTheme.ok : AppTheme.warn,
            ),
          ),
          if (state.openError != null) ...[
            const SizedBox(height: AppTheme.gapSm),
            Text(
              '未能自动打开安装包：${state.openError}',
              style: AppTheme.caption.copyWith(color: AppTheme.danger),
            ),
          ],
          const SizedBox(height: AppTheme.gapSm),
          SelectableText(state.path, style: AppTheme.monoMuted),
          const SizedBox(height: AppTheme.gapSm),
          const Text('请在打开的 DMG 中手动完成替换安装（启动器不会改动应用目录）。'),
          const SizedBox(height: AppTheme.gapSm),
          const Text('替换完成后是否立刻重启 launcher？'),
          if (state.relaunchError != null) ...[
            const SizedBox(height: AppTheme.gapSm),
            Text(
              '重启失败：${state.relaunchError}',
              style: AppTheme.caption.copyWith(color: AppTheme.danger),
            ),
          ],
        ],
      ),
      actions: [
        TextButton(onPressed: flow.dismiss, child: const Text('稍后')),
        FilledButton(
          onPressed: () => unawaitedRelaunch(flow),
          child: const Text('立刻重启'),
        ),
      ],
    );
  }
}

class _FailedDialog extends StatelessWidget {
  const _FailedDialog({required this.flow, required this.state});

  final SelfUpdateFlow flow;
  final SelfUpdateFailed state;

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('下载失败'),
      content: Text(state.reason),
      actions: [
        TextButton(onPressed: flow.dismiss, child: const Text('取消')),
        FilledButton(
          onPressed: () => unawaitedRetry(flow, state),
          child: const Text('重试下载'),
        ),
      ],
    );
  }
}

// The dialog callbacks are synchronous; the flow intents are async fire and
// forget (the dialog rebuilds from flow state). These wrappers keep the
// intent explicit instead of sprinkling `unawaited` through the widgets.
void unawaitedDownload(SelfUpdateFlow flow, SelfUpdateAvailable state) {
  final url = state.downloadUrl;
  if (url == null) return;
  // ignore: discarded_futures
  flow.startDownload(
    latestVersion: state.latestVersion,
    downloadUrl: url,
    sha256: state.sha256,
  );
}

void unawaitedRetryChecksum(SelfUpdateFlow flow, SelfUpdateChecksumFailed s) {
  // ignore: discarded_futures
  flow.startDownload(
    latestVersion: s.latestVersion,
    downloadUrl: s.downloadUrl,
    sha256: s.sha256,
  );
}

void unawaitedSkip(SelfUpdateFlow flow, SelfUpdateChecksumFailed s) {
  // ignore: discarded_futures
  flow.skipVerificationAndDownload(s);
}

void unawaitedRetry(SelfUpdateFlow flow, SelfUpdateFailed s) {
  // ignore: discarded_futures
  flow.retryDownload(s);
}

void unawaitedRelaunch(SelfUpdateFlow flow) {
  // ignore: discarded_futures
  flow.relaunchNow();
}

String _formatBytes(int bytes) {
  if (bytes < 1024) return '$bytes B';
  if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
  if (bytes < 1024 * 1024 * 1024) {
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }
  return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
}
