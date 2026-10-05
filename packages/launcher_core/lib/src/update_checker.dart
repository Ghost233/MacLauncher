import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// A semantic version (SemVer 2.0.0) with precedence comparison.
///
/// Parsing is lenient about one leading `v` (`v1.2.3` == `1.2.3`, the common
/// git tag convention) and requires exactly `major.minor.patch`. Build
/// metadata (`+build`) is retained for display but ignored in precedence, as
/// SemVer §10 mandates: `1.2.0+4` and `1.2.0+5` compare equal, so a rebuilt
/// package of the same release is never reported as an update.
class SemVer implements Comparable<SemVer> {
  const SemVer._(
    this.major,
    this.minor,
    this.patch,
    this.prerelease,
    this.build,
  );

  final int major;
  final int minor;
  final int patch;

  /// Dot-separated prerelease identifiers; null for a normal release. A
  /// release sorts after every one of its prereleases (`1.3.0-rc.1 < 1.3.0`).
  final List<String>? prerelease;

  /// Build metadata without the `+`; never participates in comparison.
  final String? build;

  static final RegExp _numericIdentifier = RegExp(r'^\d+$');
  static final RegExp _identifier = RegExp(r'^[0-9A-Za-z-]+$');

  /// Parses [raw] (optionally `v`-prefixed); returns null when [raw] is not a
  /// semantic version.
  static SemVer? tryParse(String raw) {
    var text = raw.trim();
    if (text.startsWith('v') || text.startsWith('V')) {
      text = text.substring(1);
    }
    String? build;
    final plus = text.indexOf('+');
    if (plus >= 0) {
      build = text.substring(plus + 1);
      text = text.substring(0, plus);
      if (build.isEmpty || !_identifier.hasMatch(build)) return null;
    }
    List<String>? prerelease;
    final dash = text.indexOf('-');
    if (dash >= 0) {
      final pre = text.substring(dash + 1);
      text = text.substring(0, dash);
      prerelease = pre.split('.');
      if (prerelease.any((id) => id.isEmpty || !_identifier.hasMatch(id))) {
        return null;
      }
    }
    final core = text.split('.');
    if (core.length != 3) return null;
    final numbers = <int>[];
    for (final part in core) {
      if (!_numericIdentifier.hasMatch(part)) return null;
      final value = int.tryParse(part);
      if (value == null) return null;
      numbers.add(value);
    }
    return SemVer._(numbers[0], numbers[1], numbers[2], prerelease, build);
  }

  /// Precedence per SemVer §11; [build] metadata is ignored.
  @override
  int compareTo(SemVer other) {
    if (major != other.major) return major.compareTo(other.major);
    if (minor != other.minor) return minor.compareTo(other.minor);
    if (patch != other.patch) return patch.compareTo(other.patch);
    final mine = prerelease;
    final theirs = other.prerelease;
    if (mine == null && theirs == null) return 0;
    if (mine == null) return 1; // a release outranks its prereleases
    if (theirs == null) return -1;
    for (var i = 0; i < mine.length && i < theirs.length; i++) {
      final a = mine[i];
      final b = theirs[i];
      if (a == b) continue;
      final aNumeric = _numericIdentifier.hasMatch(a);
      final bNumeric = _numericIdentifier.hasMatch(b);
      if (aNumeric && bNumeric) {
        final result = int.parse(a).compareTo(int.parse(b));
        if (result != 0) return result;
      } else if (aNumeric) {
        return -1; // numeric identifiers sort below alphanumeric ones
      } else if (bNumeric) {
        return 1;
      } else {
        final result = a.compareTo(b);
        if (result != 0) return result;
      }
    }
    // A larger set of prerelease identifiers outranks a smaller prefix.
    return mine.length.compareTo(theirs.length);
  }

  /// `major.minor.patch[-prerelease][+build]`, without any `v` prefix.
  @override
  String toString() {
    final buffer = StringBuffer('$major.$minor.$patch');
    final pre = prerelease;
    if (pre != null) buffer.write('-${pre.join('.')}');
    final b = build;
    if (b != null) buffer.write('+$b');
    return buffer.toString();
  }
}

/// Outcome of one [UpdateChecker.checkForUpdate] call.
///
/// Checking for updates is a background convenience: failures are reported as
/// typed results for the caller (settings page, manual check button) to
/// present or ignore, never as thrown exceptions.
sealed class UpdateCheckResult {
  const UpdateCheckResult();
}

/// The query completed and the latest full release was evaluated.
final class UpdateCheckSuccess extends UpdateCheckResult {
  const UpdateCheckSuccess({
    required this.hasUpdate,
    required this.latestVersion,
    this.dmgDownloadUrl,
    this.sha256,
  });

  /// Whether [latestVersion] is strictly newer than the current version.
  final bool hasUpdate;

  /// Latest published version, normalized (no `v` prefix, build metadata
  /// preserved).
  final String latestVersion;

  /// Direct download URL of the release's `.dmg` asset; null when the
  /// release ships no DMG (a version-only release still counts as an update).
  final Uri? dmgDownloadUrl;

  /// Lowercase hex sha256 of [dmgDownloadUrl]'s payload, when determinable:
  /// taken from the asset's `digest` field, falling back to a sibling
  /// `<name>.sha256` checksum asset. Null means the download cannot be
  /// verified up front; the downloader still computes the actual digest.
  final String? sha256;
}

/// The query failed. [reason] is user-presentable; [cause] is the original
/// error for diagnostics.
final class UpdateCheckFailure extends UpdateCheckResult {
  const UpdateCheckFailure(this.reason, {this.cause});

  final String reason;
  final Object? cause;

  @override
  String toString() => 'UpdateCheckFailure($reason)';
}

/// One asset of a GitHub release, validated at the I/O boundary (E02).
class _AssetInfo {
  const _AssetInfo({
    required this.name,
    required this.downloadUrl,
    this.sha256,
  });

  final String name;
  final Uri downloadUrl;

  /// Lowercase hex digest from the asset's `digest` field, already stripped
  /// of its `sha256:` algorithm prefix; null when absent or not sha256.
  final String? sha256;
}

/// Checks GitHub Releases for a newer launcher version.
///
/// The checker queries `GET /repos/{owner}/{repo}/releases/latest`. GitHub
/// defines the latest release as the most recently created non-draft,
/// non-prerelease release, so the rolling-build prerelease named `latest`
/// (see 滚动构建 in CONTEXT.md) never matches this endpoint — that is exactly
/// the "latest full release" semantics issue #29 asks for. When the
/// repository has no full release yet the endpoint answers 404, reported as
/// an [UpdateCheckFailure] with an explicit reason. A defensive guard still
/// rejects a payload marked draft or prerelease, in case the endpoint
/// behavior ever changes.
///
/// The current version is build-time injected (pubspec version); this module
/// never reads package info itself. [owner]/[repo] default to the launcher
/// repository and are injectable for tests, as is the API [baseUri] and the
/// [HttpClient] factory (E08).
///
/// Resource ownership (E04): every [checkForUpdate] call creates its own
/// client through the factory and force-closes it in a `finally`; nothing
/// outlives the call.
class UpdateChecker {
  UpdateChecker({
    required this.currentVersion,
    this.owner = 'Ghost233',
    this.repo = 'MacLauncher',
    Uri? baseUri,
    HttpClient Function()? clientFactory,
    this.timeout = const Duration(seconds: 15),
  }) : _baseUri = baseUri ?? Uri.https('api.github.com', ''),
       _clientFactory = clientFactory ?? HttpClient.new;

  /// Build-time injected current version (pubspec `version`, e.g. `1.2.0+4`).
  final String currentVersion;

  final String owner;
  final String repo;

  /// Root of the GitHub API; defaults to `https://api.github.com`.
  final Uri _baseUri;

  final HttpClient Function() _clientFactory;

  /// Bound on the whole check; expiry is reported as an [UpdateCheckFailure].
  final Duration timeout;

  static final RegExp _sha256Hex = RegExp(r'^[0-9a-fA-F]{64}$');

  Uri get _latestReleaseUri => _baseUri.replace(
    path: '${_baseUri.path}/repos/$owner/$repo/releases/latest',
  );

  /// Queries the latest full release and compares it with [currentVersion].
  ///
  /// Always completes with an [UpdateCheckResult]; network errors, unexpected
  /// status codes, malformed JSON and timeouts all become
  /// [UpdateCheckFailure] — the caller decides whether to surface anything.
  Future<UpdateCheckResult> checkForUpdate() async {
    final current = SemVer.tryParse(currentVersion);
    if (current == null) {
      return UpdateCheckFailure(
        'current version "$currentVersion" is not a semantic version',
      );
    }
    final client = _clientFactory();
    try {
      return await _check(client, current).timeout(timeout);
    } on TimeoutException {
      return UpdateCheckFailure('request timed out after $timeout');
    } catch (error) {
      return UpdateCheckFailure(_describe(error), cause: error);
    } finally {
      client.close(force: true);
    }
  }

  static String _describe(Object error) {
    if (error is SocketException) return 'network error: ${error.message}';
    if (error is HttpException) return 'HTTP error: ${error.message}';
    if (error is FormatException) return 'malformed release payload: $error';
    return 'unexpected error: $error';
  }

  Future<UpdateCheckResult> _check(HttpClient client, SemVer current) async {
    final release = await _getJson(client, _latestReleaseUri);

    final tagName = release['tag_name'];
    if (tagName is! String || tagName.isEmpty) {
      throw const FormatException('missing string field "tag_name"');
    }
    // Defensive: /releases/latest must not return these (see class doc).
    if (release['draft'] == true || release['prerelease'] == true) {
      return const UpdateCheckFailure(
        'latest-release endpoint returned a draft or prerelease; '
        'treating it as "no published full release"',
      );
    }
    final latest = SemVer.tryParse(tagName);
    if (latest == null) {
      throw FormatException('unparseable release tag "$tagName"');
    }

    final assets = _parseAssets(release['assets']);
    _AssetInfo? dmg;
    for (final asset in assets) {
      if (asset.name.toLowerCase().endsWith('.dmg')) {
        dmg = asset;
        break;
      }
    }

    String? sha256 = dmg?.sha256;
    if (dmg != null && sha256 == null) {
      // Fallback when GitHub did not attach a digest: a sibling checksum
      // asset named `<dmg>.sha256` whose body starts with the hex digest.
      // Its failure degrades to "unverifiable", never to a check failure.
      sha256 = await _fetchCompanionChecksum(client, assets, dmg.name);
    }

    return UpdateCheckSuccess(
      hasUpdate: latest.compareTo(current) > 0,
      latestVersion: latest.toString(),
      dmgDownloadUrl: dmg?.downloadUrl,
      sha256: sha256,
    );
  }

  /// Validates the `assets` array into typed data; entries with a missing or
  /// malformed name/URL are dropped, a non-list value is an error.
  List<_AssetInfo> _parseAssets(Object? raw) {
    if (raw == null) return const [];
    if (raw is! List) {
      throw const FormatException('field "assets" is not a list');
    }
    final assets = <_AssetInfo>[];
    for (final entry in raw) {
      if (entry is! Map) continue;
      final map = entry.cast<String, Object?>();
      final name = map['name'];
      final url = map['browser_download_url'];
      if (name is! String || url is! String) continue;
      final downloadUrl = Uri.tryParse(url);
      if (downloadUrl == null) continue;
      assets.add(
        _AssetInfo(
          name: name,
          downloadUrl: downloadUrl,
          sha256: _parseDigest(map['digest']),
        ),
      );
    }
    return assets;
  }

  /// Extracts a sha256 hex digest from an asset's `digest` field, which
  /// GitHub formats as `<algorithm>:<hex>`; other algorithms read as absent.
  static String? _parseDigest(Object? raw) {
    if (raw is! String) return null;
    const prefix = 'sha256:';
    if (!raw.startsWith(prefix)) return null;
    final hex = raw.substring(prefix.length);
    return _sha256Hex.hasMatch(hex) ? hex.toLowerCase() : null;
  }

  Future<String?> _fetchCompanionChecksum(
    HttpClient client,
    List<_AssetInfo> assets,
    String dmgName,
  ) async {
    final expected = '$dmgName.sha256';
    for (final asset in assets) {
      if (asset.name != expected) continue;
      try {
        final body = await _getText(client, asset.downloadUrl);
        final match = RegExp(r'[0-9a-fA-F]{64}').firstMatch(body);
        return match?.group(0)?.toLowerCase();
      } catch (_) {
        return null;
      }
    }
    return null;
  }

  Future<Map<String, Object?>> _getJson(HttpClient client, Uri uri) async {
    final body = await _getText(client, uri);
    final decoded = jsonDecode(body);
    if (decoded is! Map) {
      throw const FormatException('top-level JSON value is not an object');
    }
    return decoded.cast<String, Object?>();
  }

  Future<String> _getText(HttpClient client, Uri uri) async {
    final request = await client.getUrl(uri);
    request.headers.set(
      HttpHeaders.acceptHeader,
      'application/vnd.github+json',
    );
    request.headers.set(
      HttpHeaders.userAgentHeader,
      'MacLauncher/$currentVersion',
    );
    final response = await request.close();
    final body = await utf8.decoder.bind(response).join();
    if (response.statusCode == HttpStatus.notFound) {
      throw const FormatException(
        'repository has no published full release yet (HTTP 404)',
      );
    }
    if (response.statusCode != HttpStatus.ok) {
      throw HttpException('unexpected HTTP ${response.statusCode}', uri: uri);
    }
    return body;
  }
}
