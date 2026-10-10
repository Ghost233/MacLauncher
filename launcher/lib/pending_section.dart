import 'package:flutter/material.dart';
import 'package:launcher_core/launcher_core.dart';

import 'theme.dart';

/// The 待批准 section: self-discovered applications that shook hands with an
/// unknown identity and wait for a one-time user decision. Pure display —
/// approve/ignore orchestration (stores, toasts) lives in the page layer
/// (E05 界面边界); cards only raise intent.
class PendingSection extends StatelessWidget {
  const PendingSection({
    super.key,
    required this.projects,
    required this.onApprove,
    required this.onIgnore,
  });

  /// Pending discoveries, already sorted by first-seen (registry order).
  final List<PendingProject> projects;
  final void Function(PendingProject project) onApprove;
  final void Function(PendingProject project) onIgnore;

  @override
  Widget build(BuildContext context) {
    if (projects.isEmpty) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text('待批准', style: AppTheme.sectionLabel),
        const SizedBox(height: AppTheme.gapXs),
        const Text('以下应用主动连接了启动器，等待你的一次性批准。', style: AppTheme.captionMuted),
        const SizedBox(height: AppTheme.gapMd),
        for (final project in projects)
          Padding(
            padding: const EdgeInsets.only(bottom: AppTheme.gapMd),
            child: PendingProjectCard(
              key: ValueKey('pending/${project.projectId}'),
              project: project,
              onApprove: () => onApprove(project),
              onIgnore: () => onIgnore(project),
            ),
          ),
        const Padding(
          padding: EdgeInsets.symmetric(vertical: AppTheme.gapMd),
          child: Divider(),
        ),
      ],
    );
  }
}

/// One pending discovery: identity, declared services, source process and
/// first-seen time, with 批准…/忽略 actions.
class PendingProjectCard extends StatelessWidget {
  const PendingProjectCard({
    super.key,
    required this.project,
    required this.onApprove,
    required this.onIgnore,
  });

  final PendingProject project;
  final VoidCallback onApprove;
  final VoidCallback onIgnore;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: AppTheme.cardDecoration(),
      child: Padding(
        padding: const EdgeInsets.all(AppTheme.gapLg),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            CardHeader(
              title: Text(project.displayName, style: AppTheme.cardTitle),
              actions: [
                FilledButton.tonalIcon(
                  onPressed: onApprove,
                  icon: const Icon(Icons.check_circle_outline, size: 14),
                  label: const Text('批准…'),
                  style: FilledButton.styleFrom(
                    backgroundColor: AppTheme.accentSoft,
                    foregroundColor: AppTheme.accent,
                    textStyle: const TextStyle(
                      fontSize: 12.5,
                      fontWeight: FontWeight.w500,
                    ),
                    minimumSize: const Size(0, 30),
                    padding: const EdgeInsets.symmetric(horizontal: 10),
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                ),
                TextButton(
                  onPressed: onIgnore,
                  style: TextButton.styleFrom(
                    foregroundColor: AppTheme.neutral,
                    textStyle: const TextStyle(
                      fontSize: 12.5,
                      fontWeight: FontWeight.w500,
                    ),
                    minimumSize: const Size(0, 30),
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                  child: const Text('忽略'),
                ),
              ],
            ),
            const SizedBox(height: AppTheme.gapXs),
            Text('项目标识：${project.projectId}', style: AppTheme.monoMuted),
            const SizedBox(height: AppTheme.gapXs),
            Text(
              project.services.isEmpty
                  ? '服务：无（未声明）'
                  : '服务：${project.services.map((s) => '${s.name}（${s.id}）').join('、')}',
              style: AppTheme.captionMuted,
            ),
            const SizedBox(height: AppTheme.gapXs),
            Text(
              '来源进程：${project.sourceProcessPath ?? '未知'}',
              style: AppTheme.monoMuted,
            ),
            const SizedBox(height: AppTheme.gapXs),
            Text(
              '首次发现：${project.firstSeenAt.toLocal()}',
              style: AppTheme.captionMuted,
            ),
          ],
        ),
      ),
    );
  }
}
