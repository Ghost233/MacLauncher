import 'dart:async';

import 'package:flutter/material.dart';
import 'package:launcher_core/launcher_core.dart';
import 'package:maclauncher_sdk/maclauncher_sdk.dart';

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
            padding: const EdgeInsets.all(12),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    widget.title,
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                ),
                if (state.isStale)
                  Tooltip(
                    message: state.reason ?? '读取失败，显示旧内容',
                    child: Chip(
                      label: const Text('旧内容'),
                      backgroundColor: Theme.of(context)
                          .colorScheme
                          .errorContainer,
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
              LogViewKind.loading => const Center(child: Text('读取中…')),
              LogViewKind.unsupported => const Center(
                child: Text('应用未提供日志能力。'),
              ),
              LogViewKind.failed => Center(
                child: Text('日志读取失败：${state.reason}'),
              ),
              LogViewKind.unknown => Center(
                child: Text('日志状态未知：${state.reason ?? ''}'),
              ),
              LogViewKind.batch || LogViewKind.staleBatch =>
                state.batch!.entries.isEmpty
                    ? const Center(child: Text('无日志（读取成功但为空）。'))
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
      padding: const EdgeInsets.all(12),
      children: [
        if (notes.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Text(
              notes.join('；'),
              style: Theme.of(context).textTheme.bodySmall
                  ?.copyWith(color: Theme.of(context).colorScheme.secondary),
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
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 1),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '[${annotations.join(' · ')}]',
            style: TextStyle(
              color: Theme.of(context).colorScheme.outline,
              fontFamily: 'monospace',
              fontSize: 11,
            ),
          ),
          Text(
            entry.text,
            style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
          ),
        ],
      ),
    );
  }
}
