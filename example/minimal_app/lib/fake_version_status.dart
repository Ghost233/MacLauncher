import 'package:maclauncher_sdk/maclauncher_sdk.dart';

/// Which 「版本状况」answer the minimal demo reports.
///
/// minimal_app never queries a real update source; it reports a fixed,
/// configurable outcome so integrators can watch each of the three states
/// the launcher may render end to end.
enum DemoVersionStatusMode {
  /// A successful query that found a newer version.
  success,

  /// The update-source query failed.
  failure,

  /// No update channel: the callback is not registered at all, so the SDK
  /// auto-answers 「不支持更新」 exactly like a legacy application.
  unsupported;

  static DemoVersionStatusMode? parse(String value) =>
      values.asNameMap()[value];
}

/// Fixed fake values reported on [DemoVersionStatusMode.success].
///
/// These are demo data, not a real release: the URL uses the reserved
/// `example.invalid` TLD and must never be contacted.
const String kDemoCurrentVersion = '1.0.0';
const String kDemoLatestVersion = '1.1.0';
const String kDemoDownloadUrl =
    'https://example.invalid/minimal_app/minimal_app-1.1.0.dmg';
const String kDemoSha256 =
    '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef';

/// The fake failure reason reported on [DemoVersionStatusMode.failure].
const String kDemoFailureReason = 'mock 网络失败：更新源不可达';

/// Command-line flag selecting the reported mode.
const String kVersionStatusFlag = 'version-status';

/// Environment variable selecting the reported mode; the command-line flag
/// wins when both are present.
const String kVersionStatusEnv = 'MACLAUNCHER_VERSION_STATUS';

/// Resolves the configured mode.
///
/// Precedence: `--version-status=<mode>` > `MACLAUNCHER_VERSION_STATUS` >
/// [DemoVersionStatusMode.success]. Throws [FormatException] on an
/// unrecognized value so misconfiguration fails loudly at startup.
DemoVersionStatusMode resolveDemoVersionStatusMode(
  List<String> args,
  Map<String, String> environment,
) {
  DemoVersionStatusMode parseOrThrow(String value, String source) {
    final mode = DemoVersionStatusMode.parse(value);
    if (mode == null) {
      throw FormatException(
        'unknown $source mode "$value"; expected '
        '${DemoVersionStatusMode.values.map((m) => m.name).join('|')}',
      );
    }
    return mode;
  }

  for (final arg in args) {
    if (arg.startsWith('--$kVersionStatusFlag=')) {
      return parseOrThrow(
        arg.substring('--$kVersionStatusFlag='.length),
        '--$kVersionStatusFlag',
      );
    }
  }
  final fromEnv = environment[kVersionStatusEnv];
  if (fromEnv != null && fromEnv.isNotEmpty) {
    return parseOrThrow(fromEnv, kVersionStatusEnv);
  }
  return DemoVersionStatusMode.success;
}

/// Builds the app-level callbacks for [mode].
///
/// Returns null for [DemoVersionStatusMode.unsupported]: not registering
/// `onVersionStatus` is exactly how a real application without an update
/// channel behaves — the SDK declares no `versionStatus` capability and
/// auto-answers 「不支持更新」 if a query still arrives.
AppCallbacks? demoVersionStatusCallbacks(DemoVersionStatusMode mode) {
  switch (mode) {
    case DemoVersionStatusMode.success:
      return AppCallbacks(
        onVersionStatus: () async => VersionStatus(
          state: VersionQueryState.success,
          currentVersion: kDemoCurrentVersion,
          hasUpdate: true,
          latestVersion: kDemoLatestVersion,
          downloadUrl: kDemoDownloadUrl,
          sha256: kDemoSha256,
        ),
      );
    case DemoVersionStatusMode.failure:
      return AppCallbacks(
        onVersionStatus: () async => VersionStatus(
          state: VersionQueryState.failure,
          currentVersion: kDemoCurrentVersion,
          failureReason: kDemoFailureReason,
        ),
      );
    case DemoVersionStatusMode.unsupported:
      return null;
  }
}
