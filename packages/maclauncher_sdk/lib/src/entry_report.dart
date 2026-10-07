import 'dart:io';

/// How the launcher may start the application, as self-reported by the
/// application itself in the hello handshake.
enum SdkEntryKind {
  /// An `.app` bundle opened via the system `open`.
  app,

  /// An executable started detached (no shell, no output capture).
  executable;

  static SdkEntryKind fromJson(String value) =>
      SdkEntryKind.values.asNameMap()[value] ?? SdkEntryKind.executable;

  String toJson() => name;
}

/// A launch recipe the application reports about itself at runtime, so the
/// launcher can learn how to start it without a manifest file.
///
/// The application always knows its own runtime location best: a packaged
/// app can report its own bundle, a script-started tool can report the
/// exact command (including args and working directory) it wants the
/// launcher to use. All paths must be absolute; the launcher validates
/// existence at approval time and treats a vanished path as a recoverable
/// 「入口失效」 state, never as a reason to recycle anything.
class SdkEntry {
  const SdkEntry._({
    required this.kind,
    required this.path,
    this.args = const [],
    this.workingDirectory,
  });

  /// An `.app` bundle entry; opened via the system `open`.
  factory SdkEntry.appBundle(String bundlePath) =>
      SdkEntry._(kind: SdkEntryKind.app, path: bundlePath);

  /// An executable entry, started detached with optional [args] and
  /// [workingDirectory] (absolute; defaults to the executable's directory
  /// on the launcher side when omitted).
  factory SdkEntry.executable(
    String path, {
    List<String> args = const [],
    String? workingDirectory,
  }) => SdkEntry._(
    kind: SdkEntryKind.executable,
    path: path,
    args: args,
    workingDirectory: workingDirectory,
  );

  /// Derives an app-bundle entry from the running executable's own path
  /// (`/…/Foo.app/Contents/MacOS/Foo` → `/…/Foo.app`). Returns null when
  /// the executable is not inside an `.app` bundle — e.g. a plain CLI or a
  /// development run — in which case use [currentExecutable] instead.
  static SdkEntry? currentAppBundle({String? resolvedExecutable}) {
    final executable = resolvedExecutable ?? Platform.resolvedExecutable;
    const marker = '.app/Contents/MacOS/';
    final index = executable.indexOf(marker);
    if (index <= 0) return null;
    return SdkEntry.appBundle(executable.substring(0, index + '.app'.length));
  }

  /// Reports the running executable itself, for script-started or CLI
  /// projects. [args] and [workingDirectory] describe how the launcher
  /// should re-run it; the application decides what to declare.
  static SdkEntry currentExecutable({
    String? resolvedExecutable,
    List<String> args = const [],
    String? workingDirectory,
  }) => SdkEntry.executable(
    resolvedExecutable ?? Platform.resolvedExecutable,
    args: args,
    workingDirectory: workingDirectory,
  );

  /// `app` or `executable`.
  final SdkEntryKind kind;

  /// Absolute path of the bundle or executable.
  final String path;

  /// Launch arguments; only meaningful for [SdkEntryKind.executable].
  final List<String> args;

  /// Absolute working directory; only meaningful for
  /// [SdkEntryKind.executable].
  final String? workingDirectory;

  Map<String, Object?> toJson() => {
    'kind': kind.toJson(),
    'path': path,
    if (args.isNotEmpty) 'args': args,
    if (workingDirectory != null) 'workingDirectory': workingDirectory,
  };

  static SdkEntry? fromJson(Map<String, Object?> json) {
    final path = json['path'];
    if (path is! String || path.isEmpty) return null;
    return SdkEntry._(
      kind: SdkEntryKind.fromJson(json['kind'] as String? ?? ''),
      path: path,
      args: [
        for (final a in (json['args'] as List? ?? const []))
          if (a is String) a,
      ],
      workingDirectory: json['workingDirectory'] as String?,
    );
  }
}
