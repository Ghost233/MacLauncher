import 'dart:convert';
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

/// Outcome of decoding one store file: either the decoded JSON value, or a
/// whole-file damage report when the file could not be decoded or its
/// top-level structure was not what the store keeps.
class StoreFileDecode {
  const StoreFileDecode({this.decoded, this.wholeFileDamage});

  /// The decoded JSON value; null exactly when [wholeFileDamage] is set.
  final Object? decoded;

  /// Whole-file damage report (original moved aside), or null when the
  /// file decoded into a structurally valid document.
  final StorageCorruptionReport? wholeFileDamage;
}

/// Decodes the JSON document in [file], tolerating damage: unparseable
/// JSON or a top level rejected by [isValidTopLevel] moves the original
/// aside to `.corrupt-<timestamp>` and reports whole-file damage so the
/// caller starts with an empty collection. Never throws for damaged
/// content. Callers check file existence themselves (a missing file is
/// simply an empty store, not damage).
Future<StoreFileDecode> decodeStoreFile(
  File file, {
  required bool Function(Object? decoded) isValidTopLevel,
}) async {
  final Object? decoded;
  try {
    decoded = jsonDecode(await file.readAsString());
  } on FormatException {
    return StoreFileDecode(wholeFileDamage: await _wholeFileDamage(file));
  }
  if (!isValidTopLevel(decoded)) {
    return StoreFileDecode(wholeFileDamage: await _wholeFileDamage(file));
  }
  return StoreFileDecode(decoded: decoded);
}

/// The record-level damage report for a load that skipped [skipped]
/// entries, or null when nothing was skipped.
StorageCorruptionReport? skippedRecordsReport(File file, int skipped) =>
    skipped > 0
    ? StorageCorruptionReport(
        filePath: file.path,
        backupPath: null,
        skippedRecords: skipped,
      )
    : null;

Future<StorageCorruptionReport> _wholeFileDamage(File file) async =>
    StorageCorruptionReport(
      filePath: file.path,
      backupPath: await backupCorruptedFile(file),
      skippedRecords: 0,
    );
