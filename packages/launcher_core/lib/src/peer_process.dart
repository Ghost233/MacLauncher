import 'dart:io';

/// Best-effort source-process discovery for unix-socket peers.
///
/// dart:io exposes no peer credentials for unix domain sockets, so this
/// shells out to lsof/ps. It is display-only information: the trust model
/// never depends on it, and any failure simply yields null.
///
/// Attribution is inherently approximate — lsof lists every process
/// holding the endpoint, so the peer is only reported when exactly one
/// candidate (besides this process) remains.
Future<String?> probePeerProcessPath(String socketPath) async {
  try {
    final lsof = await Process.run('lsof', [
      '-n',
      '+E',
      '--',
      socketPath,
    ]).timeout(const Duration(seconds: 2));
    if (lsof.exitCode != 0) return null;
    final peers = parsePeerPids(lsof.stdout as String, pid);
    if (peers.length != 1) return null;
    final ps = await Process.run('ps', [
      '-p',
      '${peers.single}',
      '-o',
      'comm=',
    ]).timeout(const Duration(seconds: 2));
    if (ps.exitCode != 0) return null;
    final path = (ps.stdout as String).trim();
    return path.isEmpty ? null : path;
  } catch (_) {
    return null;
  }
}

/// Extracts peer pids from `lsof +E` output, excluding [selfPid].
///
/// With endpoint info enabled, connected unix sockets carry a trailing
/// `->INO=0x… pid,command,fd` group naming the peer process.
List<int> parsePeerPids(String lsofOutput, int selfPid) {
  final pids = <int>{};
  final endpoint = RegExp(r'->INO=\S+\s+(\d+),');
  for (final match in endpoint.allMatches(lsofOutput)) {
    final peer = int.tryParse(match.group(1)!);
    if (peer != null && peer != selfPid) pids.add(peer);
  }
  return pids.toList(growable: false);
}
