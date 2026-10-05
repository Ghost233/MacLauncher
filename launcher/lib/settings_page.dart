import 'package:flutter/material.dart';
import 'package:launcher_core/launcher_core.dart';

import 'self_update_flow.dart';
import 'theme.dart';

/// Manual update-check entry. The real checker arrives with the update
/// checker ticket (#29/#31); callers inject it through this seam so the
/// settings page never changes shape when it lands.
typedef UpdateCheckCallback = Future<void> Function();

/// The standalone settings page: launcher-wide update preferences and a
/// manual update check. Reached from the management page's app-bar gear.
class SettingsPage extends StatefulWidget {
  const SettingsPage({
    super.key,
    required this.preferences,
    required this.onCheckNow,
    this.selfUpdate,
  });

  final PreferenceStore preferences;
  final UpdateCheckCallback onCheckNow;

  /// The real self-update flow (#31). When injected, 立即检查更新 runs the
  /// checker and the page renders 有新版 / 已是最新 / 失败 from the typed
  /// result; when absent the legacy [onCheckNow] placeholder runs instead.
  final SelfUpdateFlow? selfUpdate;

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  // All three rows read this local state (single source of truth for the
  // page); it is initialized from the store once.
  late bool _checkOnLaunch;
  late bool _autoDownload;
  late bool _autoInstall;
  var _checking = false;

  /// Latest manual check outcome; null until the first check or when the
  /// legacy [SettingsPage.onCheckNow] placeholder path is in use.
  UpdateCheckResult? _checkResult;

  @override
  void initState() {
    super.initState();
    _checkOnLaunch = widget.preferences.updateCheckOnLaunch;
    _autoDownload = widget.preferences.updateAutoDownload;
    _autoInstall = widget.preferences.updateAutoInstall;
  }

  /// Optimistic toggle: apply immediately so the switch never feels stuck,
  /// persist in the background, and roll back with a hint if the atomic
  /// write fails.
  Future<void> _toggle({
    required bool value,
    required Future<void> Function(bool) persist,
    required void Function(bool) apply,
  }) async {
    setState(() => apply(value));
    try {
      await persist(value);
    } catch (_) {
      if (!mounted) return;
      setState(() => apply(!value));
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('偏好保存失败，请重试。')));
    }
  }

  Future<void> _checkNow() async {
    if (_checking) return;
    setState(() => _checking = true);
    try {
      final flow = widget.selfUpdate;
      if (flow != null) {
        // Real implementation (#31): the typed result is rendered below the
        // button; failures stay visible here instead of a toast.
        final result = await flow.checkNow();
        if (mounted) setState(() => _checkResult = result);
      } else {
        await widget.onCheckNow();
      }
    } finally {
      if (mounted) setState(() => _checking = false);
    }
  }

  /// Three-state manual check rendering: 有新版 (with a download entry when
  /// the release carries a DMG address) / 已是最新 / 失败. Text comes only
  /// from the typed [UpdateCheckResult]; nothing is invented.
  Widget _checkResultArea() {
    final result = _checkResult;
    if (result == null) return const SizedBox.shrink();
    switch (result) {
      case UpdateCheckFailure(:final reason):
        return _ResultLine(
          key: const ValueKey('update-check-failed'),
          color: AppTheme.danger,
          text: '检查失败：$reason',
        );
      case UpdateCheckSuccess(hasUpdate: false, :final latestVersion):
        return _ResultLine(
          key: const ValueKey('update-check-latest'),
          color: AppTheme.ok,
          text: '已是最新版本（$latestVersion）。',
        );
      case UpdateCheckSuccess(
        hasUpdate: true,
        :final latestVersion,
        :final dmgDownloadUrl,
        :final sha256,
      ):
        if (dmgDownloadUrl == null) {
          return _ResultLine(
            key: const ValueKey('update-check-no-url'),
            color: AppTheme.warn,
            text: '发现新版本 $latestVersion，但该版本未提供下载地址。',
          );
        }
        return Row(
          key: const ValueKey('update-check-available'),
          children: [
            Expanded(
              child: Text(
                '发现新版本 $latestVersion。',
                style: AppTheme.caption.copyWith(color: AppTheme.accent),
              ),
            ),
            FilledButton(
              key: const ValueKey('update-download-entry'),
              onPressed: () {
                // Starts the shared flow; the management page surfaces the
                // progress/result dialog on top of this route.
                // ignore: discarded_futures
                widget.selfUpdate?.startDownload(
                  latestVersion: latestVersion,
                  downloadUrl: dmgDownloadUrl,
                  sha256: sha256,
                );
              },
              style: FilledButton.styleFrom(
                backgroundColor: AppTheme.accent,
                foregroundColor: Colors.white,
                minimumSize: const Size(0, 28),
                padding: const EdgeInsets.symmetric(horizontal: 12),
                textStyle: const TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w500,
                ),
              ),
              child: const Text('下载新版本'),
            ),
          ],
        );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('设置')),
      body: Align(
        alignment: Alignment.topCenter,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 640),
          child: ListView(
            padding: const EdgeInsets.all(AppTheme.gapXl),
            children: [
              Container(
                decoration: AppTheme.cardDecoration(),
                padding: const EdgeInsets.all(AppTheme.gapLg),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text('更新', style: AppTheme.sectionLabel),
                    const SizedBox(height: AppTheme.gapMd),
                    _SwitchRow(
                      key: const ValueKey('update-check-on-launch'),
                      label: '启动时检查新版本',
                      value: _checkOnLaunch,
                      onChanged: (value) => _toggle(
                        value: value,
                        persist: widget.preferences.setUpdateCheckOnLaunch,
                        apply: (v) => _checkOnLaunch = v,
                      ),
                    ),
                    _SwitchRow(
                      key: const ValueKey('update-auto-download'),
                      label: '自动下载新版本',
                      value: _autoDownload,
                      onChanged: (value) => _toggle(
                        value: value,
                        persist: widget.preferences.setUpdateAutoDownload,
                        apply: (v) => _autoDownload = v,
                      ),
                    ),
                    _SwitchRow(
                      key: const ValueKey('update-auto-install'),
                      label: '自动安装',
                      value: _autoInstall,
                      // Reserved preference (ADR 0002): stays disabled until
                      // a signing certificate exists.
                      onChanged: null,
                      note: '需要签名证书，暂不可用',
                    ),
                    const Padding(
                      padding: EdgeInsets.symmetric(vertical: AppTheme.gapMd),
                      child: Divider(),
                    ),
                    Row(
                      children: [
                        FilledButton.icon(
                          key: const ValueKey('update-check-now'),
                          onPressed: _checking ? null : _checkNow,
                          icon: _checking
                              ? const SizedBox(
                                  width: 14,
                                  height: 14,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                    color: Colors.white,
                                  ),
                                )
                              : const Icon(Icons.system_update_alt, size: 16),
                          label: const Text('立即检查更新'),
                          style: FilledButton.styleFrom(
                            backgroundColor: AppTheme.accent,
                            foregroundColor: Colors.white,
                            textStyle: const TextStyle(
                              fontSize: 13,
                              fontWeight: FontWeight.w500,
                            ),
                            minimumSize: const Size(0, 32),
                            padding: const EdgeInsets.symmetric(horizontal: 14),
                          ),
                        ),
                        const SizedBox(width: AppTheme.gapMd),
                        const Expanded(
                          child: Text(
                            '手动检查启动器与已关联应用的新版本。',
                            style: AppTheme.captionMuted,
                          ),
                        ),
                      ],
                    ),
                    if (_checkResult != null) ...[
                      const SizedBox(height: AppTheme.gapSm),
                      _checkResultArea(),
                    ],
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// One preference row: label on the left, switch on the right. A disabled
/// row greys out the label and can carry a discoverable reason below.
class _SwitchRow extends StatelessWidget {
  const _SwitchRow({
    super.key,
    required this.label,
    required this.value,
    required this.onChanged,
    this.note,
  });

  final String label;
  final bool value;
  final ValueChanged<bool>? onChanged;
  final String? note;

  @override
  Widget build(BuildContext context) {
    final enabled = onChanged != null;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: AppTheme.gapXs),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  label,
                  style: enabled
                      ? AppTheme.body
                      : AppTheme.body.copyWith(color: AppTheme.textTertiary),
                ),
              ),
              Switch(value: value, onChanged: onChanged),
            ],
          ),
          if (note != null)
            Padding(
              padding: const EdgeInsets.only(top: AppTheme.gapXs),
              child: Text(note!, style: AppTheme.captionMuted),
            ),
        ],
      ),
    );
  }
}

/// One colored result line under the 立即检查更新 button.
class _ResultLine extends StatelessWidget {
  const _ResultLine({super.key, required this.color, required this.text});

  final Color color;
  final String text;

  @override
  Widget build(BuildContext context) {
    return Text(text, style: AppTheme.caption.copyWith(color: color));
  }
}
