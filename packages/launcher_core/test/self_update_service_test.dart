import 'dart:io';

import 'package:launcher_core/launcher_core.dart';
import 'package:test/test.dart';

class _FakeChecker extends UpdateChecker {
  _FakeChecker(String currentVersion, this.result)
    : super(currentVersion: currentVersion);

  final UpdateCheckResult result;

  @override
  Future<UpdateCheckResult> checkForUpdate() async => result;
}

class _FakeDownloader implements UpdatePackageDownloader {
  Object? error;
  Uri? lastSource;
  String? lastTarget;
  String? lastSha256;
  bool? lastVerify;
  DownloadCancellationToken? lastToken;
  final progress = <(int, int?)>[];
  var calls = 0;

  @override
  Future<DownloadResult> download(
    Uri source,
    String targetPath, {
    String? expectedSha256,
    bool verifyChecksum = true,
    DownloadProgressCallback? onProgress,
    DownloadCancellationToken? cancellationToken,
  }) async {
    calls++;
    lastSource = source;
    lastTarget = targetPath;
    lastSha256 = expectedSha256;
    lastVerify = verifyChecksum;
    lastToken = cancellationToken;
    onProgress?.call(50, 100);
    progress.add((50, 100));
    final failure = error;
    if (failure != null) throw failure;
    return DownloadResult(
      path: targetPath,
      totalBytes: 100,
      sha256Hex: expectedSha256 ?? 'actual',
      checksumVerified: verifyChecksum && expectedSha256 != null,
      resumed: false,
    );
  }
}

SelfUpdateService _service({
  required String dir,
  String? version = '1.0.0',
  bool resolverThrows = false,
  _FakeChecker? checker,
  List<String>? seenVersions,
  _FakeDownloader? downloader,
  Future<String?> Function(String)? opener,
}) {
  return SelfUpdateService(
    layout: EndpointLayout(directory: dir),
    versionResolver: () async {
      if (resolverThrows) throw StateError('no bundle');
      return version;
    },
    checkerFactory: (v) {
      seenVersions?.add(v);
      return checker ??
          _FakeChecker(
            v,
            const UpdateCheckSuccess(hasUpdate: false, latestVersion: '1.0.0'),
          );
    },
    downloader: downloader ?? _FakeDownloader(),
    opener: opener ?? (_) async => null,
  );
}

void main() {
  late Directory temp;
  late String dir;

  setUp(() {
    temp = Directory.systemTemp.createTempSync('self-update-test-');
    dir = temp.path;
  });

  tearDown(() {
    if (temp.existsSync()) temp.deleteSync(recursive: true);
  });

  group('directory layout', () {
    test('downloads directory follows the EndpointLayout convention', () {
      expect(_service(dir: dir).downloadsDirectory, '$dir/downloads/self');
    });

    test('target path sanitizes the URL file name', () {
      final service = _service(dir: dir);
      expect(
        service.targetPathFor(Uri.parse('https://x/MacLauncher-1.3.0 (1).dmg')),
        '$dir/downloads/self/MacLauncher-1.3.0__1_.dmg',
      );
    });

    test('target path falls back when the URL has no file name', () {
      final service = _service(dir: dir);
      expect(
        service.targetPathFor(Uri.parse('https://x/')),
        '$dir/downloads/self/self-update.dmg',
      );
    });
  });

  group('checkForUpdate', () {
    test('resolver failure is a typed failure, never a throw', () async {
      final result = await _service(
        dir: dir,
        resolverThrows: true,
      ).checkForUpdate();
      expect(result, isA<UpdateCheckFailure>());
      expect((result as UpdateCheckFailure).reason, '读取当前版本失败。');
    });

    test('unavailable build channel is a typed failure', () async {
      final result = await _service(dir: dir, version: null).checkForUpdate();
      expect(result, isA<UpdateCheckFailure>());
      expect((result as UpdateCheckFailure).reason, '无法确定当前版本（构建通道不可用）。');
    });

    test('non-semver current version is a typed failure', () async {
      final result = await _service(
        dir: dir,
        version: 'dev-build',
      ).checkForUpdate();
      expect(result, isA<UpdateCheckFailure>());
      expect((result as UpdateCheckFailure).reason, contains('不是语义化版本'));
    });

    test('resolved version reaches the checker factory per check', () async {
      final seen = <String>[];
      await _service(
        dir: dir,
        version: '1.2.3',
        seenVersions: seen,
      ).checkForUpdate();
      expect(seen, ['1.2.3']);
    });
  });

  group('downloadUpdate', () {
    final source = Uri.parse('https://x/MacLauncher-1.3.0.dmg');

    test('forwards sha256, progress and the cancellation token', () async {
      final downloader = _FakeDownloader();
      final token = DownloadCancellationToken();
      final progress = <(int, int?)>[];
      final outcome = await _service(dir: dir, downloader: downloader)
          .downloadUpdate(
            source: source,
            expectedSha256: 'abc',
            cancellationToken: token,
            onProgress: (d, t) => progress.add((d, t)),
          );
      expect(outcome, isA<SelfUpdateDownloadCompleted>());
      expect((outcome as SelfUpdateDownloadCompleted).opened, isTrue);
      expect(downloader.lastSha256, 'abc');
      expect(downloader.lastVerify, isTrue);
      expect(downloader.lastToken, same(token));
      expect(progress, [(50, 100)]);
    });

    test('no published sha256 means no verification', () async {
      final downloader = _FakeDownloader();
      final outcome = await _service(
        dir: dir,
        downloader: downloader,
      ).downloadUpdate(source: source);
      final completed = outcome as SelfUpdateDownloadCompleted;
      expect(downloader.lastVerify, isFalse);
      expect(completed.result.checksumVerified, isFalse);
    });

    test('skipVerification disables verification despite a digest', () async {
      final downloader = _FakeDownloader();
      await _service(dir: dir, downloader: downloader).downloadUpdate(
        source: source,
        expectedSha256: 'abc',
        skipVerification: true,
      );
      expect(downloader.lastVerify, isFalse);
    });

    test('cancellation maps to the typed cancelled outcome', () async {
      final downloader = _FakeDownloader()
        ..error = DownloadCancelledException();
      final outcome = await _service(
        dir: dir,
        downloader: downloader,
      ).downloadUpdate(source: source, expectedSha256: 'abc');
      expect(outcome, isA<SelfUpdateDownloadCancelled>());
    });

    test('checksum mismatch is typed with expected and actual', () async {
      final downloader = _FakeDownloader()
        ..error = const DownloadChecksumMismatchException(
          'expected-hash',
          'actual-hash',
        );
      final outcome = await _service(
        dir: dir,
        downloader: downloader,
      ).downloadUpdate(source: source, expectedSha256: 'expected-hash');
      final mismatch = outcome as SelfUpdateDownloadChecksumMismatch;
      expect(mismatch.expected, 'expected-hash');
      expect(mismatch.actual, 'actual-hash');
    });

    test('http failure maps to a user-presentable reason', () async {
      final downloader = _FakeDownloader()
        ..error = DownloadHttpException(source, 404);
      final outcome = await _service(
        dir: dir,
        downloader: downloader,
      ).downloadUpdate(source: source);
      expect(outcome, isA<SelfUpdateDownloadFailed>());
      expect((outcome as SelfUpdateDownloadFailed).reason, contains('404'));
    });

    test('unexpected errors map to a failure, never a throw', () async {
      final downloader = _FakeDownloader()..error = StateError('disk full');
      final outcome = await _service(
        dir: dir,
        downloader: downloader,
      ).downloadUpdate(source: source);
      expect(outcome, isA<SelfUpdateDownloadFailed>());
      expect(
        (outcome as SelfUpdateDownloadFailed).reason,
        contains('disk full'),
      );
    });

    test('an opener error stays on the completed outcome', () async {
      final outcome = await _service(
        dir: dir,
        opener: (_) async => 'open 退出码 1',
      ).downloadUpdate(source: source);
      final completed = outcome as SelfUpdateDownloadCompleted;
      expect(completed.opened, isFalse);
      expect(completed.openError, 'open 退出码 1');
    });
  });
}
