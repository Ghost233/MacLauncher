import 'dart:io';

/// Damage found while loading one of the launcher's local storage files
/// (project bindings, login-start preferences, configuration refresh
/// state).
///
/// A report exists only when something was wrong. Two shapes:
///
/// - Whole-file damage (unparseable JSON or an illegal top-level
///   structure): the original file was moved aside to [backupPath] and the
///   store started with an empty collection.
/// - Record-level damage (individual entries invalid inside an otherwise
///   readable file): the file stays in place, [backupPath] is null and
///   [skippedRecords] counts the dropped entries.
class StorageCorruptionReport {
  const StorageCorruptionReport({
    required this.filePath,
    required this.backupPath,
    required this.skippedRecords,
  });

  /// The store file that was damaged.
  final String filePath;

  /// Where the damaged original was moved, or null when the file itself
  /// was readable and only individual records were skipped.
  final String? backupPath;

  /// Records skipped inside a readable file (0 for whole-file damage).
  final int skippedRecords;
}

/// Moves [file] aside to `<path>.corrupt-<timestamp>` so the store can
/// start empty without tripping over the same damage on the next launch.
///
/// Shared by the three local stores; an implementation detail of their
/// load path, covered through their external behavior rather than tested
/// directly. Returns the backup path, or null when even the move failed —
/// the caller still starts empty in that case.
Future<String?> backupCorruptedFile(File file) async {
  final timestamp = DateTime.now()
      .toUtc()
      .toIso8601String()
      .replaceAll('-', '')
      .replaceAll(':', '')
      .replaceAll('.', '');
  final backupPath = '${file.path}.corrupt-$timestamp';
  try {
    await file.rename(backupPath);
    return backupPath;
  } catch (_) {
    return null;
  }
}
