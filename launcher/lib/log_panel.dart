import 'dart:async';

import 'package:flutter/material.dart';
import 'package:launcher_core/launcher_core.dart';
import 'package:maclauncher_sdk/maclauncher_sdk.dart';

import 'theme.dart';

/// Log panel for one service. Owns a [LogViewModel]: opened while the panel
/// is visible, closed and disposed with it — closing the panel stops all
/// further log queries.
class LogPanel extends StatefulWidget {
  const LogPanel({
    super.key,
    required this.operations,
    required this.projectId,
    required this.serviceId,
    required this.title,
  });

  final ServiceOperations operations;
  final String projectId;
  final String serviceId;
  final String title;

  @override
  State<LogPanel> createState() => _LogPanelState();
}

class _LogPanelState extends State<LogPanel> {
  late final LogViewModel _viewModel;
  StreamSubscription<LogViewState>? _subscription;
  LogViewState _state = LogViewState.loading;

  @override
  void initState() {
    super.initState();
    _viewModel = LogViewModel(
      operations: widget.operations,
      projectId: widget.projectId,
      serviceId: widget.serviceId,
    );
    _state = _viewModel.current;
    _subscription = _viewModel.states.listen((state) {
      if (mounted) setState(() => _state = state);
    });
    _viewModel.open();
  }

  @override
  void dispose() {
    _subscription?.cancel();
    _viewModel.close();
    _viewModel.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final state = _state;
    return SizedBox(
      height: MediaQuery.of(context).size.height * 0.6,
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: AppTheme.gapLg,
              vertical: AppTheme.gapMd,
            ),
            child: Row(
              children: [
                const Icon(
                  Icons.terminal_rounded,
                  size: 16,
                  color: AppTheme.textSecondary,
                ),
                const SizedBox(width: AppTheme.gapSm),
                Expanded(child: Text(widget.title, style: AppTheme.cardTitle)),
                if (state.isStale)
                  Tooltip(
                    message: state.reason ?? '读取失败，显示旧内容',
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 3,
                      ),
                      decoration: BoxDecoration(
                        color: AppTheme.warnSoft,
                        borderRadius: BorderRadius.circular(999),
                      ),
                      child: const Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            Icons.history_rounded,
                            size: 12,
                            color: AppTheme.warn,
                          ),
                          SizedBox(width: 4),
                          Text(
                            '旧内容',
                            style: TextStyle(
                              fontSize: 11.5,
                              fontWeight: FontWeight.w500,
                              color: AppTheme.warn,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                IconButton(
                  onPressed: () => Navigator.of(context).pop(),
                  icon: const Icon(Icons.close),
                ),
              ],
            ),
          ),
          const Divider(height: 1),
          Expanded(
            child: switch (state.kind) {
              LogViewKind.loading => const _LogStateMessage(
                icon: Icons.hourglass_top_rounded,
                message: '读取中…',
              ),
              LogViewKind.unsupported => const _LogStateMessage(
                icon: Icons.block_rounded,
                message: '应用未提供日志能力。',
              ),
              LogViewKind.failed => _LogStateMessage(
                icon: Icons.error_outline_rounded,
                iconColor: AppTheme.danger,
                message: '日志读取失败：${state.reason}',
              ),
              LogViewKind.unknown => _LogStateMessage(
                icon: Icons.help_outline_rounded,
                message: '日志状态未知：${state.reason ?? ''}',
              ),
              LogViewKind.batch || LogViewKind.staleBatch =>
                state.batch!.entries.isEmpty
                    ? const _LogStateMessage(
                        icon: Icons.inbox_rounded,
                        message: '无日志（读取成功但为空）。',
                      )
                    : _LogList(
                        batch: state.batch!,
                        instanceScopeMissing: state.instanceScopeMissing,
                      ),
            },
          ),
        ],
      ),
    );
  }
}

class _LogStateMessage extends StatelessWidget {
  const _LogStateMessage({
    required this.icon,
    required this.message,
    this.iconColor = AppTheme.textTertiary,
  });

  final IconData icon;
  final String message;
  final Color iconColor;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 28, color: iconColor),
          const SizedBox(height: AppTheme.gapSm),
          Text(message, style: AppTheme.caption),
        ],
      ),
    );
  }
}

class _LogList extends StatelessWidget {
  const _LogList({required this.batch, required this.instanceScopeMissing});

  final LogBatch batch;
  final bool instanceScopeMissing;

  @override
  Widget build(BuildContext context) {
    final notes = <String>[
      if (instanceScopeMissing) '未提供实例范围',
      if (batch.truncated == true) '内容可能已截断（仅此可读范围）',
    ];
    return ListView(
      padding: const EdgeInsets.all(AppTheme.gapMd),
      children: [
        if (notes.isNotEmpty)
          Container(
            margin: const EdgeInsets.only(bottom: AppTheme.gapMd),
            padding: const EdgeInsets.symmetric(
              horizontal: AppTheme.gapMd,
              vertical: AppTheme.gapSm,
            ),
            decoration: BoxDecoration(
              color: AppTheme.neutralSoft,
              borderRadius: BorderRadius.circular(6),
            ),
            child: Row(
              children: [
                const Icon(
                  Icons.info_outline_rounded,
                  size: 13,
                  color: AppTheme.textSecondary,
                ),
                const SizedBox(width: AppTheme.gapSm),
                Expanded(
                  child: Text(notes.join('；'), style: AppTheme.captionMuted),
                ),
              ],
            ),
          ),
        for (final entry in batch.entries) _LogLine(entry: entry),
      ],
    );
  }
}

class _LogLine extends StatelessWidget {
  const _LogLine({required this.entry});

  final LogEntry entry;

  @override
  Widget build(BuildContext context) {
    final annotations = <String>[
      if (entry.timestamp != null)
        entry.timestamp!.toLocal().toString()
      else
        '无原始时间',
      if (entry.stream == LogStream.unknown) '分流未知' else entry.stream.name,
    ];
    final streamColor = switch (entry.stream) {
      LogStream.stderr => AppTheme.danger,
      LogStream.stdout => AppTheme.accent,
      _ => AppTheme.textTertiary,
    };
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '[${annotations.join(' · ')}]',
            style: TextStyle(
              color: streamColor.withValues(alpha: 0.8),
              fontFamily: 'monospace',
              fontSize: 11,
            ),
          ),
          Text(
            entry.text,
            style: const TextStyle(
              fontFamily: 'monospace',
              fontSize: 12,
              color: AppTheme.textPrimary,
            ),
          ),
        ],
      ),
    );
  }
}
