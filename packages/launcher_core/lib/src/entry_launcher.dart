import 'dart:io';

import 'manifest.dart';

/// Why an entry could not be opened. Surfaced to the user as the concrete
/// reason; a failed open never claims the business has started.
enum EntryOpenFailure { missingProgram, spawnFailed, openFailed }

class EntryOpenException implements Exception {
  EntryOpenException(this.reason, this.detail);

  final EntryOpenFailure reason;
  final String detail;

  @override
  String toString() => '$reason: $detail';
}

/// Opens a configured application entry.
///
/// Entries are opened detached and never via a shell; business output is
/// never captured, and the launcher never becomes the business's supervisor.
/// Opening an entry only gives the application a chance to connect — it
/// never means a service has started.
class EntryLauncher {
  const EntryLauncher();

  /// Opens [entry]. Relative paths (and a relative working directory)
  /// resolve against [manifestDir]. Throws [EntryOpenException] with the
  /// concrete reason on failure.
  Future<void> open(ManifestEntry entry, {required String manifestDir}) async {
    switch (entry.kind) {
      case EntryKind.executable:
        final program = resolve(entry.path, manifestDir);
        if (!File(program).existsSync()) {
          throw EntryOpenException(EntryOpenFailure.missingProgram, program);
        }
        final workingDirectory = entry.workingDirectory == null
            ? manifestDir
            : resolve(entry.workingDirectory!, manifestDir);
        try {
          await Process.start(
            program,
            entry.args,
            workingDirectory: workingDirectory,
            mode: ProcessStartMode.detached,
            runInShell: false,
          );
        } catch (e) {
          throw EntryOpenException(EntryOpenFailure.spawnFailed, '$e');
        }
      case EntryKind.app:
        final bundle = resolve(entry.path, manifestDir);
        if (FileSystemEntity.typeSync(bundle) ==
            FileSystemEntityType.notFound) {
          throw EntryOpenException(EntryOpenFailure.missingProgram, bundle);
        }
        // System-standard way to open an application bundle.
        final result = await Process.run('open', [bundle]);
        if (result.exitCode != 0) {
          throw EntryOpenException(
            EntryOpenFailure.openFailed,
            '${result.stderr}'.trim(),
          );
        }
    }
  }

  static String resolve(String path, String base) =>
      path.startsWith('/') ? path : '$base/$path';
}
