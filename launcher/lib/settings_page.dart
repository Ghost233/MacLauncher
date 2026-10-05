import 'package:flutter/material.dart';
import 'package:launcher_core/launcher_core.dart';

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
  });

  final PreferenceStore preferences;
  final UpdateCheckCallback onCheckNow;

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  late bool _checkOnLaunch;
  late bool _autoDownload;
  var _checking = false;

  @override
  void initState() {
    super.initState();
    _checkOnLaunch = widget.preferences.updateCheckOnLaunch;
    _autoDownload = widget.preferences.updateAutoDownload;
  }

  Future<void> _toggle({
    required bool value,
    required Future<void> Function(bool) persist,
    required void Function() apply,
  }) async {
    await persist(value);
    if (mounted) setState(apply);
  }

  Future<void> _checkNow() async {
    if (_checking) return;
    setState(() => _checking = true);
    try {
      await widget.onCheckNow();
    } finally {
      if (mounted) setState(() => _checking = false);
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
                        apply: () => _checkOnLaunch = value,
                      ),
                    ),
                    _SwitchRow(
                      key: const ValueKey('update-auto-download'),
                      label: '自动下载新版本',
                      value: _autoDownload,
                      onChanged: (value) => _toggle(
                        value: value,
                        persist: widget.preferences.setUpdateAutoDownload,
                        apply: () => _autoDownload = value,
                      ),
                    ),
                    _SwitchRow(
                      key: const ValueKey('update-auto-install'),
                      label: '自动安装',
                      value: widget.preferences.updateAutoInstall,
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
