import 'dart:io';

/// Fixed SDK discovery convention shared with the SDK: a user-private
/// directory holding the listening socket and the single-instance lock.
class EndpointLayout {
  EndpointLayout({required this.directory});

  /// Default for the current user: `~/Library/Application Support/MacLauncher`.
  factory EndpointLayout.forUser({String? home}) => EndpointLayout(
    directory:
        '${home ?? Platform.environment['HOME'] ?? '.'}/Library/Application Support/MacLauncher',
  );

  final String directory;

  String get socketPath => '$directory/sdk-v1.sock';
  String get lockPath => '$directory/sdk-v1.lock';

  /// Creates the directory with 0700 permissions. Existing directories are
  /// tightened to 0700 as well.
  void ensureDirectory() {
    Directory(directory).createSync(recursive: true);
    _chmod(directory, '700');
  }

  /// Restricts the socket to the owner (0600).
  void secureSocket() => _chmod(socketPath, '600');

  static void _chmod(String path, String mode) {
    final result = Process.runSync('chmod', [mode, path]);
    if (result.exitCode != 0) {
      throw StateError('chmod $mode $path failed: ${result.stderr}');
    }
  }
}
