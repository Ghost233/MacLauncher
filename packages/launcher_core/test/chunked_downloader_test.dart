import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:launcher_core/launcher_core.dart';
import 'package:test/test.dart';

/// A controllable local HTTP server serving one payload, with optional Range
/// support, deterministic connection-kill and an overlap gate for concurrency
/// evidence.
class _TestServer {
  _TestServer({required this.payload, this.supportRanges = true});

  final Uint8List payload;
  final bool supportRanges;

  late final HttpServer _server;

  /// Ranges actually answered with 206, as (start, endInclusive).
  final List<(int, int)> servedRanges = [];

  int activeRangeHandlers = 0;
  int maxActiveRangeHandlers = 0;
  int completedRangeResponses = 0;

  /// Once this many range responses completed, further range requests get
  /// their connection destroyed (simulates a crashed download / flaky peer).
  int? destroyAfterCompleted;

  /// 1-based ordinal of the range request to hold until [releaseHeld]
  /// completes; 0 disables. [heldRequestSeen] completes when that request
  /// arrives, so tests can act while the response is deterministically held.
  int holdOnRangeRequest = 0;
  final Completer<void> releaseHeld = Completer<void>();
  final Completer<void> heldRequestSeen = Completer<void>();
  int _rangeRequestOrdinal = 0;

  Completer<void>? _overlapGate;
  int _overlapTarget = 0;

  Uri get uri => Uri.parse('http://127.0.0.1:${_server.port}/file');

  /// Holds range responses until [n] of them are concurrently in flight.
  void requireOverlap(int n) {
    _overlapTarget = n;
    _overlapGate = Completer<void>();
  }

  Future<void> start() async {
    _server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    _server.listen(_handle);
  }

  Future<void> stop() => _server.close(force: true);

  Future<void> _handle(HttpRequest request) async {
    final response = request.response;
    if (request.method == 'HEAD') {
      response.contentLength = payload.length;
      if (supportRanges) {
        response.headers.set(HttpHeaders.acceptRangesHeader, 'bytes');
      }
      await response.close();
      return;
    }
    final rangeHeader = request.headers.value(HttpHeaders.rangeHeader);
    final match = rangeHeader == null
        ? null
        : RegExp(r'^bytes=(\d+)-(\d+)$').firstMatch(rangeHeader);
    if (!supportRanges || match == null) {
      response.contentLength = payload.length;
      response.add(payload);
      await response.close();
      return;
    }

    final start = int.parse(match[1]!);
    final end = int.parse(match[2]!);
    _rangeRequestOrdinal++;
    if (_rangeRequestOrdinal == holdOnRangeRequest) {
      heldRequestSeen.complete();
      await releaseHeld.future.timeout(
        const Duration(seconds: 10),
        onTimeout: () {},
      );
    }
    if (destroyAfterCompleted != null &&
        completedRangeResponses >= destroyAfterCompleted!) {
      final socket = await response.detachSocket(writeHeaders: false);
      socket.destroy();
      return;
    }

    activeRangeHandlers++;
    if (activeRangeHandlers > maxActiveRangeHandlers) {
      maxActiveRangeHandlers = activeRangeHandlers;
    }
    servedRanges.add((start, end));
    final gate = _overlapGate;
    if (gate != null) {
      if (activeRangeHandlers >= _overlapTarget && !gate.isCompleted) {
        gate.complete();
      }
      // Bounded wait keeps the test deterministic without risking a hang.
      await gate.future.timeout(const Duration(seconds: 5), onTimeout: () {});
    }

    response.statusCode = HttpStatus.partialContent;
    response.headers.set(
      HttpHeaders.contentRangeHeader,
      'bytes $start-$end/${payload.length}',
    );
    response.contentLength = end - start + 1;
    const slice = 2048;
    for (var p = start; p <= end; p += slice) {
      response.add(payload.sublist(p, min(p + slice, end + 1)));
      await response.flush();
    }
    await response.close();
    completedRangeResponses++;
    activeRangeHandlers--;
  }
}

Uint8List _payload(int size, int seed) {
  final random = Random(seed);
  return Uint8List.fromList([
    for (var i = 0; i < size; i++) random.nextInt(256),
  ]);
}

String _sha256Hex(Uint8List bytes) => sha256.convert(bytes).toString();

void main() {
  late Directory tempDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('chunked_downloader_test');
  });

  tearDown(() async {
    if (await tempDir.exists()) await tempDir.delete(recursive: true);
  });

  String targetPath(String name) => '${tempDir.path}/$name';

  group('chunked download', () {
    test('downloads correct bytes, verifies sha256, cleans up .part', () async {
      // 16 full chunks plus a short tail chunk.
      final payload = _payload(16 * 8192 + 1234, 1);
      final server = _TestServer(payload: payload);
      await server.start();
      addTearDown(server.stop);

      final target = targetPath('app.dmg');
      final result = await ChunkedDownloader().download(
        server.uri,
        target,
        chunkSizeBytes: 8192,
        expectedSha256: _sha256Hex(payload),
      );

      expect(await File(target).readAsBytes(), equals(payload));
      expect(result.totalBytes, payload.length);
      expect(result.sha256Hex, _sha256Hex(payload));
      expect(result.checksumVerified, isTrue);
      expect(result.resumed, isFalse);
      expect(await Directory('$target.part').exists(), isFalse);
      expect(await ChunkedDownloader.hasResumableState(target), isFalse);
      // Every chunk was fetched exactly once, covering the whole payload.
      expect(server.servedRanges, hasLength(17));
      final covered = <int>{};
      for (final (start, end) in server.servedRanges) {
        for (var i = start; i <= end; i++) {
          expect(covered.add(i), isTrue, reason: 'byte $i fetched twice');
        }
      }
      expect(covered.length, payload.length);
    });

    test('fetches chunks concurrently', () async {
      final payload = _payload(8 * 8192, 2);
      final server = _TestServer(payload: payload)..requireOverlap(3);
      await server.start();
      addTearDown(server.stop);

      await ChunkedDownloader().download(
        server.uri,
        targetPath('concurrent.dmg'),
        concurrency: 4,
        chunkSizeBytes: 8192,
        expectedSha256: _sha256Hex(payload),
      );

      // The gate only releases with 3 in-flight range requests.
      expect(server.maxActiveRangeHandlers, greaterThanOrEqualTo(3));
    });

    test(
      'progress is monotonically non-decreasing and ends at total',
      () async {
        final payload = _payload(8 * 8192, 3);
        final server = _TestServer(payload: payload);
        await server.start();
        addTearDown(server.stop);

        final events = <(int, int?)>[];
        await ChunkedDownloader().download(
          server.uri,
          targetPath('progress.dmg'),
          chunkSizeBytes: 8192,
          onProgress: (downloaded, total) => events.add((downloaded, total)),
        );

        expect(events, isNotEmpty);
        for (var i = 1; i < events.length; i++) {
          expect(
            events[i].$1,
            greaterThanOrEqualTo(events[i - 1].$1),
            reason: 'event $i regressed: ${events[i - 1]} -> ${events[i]}',
          );
        }
        expect(events.last, (payload.length, payload.length));
      },
    );

    test(
      'interrupted download resumes without re-fetching done chunks',
      () async {
        final payload = _payload(16 * 8192, 4);
        final server = _TestServer(payload: payload)..destroyAfterCompleted = 3;
        await server.start();
        addTearDown(server.stop);

        final target = targetPath('resume.dmg');
        Future<DownloadResult> run() => ChunkedDownloader().download(
          server.uri,
          target,
          concurrency: 1,
          chunkSizeBytes: 8192,
          expectedSha256: _sha256Hex(payload),
        );

        await expectLater(run(), throwsA(isA<DownloadException>()));

        // Deterministic interruption evidence: exactly 3 chunks persisted.
        final manifest = jsonDecode(
          await File('$target.part/manifest.json').readAsString(),
        ) as Map<String, Object?>;
        final chunks = (manifest['chunks']! as List)
            .cast<Map<String, Object?>>();
        final doneOffsets = [
          for (final chunk in chunks)
            if (chunk['complete'] == true) chunk['offset']! as int,
        ];
        expect(doneOffsets, hasLength(3));
        expect(await ChunkedDownloader.hasResumableState(target), isTrue);

        server.destroyAfterCompleted = null;
        final servedBefore = server.servedRanges.length;
        final result = await run();

        expect(result.resumed, isTrue);
        expect(result.checksumVerified, isTrue);
        expect(await File(target).readAsBytes(), equals(payload));
        expect(await Directory('$target.part').exists(), isFalse);
        // Resume fetched only the missing chunks.
        final resumedRanges = server.servedRanges.sublist(servedBefore);
        expect(resumedRanges, hasLength(13));
        for (final (start, _) in resumedRanges) {
          expect(doneOffsets, isNot(contains(start)));
        }
      },
    );

    test(
      'stale .part state for a different URL is wiped and restarted',
      () async {
        final payload = _payload(4 * 8192, 5);
        final server = _TestServer(payload: payload);
        await server.start();
        addTearDown(server.stop);

        final target = targetPath('stale.dmg');
        final partDir = Directory('$target.part')..createSync(recursive: true);
        File('${partDir.path}/manifest.json').writeAsStringSync(
          jsonEncode({'version': 1, 'url': 'http://elsewhere/old'}),
        );

        final result = await ChunkedDownloader().download(
          server.uri,
          target,
          chunkSizeBytes: 8192,
          expectedSha256: _sha256Hex(payload),
        );

        expect(result.resumed, isFalse);
        expect(await File(target).readAsBytes(), equals(payload));
      },
    );
  });

  group('cancellation', () {
    test('cancel keeps persisted chunks and the download resumes', () async {
      final payload = _payload(8 * 8192, 6);
      // Chunk 1 downloads fully; chunk 2 is held open so the cancel lands
      // deterministically mid-download with exactly one chunk persisted.
      final server = _TestServer(payload: payload)..holdOnRangeRequest = 2;
      await server.start();
      addTearDown(server.stop);

      final target = targetPath('cancel.dmg');
      final token = DownloadCancellationToken();
      final download = ChunkedDownloader().download(
        server.uri,
        target,
        concurrency: 1,
        chunkSizeBytes: 8192,
        cancellationToken: token,
      );
      await server.heldRequestSeen.future;
      token.cancel();
      server.releaseHeld.complete();
      await expectLater(download, throwsA(isA<DownloadCancelledException>()));

      // Cancelled state stays on disk, resumable.
      expect(await ChunkedDownloader.hasResumableState(target), isTrue);
      final manifest = jsonDecode(
        await File('$target.part/manifest.json').readAsString(),
      ) as Map<String, Object?>;
      final doneCount = (manifest['chunks']! as List)
          .whereType<Map<String, Object?>>()
          .where((chunk) => chunk['complete'] == true)
          .length;
      expect(doneCount, 1);
      // The chunk interrupted mid-flight left no partial file behind.
      expect(await File('$target.part/chunk-000001').exists(), isFalse);

      final result = await ChunkedDownloader().download(
        server.uri,
        target,
        concurrency: 2,
        chunkSizeBytes: 8192,
        expectedSha256: _sha256Hex(payload),
      );
      expect(result.resumed, isTrue);
      expect(result.checksumVerified, isTrue);
      expect(await File(target).readAsBytes(), equals(payload));
    });

    test('cancel before start performs no network work', () async {
      final payload = _payload(8192, 7);
      final server = _TestServer(payload: payload);
      await server.start();
      addTearDown(server.stop);

      final token = DownloadCancellationToken()..cancel();
      await expectLater(
        ChunkedDownloader().download(
          server.uri,
          targetPath('never.dmg'),
          cancellationToken: token,
        ),
        throwsA(isA<DownloadCancelledException>()),
      );
      expect(server.servedRanges, isEmpty);
    });
  });

  group('checksum', () {
    test('matching sha256 verifies', () async {
      final payload = _payload(2 * 8192, 8);
      final server = _TestServer(payload: payload);
      await server.start();
      addTearDown(server.stop);

      final result = await ChunkedDownloader().download(
        server.uri,
        targetPath('ok.dmg'),
        chunkSizeBytes: 8192,
        expectedSha256: _sha256Hex(payload),
      );
      expect(result.checksumVerified, isTrue);
    });

    test('mismatch fails, deletes target, keeps .part state', () async {
      final payload = _payload(2 * 8192, 9);
      final server = _TestServer(payload: payload);
      await server.start();
      addTearDown(server.stop);

      final target = targetPath('bad.dmg');
      await expectLater(
        ChunkedDownloader().download(
          server.uri,
          target,
          chunkSizeBytes: 8192,
          expectedSha256: _sha256Hex(_payload(64, 99)),
        ),
        throwsA(isA<DownloadChecksumMismatchException>()),
      );
      expect(await File(target).exists(), isFalse);
      expect(await ChunkedDownloader.hasResumableState(target), isTrue);
    });

    test('discardResumableState breaks the mismatch retry dead end', () async {
      final payload = _payload(2 * 8192, 19);
      final server = _TestServer(payload: payload);
      await server.start();
      addTearDown(server.stop);

      final target = targetPath('bad-retry.dmg');
      // Wrong expectation: the download completes but verification fails,
      // and the corrupt-by-expectation .part state stays on disk.
      await expectLater(
        ChunkedDownloader().download(
          server.uri,
          target,
          chunkSizeBytes: 8192,
          expectedSha256: _sha256Hex(_payload(64, 99)),
        ),
        throwsA(isA<DownloadChecksumMismatchException>()),
      );
      expect(await ChunkedDownloader.hasResumableState(target), isTrue);

      // Caller wipes the state; the retry then succeeds from scratch.
      await ChunkedDownloader.discardResumableState(target);
      expect(await ChunkedDownloader.hasResumableState(target), isFalse);

      final result = await ChunkedDownloader().download(
        server.uri,
        target,
        chunkSizeBytes: 8192,
        expectedSha256: _sha256Hex(payload),
      );
      expect(result.checksumVerified, isTrue);
      expect(result.resumed, isFalse);
      expect(await File(target).readAsBytes(), equals(payload));

      // Discarding again is a no-op, not an error.
      await ChunkedDownloader.discardResumableState(target);
    });

    test('verification can be skipped by the caller', () async {
      final payload = _payload(2 * 8192, 10);
      final server = _TestServer(payload: payload);
      await server.start();
      addTearDown(server.stop);

      final result = await ChunkedDownloader().download(
        server.uri,
        targetPath('skipped.dmg'),
        chunkSizeBytes: 8192,
        expectedSha256: _sha256Hex(_payload(64, 100)), // wrong on purpose
        verifyChecksum: false,
      );
      expect(result.checksumVerified, isFalse);
      expect(result.sha256Hex, _sha256Hex(payload)); // actual always reported
      expect(
        await File(targetPath('skipped.dmg')).readAsBytes(),
        equals(payload),
      );
    });
  });

  group('server without Range support', () {
    test('falls back to a single stream download', () async {
      final payload = _payload(3 * 8192 + 100, 11);
      final server = _TestServer(payload: payload, supportRanges: false);
      await server.start();
      addTearDown(server.stop);

      final target = targetPath('fallback.dmg');
      final events = <(int, int?)>[];
      final result = await ChunkedDownloader().download(
        server.uri,
        target,
        chunkSizeBytes: 8192,
        expectedSha256: _sha256Hex(payload),
        onProgress: (downloaded, total) => events.add((downloaded, total)),
      );

      expect(server.servedRanges, isEmpty);
      expect(await File(target).readAsBytes(), equals(payload));
      expect(result.checksumVerified, isTrue);
      expect(result.totalBytes, payload.length);
      expect(await Directory('$target.part').exists(), isFalse);
      expect(events, isNotEmpty);
      for (var i = 1; i < events.length; i++) {
        expect(events[i].$1, greaterThanOrEqualTo(events[i - 1].$1));
      }
      expect(events.last, (payload.length, payload.length));
    });

    test('staged fallback state does not pretend to resume', () async {
      final payload = _payload(2 * 8192, 12);
      final server = _TestServer(payload: payload, supportRanges: false);
      await server.start();
      addTearDown(server.stop);

      final target = targetPath('fallback-cancel.dmg');
      final token = DownloadCancellationToken();
      await expectLater(
        ChunkedDownloader().download(
          server.uri,
          target,
          cancellationToken: token,
          onProgress: (downloaded, total) {
            if (downloaded > 0) token.cancel();
          },
        ),
        throwsA(isA<DownloadCancelledException>()),
      );

      final result = await ChunkedDownloader().download(
        server.uri,
        target,
        expectedSha256: _sha256Hex(payload),
      );
      // The server cannot honor ranges, so this restarted from scratch.
      expect(result.resumed, isFalse);
      expect(await File(target).readAsBytes(), equals(payload));
    });
  });
}
