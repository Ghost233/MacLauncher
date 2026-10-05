import 'dart:io';

import 'package:launcher_core/launcher_core.dart';
import 'package:test/test.dart';

/// Controlled [UpdatePackageDownloader] (E08): records the arguments the
/// service forwarded and either throws [error] or returns a fixed result.
class _FakeDownloader implements UpdatePackageDownloader {
  Object? error;
  var calls = 0;
  Uri? source;
  String? targetPath;
  String? expectedSha256;
  bool? verifyChecksum;
  DownloadProgressCallback? progressCallback;
  DownloadCancellationToken? cancellationToken;

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
    this.source = source;
    this.targetPath = targetPath;
    this.expectedSha256 = expectedSha256;
    this.verifyChecksum = verifyChecksum;
    progressCallback = onProgress;
    this.cancellationToken = cancellationToken;
    final pending = error;
    if (pending != null) throw pending;
    return DownloadResult(
      path: targetPath,
      totalBytes: 42,
      sha256Hex: expectedSha256 ?? 'actual',
      checksumVerified: expectedSha256 != null,
      resumed: false,
    );
  }
}

void main() {
  late Directory temp;
  late _FakeDownloader downloader;
  late List<String> opened;
  late AppUpdateService service;

  AppUpdateService buildService({UpdatePackageOpener? opener}) =>
      AppUpdateService(
        layout: EndpointLayout(directory: temp.path),
        downloader: downloader,
        opener:
            opener ??
            (path) async {
              opened.add(path);
              return null;
            },
      );

  setUp(() {
    temp = Directory.systemTemp.createTempSync('app-update-service-test-');
    downloader = _FakeDownloader();
    opened = [];
    service = buildService();
  });

  tearDown(() => temp.deleteSync(recursive: true));

  group('targetPathFor', () {
    test('nests a sanitized file name under downloads/<projectId>', () {
      expect(service.downloadsDirectory, '${temp.path}/downloads');
      final path = service.targetPathFor(
        'project-a',
        Uri.parse('https://example.com/releases/My App 1.3.dmg'),
      );
      expect(path, '${temp.path}/downloads/project-a/My_App_1.3.dmg');
    });

    test('falls back to a stable name when the URL has no file segment', () {
      final path = service.targetPathFor(
        'project-a',
        Uri.parse('https://example.com/releases/'),
      );
      expect(path, '${temp.path}/downloads/project-a/update-package.dmg');
    });
  });

  group('downloadUpdate', () {
    final source = Uri.parse('https://example.com/app-1.3.0.dmg');

    test(
      'forwards sha256, progress and cancellation; opens the result',
      () async {
        final progress = <(int, int?)>[];
        final token = DownloadCancellationToken();
        final outcome = await service.downloadUpdate(
          projectId: 'project-a',
          source: source,
          expectedSha256: 'abc123',
          onProgress: (downloaded, total) => progress.add((downloaded, total)),
          cancellationToken: token,
        );

        expect(outcome, isA<AppUpdateDownloadCompleted>());
        final done = outcome as AppUpdateDownloadCompleted;
        expect(done.opened, isTrue);
        expect(done.openError, isNull);
        expect(
          done.result.path,
          '${temp.path}/downloads/project-a/app-1.3.0.dmg',
        );
        // The downloader received the verbatim digest and the callbacks.
        expect(downloader.source, source);
        expect(downloader.targetPath, done.result.path);
        expect(downloader.expectedSha256, 'abc123');
        expect(downloader.verifyChecksum, isTrue);
        expect(downloader.progressCallback, isNotNull);
        expect(downloader.cancellationToken, same(token));
        // The platform open ran on the downloaded path.
        expect(opened, [done.result.path]);
      },
    );

    test(
      'skips verification when the application provided no sha256',
      () async {
        final outcome = await service.downloadUpdate(
          projectId: 'project-a',
          source: source,
        );

        expect(outcome, isA<AppUpdateDownloadCompleted>());
        expect(downloader.expectedSha256, isNull);
        expect(downloader.verifyChecksum, isFalse);
        expect(
          (outcome as AppUpdateDownloadCompleted).result.checksumVerified,
          isFalse,
        );
      },
    );

    test('maps cancellation without opening anything', () async {
      downloader.error = const DownloadCancelledException();
      final outcome = await service.downloadUpdate(
        projectId: 'project-a',
        source: source,
      );

      expect(outcome, isA<AppUpdateDownloadCancelled>());
      expect(opened, isEmpty);
    });

    test('maps HTTP failures to a verbatim reason', () async {
      downloader.error = DownloadHttpException(source, 404);
      final outcome = await service.downloadUpdate(
        projectId: 'project-a',
        source: source,
      );

      expect(outcome, isA<AppUpdateDownloadFailed>());
      expect((outcome as AppUpdateDownloadFailed).reason, contains('404'));
      expect(opened, isEmpty);
    });

    test(
      'checksum mismatch wipes the .part state so a retry re-downloads',
      () async {
        final target = service.targetPathFor('project-a', source);
        Directory('$target.part').createSync(recursive: true);
        File('$target.part/manifest.json').writeAsStringSync('{}');
        downloader.error = const DownloadChecksumMismatchException(
          'expected',
          'actual',
        );

        final outcome = await service.downloadUpdate(
          projectId: 'project-a',
          source: source,
          expectedSha256: 'expected',
        );

        expect(outcome, isA<AppUpdateDownloadFailed>());
        expect(
          (outcome as AppUpdateDownloadFailed).reason,
          contains('sha256 mismatch'),
        );
        expect(Directory('$target.part').existsSync(), isFalse);
        expect(opened, isEmpty);
      },
    );

    test('maps unexpected errors to a failure instead of throwing', () async {
      downloader.error = StateError('weird');
      final outcome = await service.downloadUpdate(
        projectId: 'project-a',
        source: source,
      );

      expect(outcome, isA<AppUpdateDownloadFailed>());
      expect((outcome as AppUpdateDownloadFailed).reason, contains('weird'));
    });

    test('open failure still completes and reports the cause', () async {
      service = buildService(opener: (path) async => 'open 退出码 1：boom');
      final outcome = await service.downloadUpdate(
        projectId: 'project-a',
        source: source,
      );

      expect(outcome, isA<AppUpdateDownloadCompleted>());
      final done = outcome as AppUpdateDownloadCompleted;
      expect(done.opened, isFalse);
      expect(done.openError, 'open 退出码 1：boom');
    });
  });
}
