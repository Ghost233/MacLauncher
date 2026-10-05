import 'dart:io';

/// Exclusive, per-user ownership of the listening endpoint.
///
/// Only the process holding the lock may bind the socket and clean up a
/// stale endpoint. A second launcher instance can never override an active
/// endpoint.
class EndpointLock {
  EndpointLock._(this._file, this._handle);

  final File _file;
  final RandomAccessFile _handle;

  /// Paths held inside this process. POSIX file locks are per-process, so a
  /// second in-process acquisition would silently succeed; this guard keeps
  /// the single-instance rule intact (and testable) within one process too.
  static final Set<String> _heldInProcess = {};

  /// Acquires the lock at [lockPath]. Throws [StateError] when another
  /// process holds it.
  static Future<EndpointLock> acquire(String lockPath) async {
    final requested = File(lockPath);
    await requested.create(recursive: true);
    // POSIX locks are per-process, so aliases must share the same in-process
    // reservation as well as the same operating-system lock.
    lockPath = requested.resolveSymbolicLinksSync();
    if (!_heldInProcess.add(lockPath)) {
      throw StateError(
        'another launcher instance holds the endpoint lock: $lockPath',
      );
    }
    final file = File(lockPath);
    RandomAccessFile? handle;
    try {
      // Do not truncate the incumbent owner's metadata before locking.
      handle = await file.open(mode: FileMode.append);
      try {
        await handle.lock(FileLock.exclusive);
      } catch (_) {
        throw StateError(
          'another launcher instance holds the endpoint lock: $lockPath',
        );
      }
      await handle.truncate(0);
      await handle.writeString('$pid\n');
      await handle.flush();
      return EndpointLock._(file, handle);
    } catch (_) {
      try {
        await handle?.close();
      } finally {
        _heldInProcess.remove(lockPath);
      }
      rethrow;
    }
  }

  Future<void> release() async {
    try {
      await _handle.unlock();
    } finally {
      await _handle.close();
      _heldInProcess.remove(_file.path);
    }
  }
}
