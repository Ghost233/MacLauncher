import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';

/// Reports download progress.
///
/// [downloadedBytes] is monotonically non-decreasing within one
/// [ChunkedDownloader.download] call; [totalBytes] is null when the server
/// does not disclose the payload size.
typedef DownloadProgressCallback = void Function(
  int downloadedBytes,
  int? totalBytes,
);

/// Cooperative cancellation for [ChunkedDownloader.download].
///
/// Cancellation never deletes persisted chunks: the `.part` directory stays
/// on disk so a later download call resumes where this one stopped.
class DownloadCancellationToken {
  bool _cancelled = false;

  bool get isCancelled => _cancelled;

  void cancel() => _cancelled = true;

  void throwIfCancelled() {
    if (_cancelled) throw const DownloadCancelledException();
  }
}

/// Base type for every failure reported by [ChunkedDownloader].
sealed class DownloadException implements Exception {
  const DownloadException(this.message);

  final String message;

  @override
  String toString() => '$runtimeType: $message';
}

/// The caller cancelled the download. Persisted chunks are kept for resume.
class DownloadCancelledException extends DownloadException {
  const DownloadCancelledException() : super('download cancelled');
}

/// The server answered with an unexpected status code.
class DownloadHttpException extends DownloadException {
  const DownloadHttpException(this.uri, this.statusCode)
    : super('unexpected HTTP $statusCode for $uri');

  final Uri uri;
  final int statusCode;
}

/// The assembled payload does not match the expected sha256. The assembled
/// file is deleted; the `.part` directory is kept so the caller decides
/// whether to retry, wipe or investigate.
///
/// A plain retry reuses the persisted chunks and therefore fails the same
/// way. Before retrying, either call
/// [ChunkedDownloader.discardResumableState] to wipe the corrupt chunks or
/// download to a different target path.
class DownloadChecksumMismatchException extends DownloadException {
  const DownloadChecksumMismatchException(this.expected, this.actual)
    : super('sha256 mismatch: expected $expected, got $actual');

  final String expected;
  final String actual;
}

/// A chunk or stream transfer failed underneath (connection reset, I/O
/// error, short read). Persisted chunks are kept for resume; the original
/// error is available as [cause].
class DownloadTransferException extends DownloadException {
  const DownloadTransferException(this.cause)
    : super('transfer failed: $cause');

  final Object cause;
}

/// Outcome of a successful [ChunkedDownloader.download].
class DownloadResult {
  const DownloadResult({
    required this.path,
    required this.totalBytes,
    required this.sha256Hex,
    required this.checksumVerified,
    required this.resumed,
  });

  /// Final location of the downloaded payload.
  final String path;

  final int totalBytes;

  /// Actual sha256 of the payload, always computed while assembling.
  final String sha256Hex;

  /// True only when an expected sha256 was provided, verification was not
  /// skipped and the payload matched.
  final bool checksumVerified;

  /// True when a previously persisted `.part` state was reused.
  final bool resumed;
}

/// One chunk of a chunked download plan.
class _ChunkPlan {
  _ChunkPlan({required this.offset, required this.length});

  final int offset;
  final int length;
  bool complete = false;
}

/// Monotonic progress accounting for one download call.
class _Progress {
  _Progress(this.totalBytes, this.onProgress);

  final int? totalBytes;
  final DownloadProgressCallback? onProgress;

  int _completedBytes = 0;
  final Map<int, int> _inFlightBytes = {};
  int _highWater = 0;

  /// Seeds bytes carried over from a previously persisted state.
  void seedCompleted(int bytes) {
    _completedBytes += bytes;
    _report();
  }

  void chunkProgress(int index, int bytes) {
    _inFlightBytes[index] = (_inFlightBytes[index] ?? 0) + bytes;
    _report();
  }

  void chunkComplete(int index, int length) {
    _inFlightBytes.remove(index);
    _completedBytes += length;
    _report();
  }

  void finish() => _report();

  void _report() {
    var current = _completedBytes;
    for (final bytes in _inFlightBytes.values) {
      current += bytes;
    }
    // Retried chunks reset their in-flight counter; the high-water mark
    // keeps the reported sequence monotonic.
    if (current > _highWater) _highWater = current;
    onProgress?.call(_highWater, totalBytes);
  }
}

/// Collects the single [Digest] produced by a chunked hash conversion.
class _DigestCollector implements Sink<Digest> {
  Digest? value;

  @override
  void add(Digest digest) => value = digest;

  @override
  void close() {}
}

/// Concurrent HTTP Range downloader with on-disk resume state.
///
/// Layout while a download is in flight (`<target>` is the target path):
///
/// ```
/// <target>.part/
///   manifest.json      progress manifest (url, size, chunk plan, done flags)
///   chunk-000000 ...   one file per chunk
///   assembled          temporary assembly output, renamed to <target>
/// ```
///
/// Resume rules:
/// - A `.part` manifest matches only the same URL, total size and chunk size;
///   anything else is wiped and downloaded from scratch.
/// - A chunk file counts as done only with exactly the planned length;
///   partial chunks (interrupt mid-write) are re-downloaded whole.
/// - Servers without Range support fall back to a single-stream GET staged
///   in the `.part` directory; that state cannot resume (the server cannot
///   honor ranges) and is wiped on the next attempt.
///
/// Resource ownership: every [download] call creates its own [HttpClient]
/// (via the injected factory) and force-closes it in a `finally`; every file
/// sink is closed in a `finally`. Nothing outlives the call.
class ChunkedDownloader {
  ChunkedDownloader({HttpClient Function()? clientFactory})
    : _clientFactory = clientFactory ?? HttpClient.new;

  final HttpClient Function() _clientFactory;

  /// Default number of concurrent chunk fetches.
  static const int defaultConcurrency = 4;

  /// Default chunk size: 4 MiB. Update packages are DMGs in the tens to
  /// hundreds of MiB, so this yields tens of chunks — enough parallelism
  /// granularity without excessive per-request overhead or manifest churn.
  static const int defaultChunkSizeBytes = 4 * 1024 * 1024;

  /// Whether resumable state exists for [targetPath].
  ///
  /// This only checks that a `.part` progress manifest is present; the
  /// download call itself decides whether the state matches (same URL, size
  /// and chunk size) and wipes it when it does not.
  static Future<bool> hasResumableState(String targetPath) =>
      File('$targetPath.part/manifest.json').exists();

  /// Deletes the `.part` directory for [targetPath], if any.
  ///
  /// The caller-owned escape hatch for state that must not be resumed —
  /// e.g. after a [DownloadChecksumMismatchException], whose persisted
  /// chunks would otherwise fail every retry identically.
  static Future<void> discardResumableState(String targetPath) async {
    final partDir = Directory('$targetPath.part');
    if (await partDir.exists()) await partDir.delete(recursive: true);
  }

  /// Downloads [source] to [targetPath].
  ///
  /// [expectedSha256] enables whole-payload integrity verification; pass
  /// [verifyChecksum] false to skip the comparison (the caller's decision,
  /// e.g. a user preference). The actual digest is always reported through
  /// [DownloadResult.sha256Hex].
  ///
  /// Completes with [DownloadResult] on success; throws a [DownloadException]
  /// subclass on cancellation, HTTP errors or checksum mismatch. Whatever the
  /// outcome, already persisted chunks stay in `<target>.part/` for resume.
  Future<DownloadResult> download(
    Uri source,
    String targetPath, {
    int concurrency = defaultConcurrency,
    int chunkSizeBytes = defaultChunkSizeBytes,
    String? expectedSha256,
    bool verifyChecksum = true,
    DownloadProgressCallback? onProgress,
    DownloadCancellationToken? cancellationToken,
  }) async {
    if (concurrency < 1) {
      throw ArgumentError.value(concurrency, 'concurrency', 'must be >= 1');
    }
    if (chunkSizeBytes < 1) {
      throw ArgumentError.value(
        chunkSizeBytes,
        'chunkSizeBytes',
        'must be >= 1',
      );
    }
    final token = cancellationToken ?? DownloadCancellationToken();
    final client = _clientFactory();
    try {
      token.throwIfCancelled();
      final probe = await _probe(client, source);
      token.throwIfCancelled();
      if (probe.rangeSupported) {
        return await _downloadChunked(
          client,
          source,
          targetPath,
          probe.totalBytes!,
          concurrency,
          chunkSizeBytes,
          expectedSha256,
          verifyChecksum,
          onProgress,
          token,
        );
      }
      return await _downloadSingleStream(
        client,
        source,
        targetPath,
        probe.totalBytes,
        expectedSha256,
        verifyChecksum,
        onProgress,
        token,
      );
    } finally {
      client.close(force: true);
    }
  }

  // ---------------------------------------------------------------- probe

  Future<({int? totalBytes, bool rangeSupported})> _probe(
    HttpClient client,
    Uri source,
  ) async {
    final request = await client.headUrl(source);
    final response = await request.close();
    await response.drain<void>();
    if (response.statusCode != HttpStatus.ok) {
      throw DownloadHttpException(source, response.statusCode);
    }
    final acceptsRanges =
        response.headers.value(HttpHeaders.acceptRangesHeader)?.toLowerCase() ==
        'bytes';
    final total = response.contentLength >= 0 ? response.contentLength : null;
    return (totalBytes: total, rangeSupported: acceptsRanges && total != null);
  }

  // -------------------------------------------------------------- chunked

  Future<DownloadResult> _downloadChunked(
    HttpClient client,
    Uri source,
    String targetPath,
    int totalBytes,
    int concurrency,
    int chunkSizeBytes,
    String? expectedSha256,
    bool verifyChecksum,
    DownloadProgressCallback? onProgress,
    DownloadCancellationToken token,
  ) async {
    final partDir = Directory('$targetPath.part');
    final manifestFile = File('${partDir.path}/manifest.json');
    final plans = <_ChunkPlan>[
      for (var offset = 0; offset < totalBytes; offset += chunkSizeBytes)
        _ChunkPlan(
          offset: offset,
          length: (offset + chunkSizeBytes <= totalBytes)
              ? chunkSizeBytes
              : totalBytes - offset,
        ),
    ];
    final progress = _Progress(totalBytes, onProgress);

    var resumed = false;
    if (await manifestFile.exists()) {
      final reuse = await _tryReuseManifest(
        partDir,
        manifestFile,
        source,
        totalBytes,
        chunkSizeBytes,
        plans,
      );
      if (reuse) {
        resumed = true;
        for (var i = 0; i < plans.length; i++) {
          if (plans[i].complete) progress.seedCompleted(plans[i].length);
        }
      } else {
        // Stale or foreign state: this target now downloads different bytes.
        await partDir.delete(recursive: true);
      }
    }
    await partDir.create(recursive: true);
    await _saveManifest(
      manifestFile,
      source,
      totalBytes,
      chunkSizeBytes,
      plans,
    );

    final pending = <int>[
      for (var i = 0; i < plans.length; i++)
        if (!plans[i].complete) i,
    ];
    Object? failure;
    var next = 0;

    Future<void> worker() async {
      while (failure == null && !token.isCancelled) {
        if (next >= pending.length) return;
        final index = pending[next++];
        final plan = plans[index];
        final file = File(_chunkPath(partDir, index));
        try {
          await _downloadChunk(
            client,
            source,
            plan,
            file,
            progress,
            index,
            token,
          );
          token.throwIfCancelled();
          final actualLength = await file.length();
          if (actualLength != plan.length) {
            throw StateError(
              'chunk $index length $actualLength != ${plan.length}',
            );
          }
          plan.complete = true;
          progress.chunkComplete(index, plan.length);
          await _saveManifest(
            manifestFile,
            source,
            totalBytes,
            chunkSizeBytes,
            plans,
          );
        } catch (e) {
          // A partial chunk file is not resumable; the whole chunk retries.
          if (await file.exists()) await file.delete();
          failure ??= e is DownloadException ? e : DownloadTransferException(e);
          return;
        }
      }
    }

    final workerCount = pending.length < concurrency
        ? pending.length
        : concurrency;
    await Future.wait([for (var i = 0; i < workerCount; i++) worker()]);
    token.throwIfCancelled();
    final failure0 = failure;
    if (failure0 != null) throw failure0;

    return _assemble(
      partDir,
      plans,
      targetPath,
      totalBytes,
      expectedSha256,
      verifyChecksum,
      progress,
      resumed,
    );
  }

  Future<void> _downloadChunk(
    HttpClient client,
    Uri source,
    _ChunkPlan plan,
    File file,
    _Progress progress,
    int index,
    DownloadCancellationToken token,
  ) async {
    final request = await client.getUrl(source);
    request.headers.set(
      HttpHeaders.rangeHeader,
      'bytes=${plan.offset}-${plan.offset + plan.length - 1}',
    );
    final response = await request.close();
    if (response.statusCode != HttpStatus.partialContent) {
      await response.drain<void>();
      throw DownloadHttpException(source, response.statusCode);
    }
    final sink = file.openWrite();
    try {
      await for (final data in response) {
        token.throwIfCancelled();
        sink.add(data);
        progress.chunkProgress(index, data.length);
      }
      await sink.flush();
    } finally {
      await sink.close();
    }
  }

  // --------------------------------------------------------- single stream

  Future<DownloadResult> _downloadSingleStream(
    HttpClient client,
    Uri source,
    String targetPath,
    int? probedTotalBytes,
    String? expectedSha256,
    bool verifyChecksum,
    DownloadProgressCallback? onProgress,
    DownloadCancellationToken token,
  ) async {
    final partDir = Directory('$targetPath.part');
    // The server cannot honor ranges, so a previous staged stream has no
    // resume value; restart cleanly.
    if (await partDir.exists()) await partDir.delete(recursive: true);
    await partDir.create(recursive: true);
    final staging = File('${partDir.path}/single');

    final request = await client.getUrl(source);
    final response = await request.close();
    if (response.statusCode != HttpStatus.ok) {
      await response.drain<void>();
      throw DownloadHttpException(source, response.statusCode);
    }
    final total = response.contentLength >= 0
        ? response.contentLength
        : probedTotalBytes;
    final progress = _Progress(total, onProgress);

    final collector = _DigestCollector();
    final hashSink = sha256.startChunkedConversion(collector);
    final sink = staging.openWrite();
    var received = 0;
    try {
      await for (final data in response) {
        token.throwIfCancelled();
        sink.add(data);
        hashSink.add(data);
        received += data.length;
        progress.chunkProgress(0, data.length);
      }
      hashSink.close();
      await sink.flush();
    } finally {
      await sink.close();
    }
    if (total != null && received != total) {
      await staging.delete();
      throw StateError('received $received of $total bytes for $source');
    }
    progress.chunkComplete(0, received);
    token.throwIfCancelled();

    final sha256Hex = collector.value.toString();
    final verified = await _verifyChecksum(
      staging,
      sha256Hex,
      expectedSha256,
      verifyChecksum,
    );
    await File(targetPath).parent.create(recursive: true);
    await _replaceTarget(staging, targetPath);
    await partDir.delete(recursive: true);
    progress.finish();
    return DownloadResult(
      path: targetPath,
      totalBytes: received,
      sha256Hex: sha256Hex,
      checksumVerified: verified,
      resumed: false,
    );
  }

  // ------------------------------------------------------------ assembly

  Future<DownloadResult> _assemble(
    Directory partDir,
    List<_ChunkPlan> plans,
    String targetPath,
    int totalBytes,
    String? expectedSha256,
    bool verifyChecksum,
    _Progress progress,
    bool resumed,
  ) async {
    final assembled = File('${partDir.path}/assembled');
    final collector = _DigestCollector();
    final hashSink = sha256.startChunkedConversion(collector);
    final sink = assembled.openWrite();
    try {
      for (var i = 0; i < plans.length; i++) {
        final chunkFile = File(_chunkPath(partDir, i));
        await for (final data in chunkFile.openRead()) {
          sink.add(data);
          hashSink.add(data);
        }
      }
      hashSink.close();
      await sink.flush();
    } finally {
      await sink.close();
    }

    final sha256Hex = collector.value.toString();
    final verified = await _verifyChecksum(
      assembled,
      sha256Hex,
      expectedSha256,
      verifyChecksum,
    );
    await File(targetPath).parent.create(recursive: true);
    await _replaceTarget(assembled, targetPath);
    await partDir.delete(recursive: true);
    progress.finish();
    return DownloadResult(
      path: targetPath,
      totalBytes: totalBytes,
      sha256Hex: sha256Hex,
      checksumVerified: verified,
      resumed: resumed,
    );
  }

  /// Returns true when the checksum was actually verified. On mismatch,
  /// deletes [assembledFile] and throws; chunk state is kept for the caller.
  Future<bool> _verifyChecksum(
    File assembledFile,
    String actualHex,
    String? expectedSha256,
    bool verifyChecksum,
  ) async {
    final expected = expectedSha256?.toLowerCase();
    if (expected == null || !verifyChecksum) return false;
    if (actualHex != expected) {
      await assembledFile.delete();
      throw DownloadChecksumMismatchException(expected, actualHex);
    }
    return true;
  }

  Future<void> _replaceTarget(File staged, String targetPath) async {
    final target = File(targetPath);
    if (await target.exists()) await target.delete();
    await staged.rename(targetPath);
  }

  // -------------------------------------------------------------- manifest

  String _chunkPath(Directory partDir, int index) =>
      '${partDir.path}/chunk-${index.toString().padLeft(6, '0')}';

  /// Monotonic suffix so concurrent workers never share a tmp file.
  static int _manifestTmpCounter = 0;

  Future<void> _saveManifest(
    File manifestFile,
    Uri source,
    int totalBytes,
    int chunkSizeBytes,
    List<_ChunkPlan> plans,
  ) async {
    // Concurrent workers save snapshots independently; a unique tmp path per
    // call plus an atomic rename keeps every on-disk manifest a complete
    // document (a stale snapshot may briefly win the rename race, which only
    // re-downloads an already complete chunk — resume validates by length).
    final tmp = File('${manifestFile.path}.tmp-${_manifestTmpCounter++}');
    await tmp.writeAsString(
      jsonEncode({
        'version': 1,
        'url': source.toString(),
        'totalBytes': totalBytes,
        'chunkSizeBytes': chunkSizeBytes,
        'chunks': [
          for (final plan in plans)
            {
              'offset': plan.offset,
              'length': plan.length,
              'complete': plan.complete,
            },
        ],
      }),
      flush: true,
    );
    await tmp.rename(manifestFile.path);
  }

  /// Validates a persisted manifest against the current plan and marks
  /// reusable chunks complete. Returns false when the state is stale or
  /// corrupt; the caller then wipes the `.part` directory.
  Future<bool> _tryReuseManifest(
    Directory partDir,
    File manifestFile,
    Uri source,
    int totalBytes,
    int chunkSizeBytes,
    List<_ChunkPlan> plans,
  ) async {
    final Object? decoded;
    try {
      decoded = jsonDecode(await manifestFile.readAsString());
    } on Exception {
      return false;
    }
    if (decoded is! Map) return false;
    final manifest = decoded.cast<String, Object?>();
    if (manifest['version'] != 1 ||
        manifest['url'] != source.toString() ||
        manifest['totalBytes'] != totalBytes ||
        manifest['chunkSizeBytes'] != chunkSizeBytes) {
      return false;
    }
    final chunks = manifest['chunks'];
    if (chunks is! List || chunks.length != plans.length) return false;
    for (var i = 0; i < plans.length; i++) {
      final entry = chunks[i];
      if (entry is! Map) return false;
      final record = entry.cast<String, Object?>();
      if (record['offset'] != plans[i].offset ||
          record['length'] != plans[i].length) {
        return false;
      }
      if (record['complete'] == true) {
        final chunkFile = File(_chunkPath(partDir, i));
        // Done means done: only an exact-length chunk file survives resume.
        plans[i].complete =
            await chunkFile.exists() &&
            await chunkFile.length() == plans[i].length;
      } else if (await File(_chunkPath(partDir, i)).exists()) {
        // Partial chunk from an interrupted write; re-downloaded whole.
        await File(_chunkPath(partDir, i)).delete();
      }
    }
    return true;
  }
}
