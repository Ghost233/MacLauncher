import 'dart:convert';
import 'dart:io';

import 'package:launcher_core/launcher_core.dart';
import 'package:test/test.dart';

/// A local stub of the GitHub Releases API: serves a configurable release
/// document at `/repos/{owner}/{repo}/releases/latest` plus arbitrary text
/// routes (companion checksum assets), and records request paths/headers.
class _GitHubStub {
  late final HttpServer _server;

  int releaseStatus = HttpStatus.ok;
  Object? releaseBody; // jsonEncoded when non-null
  String? rawReleaseBody; // served verbatim when set (malformed JSON tests)

  /// Extra path -> (status, text body) routes, e.g. checksum asset downloads.
  final Map<String, (int, String)> textRoutes = {};

  final List<String> requestedPaths = [];
  String? lastUserAgent;
  String? lastAccept;

  Uri get baseUri => Uri.parse('http://127.0.0.1:${_server.port}');

  Future<void> start() async {
    _server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    _server.listen(_handle);
  }

  Future<void> stop() => _server.close(force: true);

  Future<void> _handle(HttpRequest request) async {
    final path = request.uri.path;
    requestedPaths.add(path);
    lastUserAgent = request.headers.value(HttpHeaders.userAgentHeader);
    lastAccept = request.headers.value(HttpHeaders.acceptHeader);
    final response = request.response;

    final route = textRoutes[path];
    if (route != null) {
      response.statusCode = route.$1;
      response.write(route.$2);
      await response.close();
      return;
    }
    if (path == '/repos/Ghost233/MacLauncher/releases/latest') {
      response.statusCode = releaseStatus;
      if (rawReleaseBody != null) {
        response.write(rawReleaseBody);
      } else if (releaseBody != null) {
        response.write(jsonEncode(releaseBody));
      }
      await response.close();
      return;
    }
    response.statusCode = HttpStatus.notFound;
    await response.close();
  }
}

Map<String, Object?> releaseJson({
  String tagName = 'v1.3.0',
  bool draft = false,
  bool prerelease = false,
  List<Object?>? assets,
}) => {
  'tag_name': tagName,
  'draft': draft,
  'prerelease': prerelease,
  'assets':
      assets ??
      [
        {
          'name': 'MacLauncher-1.3.0.dmg',
          'browser_download_url':
              'https://downloads.example.com/MacLauncher-1.3.0.dmg',
          'digest': 'sha256:${'ab' * 32}',
        },
      ],
};

void main() {
  group('SemVer', () {
    test('parses plain, v-prefixed, prerelease and build forms', () {
      expect(SemVer.tryParse('1.2.3').toString(), '1.2.3');
      expect(SemVer.tryParse('v1.2.3').toString(), '1.2.3');
      expect(SemVer.tryParse('1.2.3-rc.1').toString(), '1.2.3-rc.1');
      expect(SemVer.tryParse('1.2.3+45').toString(), '1.2.3+45');
      expect(SemVer.tryParse(' v1.2.3-rc.1+45 ').toString(), '1.2.3-rc.1+45');
    });

    test('rejects non-semver input', () {
      for (final raw in ['', '1.2', '1.2.3.4', 'a.b.c', '1.2.x', '1.2.3-']) {
        expect(SemVer.tryParse(raw), isNull, reason: raw);
      }
    });

    test('orders core numbers numerically', () {
      expect(SemVer.tryParse('1.2.3')!.compareTo(SemVer.tryParse('1.2.3')!), 0);
      expect(
        SemVer.tryParse('1.2.3')!.compareTo(SemVer.tryParse('1.2.10')!),
        isNegative,
      );
      expect(
        SemVer.tryParse('2.0.0')!.compareTo(SemVer.tryParse('10.0.0')!),
        isNegative,
      );
    });

    test('ignores build metadata in precedence (SemVer §10)', () {
      expect(
        SemVer.tryParse('1.2.3+4')!.compareTo(SemVer.tryParse('1.2.3+5')!),
        0,
      );
      expect(
        SemVer.tryParse('1.2.3+4')!.compareTo(SemVer.tryParse('1.2.3')!),
        0,
      );
      expect(
        SemVer.tryParse('1.2.3+4')!.compareTo(SemVer.tryParse('1.2.4')!),
        isNegative,
      );
    });

    test('a release outranks its prereleases; prereleases order per §11', () {
      final release = SemVer.tryParse('1.3.0')!;
      expect(SemVer.tryParse('1.3.0-rc.1')!.compareTo(release), isNegative);
      expect(release.compareTo(SemVer.tryParse('1.3.0-rc.1')!), isPositive);
      expect(
        SemVer.tryParse('1.3.0-alpha')!
            .compareTo(SemVer.tryParse('1.3.0-alpha.1')!),
        isNegative,
      );
      expect(
        SemVer.tryParse('1.3.0-alpha.1')!
            .compareTo(SemVer.tryParse('1.3.0-alpha.beta')!),
        isNegative, // numeric identifiers sort below alphanumeric ones
      );
      expect(
        SemVer.tryParse('1.3.0-rc.1')!
            .compareTo(SemVer.tryParse('1.3.0-rc.2')!),
        isNegative,
      );
    });
  });

  group('UpdateChecker', () {
    late _GitHubStub stub;

    UpdateChecker checker({String currentVersion = '1.2.0'}) =>
        UpdateChecker(currentVersion: currentVersion, baseUri: stub.baseUri);

    setUp(() async {
      stub = _GitHubStub();
      await stub.start();
    });

    tearDown(() => stub.stop());

    test(
      'newer release with DMG asset reports an update with digest',
      () async {
        stub.releaseBody = releaseJson();

        final result = await checker().checkForUpdate();

        final success = result as UpdateCheckSuccess;
        expect(success.hasUpdate, isTrue);
        expect(success.latestVersion, '1.3.0');
        expect(
          success.dmgDownloadUrl.toString(),
          'https://downloads.example.com/MacLauncher-1.3.0.dmg',
        );
        expect(success.sha256, 'ab' * 32);
        // The request must target the latest-release endpoint: GitHub's
        // "latest" is defined as the newest non-draft, non-prerelease release,
        // so the rolling-build prerelease named `latest` never matches it.
        expect(stub.requestedPaths, [
          '/repos/Ghost233/MacLauncher/releases/latest',
        ]);
        expect(stub.lastAccept, 'application/vnd.github+json');
        expect(stub.lastUserAgent, startsWith('MacLauncher/'));
      },
    );

    test('equal version reports no update', () async {
      stub.releaseBody = releaseJson(tagName: '1.2.0');
      final result = await checker().checkForUpdate();
      expect((result as UpdateCheckSuccess).hasUpdate, isFalse);
    });

    test('older release (current ahead) reports no update', () async {
      stub.releaseBody = releaseJson(tagName: '1.1.9');
      final result = await checker(currentVersion: '1.2.0').checkForUpdate();
      expect((result as UpdateCheckSuccess).hasUpdate, isFalse);
    });

    test(
      'build metadata never creates an update (1.2.0+4 vs 1.2.0+9)',
      () async {
        stub.releaseBody = releaseJson(tagName: 'v1.2.0+9');
        final result = await checker(currentVersion: '1.2.0+4')
            .checkForUpdate();
        final success = result as UpdateCheckSuccess;
        expect(success.hasUpdate, isFalse);
        expect(success.latestVersion, '1.2.0+9');
      },
    );

    test(
      'current prerelease updates to its release (1.3.0-rc.1 -> 1.3.0)',
      () async {
        stub.releaseBody = releaseJson(tagName: 'v1.3.0');
        final result = await checker(currentVersion: '1.3.0-rc.1')
            .checkForUpdate();
        expect((result as UpdateCheckSuccess).hasUpdate, isTrue);
      },
    );

    test('a payload marked prerelease is skipped even from /latest', () async {
      // Defensive guard: the endpoint must never do this, but if it does the
      // rolling `latest` build must still not surface as an update.
      stub.releaseBody = releaseJson(prerelease: true);
      final result = await checker().checkForUpdate();
      expect(result, isA<UpdateCheckFailure>());
      expect((result as UpdateCheckFailure).reason, contains('prerelease'));
    });

    test('network failure becomes a typed failure, never a throw', () async {
      final deadUri = stub.baseUri; // capture the port before closing
      await stub.stop(); // connection refused on the stub's port
      final result = await UpdateChecker(
        currentVersion: '1.2.0',
        baseUri: deadUri,
      ).checkForUpdate();
      expect(result, isA<UpdateCheckFailure>());
      expect((result as UpdateCheckFailure).cause, isNotNull);
    });

    test('HTTP 404 (no full release yet) is a typed failure', () async {
      stub.releaseStatus = HttpStatus.notFound;
      stub.releaseBody = null;
      final result = await checker().checkForUpdate();
      expect(result, isA<UpdateCheckFailure>());
      expect((result as UpdateCheckFailure).reason, contains('404'));
    });

    test('HTTP 500 is a typed failure', () async {
      stub.releaseStatus = HttpStatus.internalServerError;
      final result = await checker().checkForUpdate();
      expect(result, isA<UpdateCheckFailure>());
      expect((result as UpdateCheckFailure).reason, contains('500'));
    });

    test('missing tag_name is a malformed-payload failure', () async {
      stub.releaseBody = {'draft': false, 'prerelease': false, 'assets': []};
      final result = await checker().checkForUpdate();
      expect(result, isA<UpdateCheckFailure>());
      expect((result as UpdateCheckFailure).reason, contains('tag_name'));
    });

    test('non-object JSON is a malformed-payload failure', () async {
      stub.rawReleaseBody = '"just a string"';
      final result = await checker().checkForUpdate();
      expect(result, isA<UpdateCheckFailure>());
    });

    test('invalid JSON is a malformed-payload failure', () async {
      stub.rawReleaseBody = '{not json';
      final result = await checker().checkForUpdate();
      expect(result, isA<UpdateCheckFailure>());
    });

    test('unparseable release tag is a malformed-payload failure', () async {
      stub.releaseBody = releaseJson(tagName: 'nightly');
      final result = await checker().checkForUpdate();
      expect(result, isA<UpdateCheckFailure>());
      expect((result as UpdateCheckFailure).reason, contains('nightly'));
    });

    test('unparseable current version fails before any HTTP request', () async {
      final result = await checker(currentVersion: 'dev-build')
          .checkForUpdate();
      expect(result, isA<UpdateCheckFailure>());
      expect(stub.requestedPaths, isEmpty);
    });

    test('release without assets still reports the version', () async {
      stub.releaseBody = releaseJson(assets: []);
      final result = await checker().checkForUpdate();
      final success = result as UpdateCheckSuccess;
      expect(success.hasUpdate, isTrue);
      expect(success.dmgDownloadUrl, isNull);
      expect(success.sha256, isNull);
    });

    test('non-list assets field is a malformed-payload failure', () async {
      stub.releaseBody = {...releaseJson(), 'assets': 'none'};
      final result = await checker().checkForUpdate();
      expect(result, isA<UpdateCheckFailure>());
      expect((result as UpdateCheckFailure).reason, contains('assets'));
    });

    test(
      'release with no DMG asset has null download URL and sha256',
      () async {
        stub.releaseBody = releaseJson(
          assets: [
            {
              'name': 'MacLauncher-1.3.0.zip',
              'browser_download_url': 'https://downloads.example.com/x.zip',
              'digest': 'sha256:${'cd' * 32}',
            },
          ],
        );
        final result = await checker().checkForUpdate();
        final success = result as UpdateCheckSuccess;
        expect(success.hasUpdate, isTrue);
        expect(success.dmgDownloadUrl, isNull);
        expect(success.sha256, isNull);
      },
    );

    test('malformed asset entries are dropped, valid ones kept', () async {
      stub.releaseBody = releaseJson(
        assets: [
          {'browser_download_url': 'https://x/y.dmg'}, // no name
          {'name': 'broken.dmg'}, // no URL
          42,
          {
            'name': 'MacLauncher-1.3.0.dmg',
            'browser_download_url': 'https://downloads.example.com/ok.dmg',
            'digest': 'sha256:${'ef' * 32}',
          },
        ],
      );
      final result = await checker().checkForUpdate();
      final success = result as UpdateCheckSuccess;
      expect(
        success.dmgDownloadUrl.toString(),
        'https://downloads.example.com/ok.dmg',
      );
      expect(success.sha256, 'ef' * 32);
    });

    test('sha256 comes from the asset digest field', () async {
      stub.releaseBody = releaseJson(
        assets: [
          {
            'name': 'MacLauncher-1.3.0.dmg',
            'browser_download_url': 'https://downloads.example.com/a.dmg',
            'digest': 'sha256:${'AB' * 32}', // uppercase normalizes
          },
        ],
      );
      final result = await checker().checkForUpdate();
      expect((result as UpdateCheckSuccess).sha256, 'ab' * 32);
    });

    test('missing digest falls back to a sibling <dmg>.sha256 asset', () async {
      final hex = '0123456789abcdef' * 4;
      stub.releaseBody = releaseJson(
        assets: [
          {
            'name': 'MacLauncher-1.3.0.dmg',
            'browser_download_url': 'https://downloads.example.com/a.dmg',
            // no digest field
          },
          {
            'name': 'MacLauncher-1.3.0.dmg.sha256',
            // The companion URL is fetched verbatim; point it at the stub.
            'browser_download_url': '${stub.baseUri}/checksum',
          },
        ],
      );
      stub.textRoutes['/checksum'] = (200, '$hex  MacLauncher-1.3.0.dmg\n');

      final result = await checker().checkForUpdate();

      final success = result as UpdateCheckSuccess;
      expect(success.sha256, hex);
      expect(stub.requestedPaths, contains('/checksum'));
    });

    test('unreachable companion checksum degrades to null sha256', () async {
      stub.releaseBody = releaseJson(
        assets: [
          {
            'name': 'MacLauncher-1.3.0.dmg',
            'browser_download_url': 'https://downloads.example.com/a.dmg',
          },
          {
            'name': 'MacLauncher-1.3.0.dmg.sha256',
            'browser_download_url': '${stub.baseUri}/missing-checksum',
          },
        ],
      );
      final result = await checker().checkForUpdate();
      final success = result as UpdateCheckSuccess;
      expect(success.hasUpdate, isTrue);
      expect(success.sha256, isNull);
    });

    test('non-sha256 digest algorithms read as absent', () async {
      stub.releaseBody = releaseJson(
        assets: [
          {
            'name': 'MacLauncher-1.3.0.dmg',
            'browser_download_url': 'https://downloads.example.com/a.dmg',
            'digest': 'md5:${'ab' * 16}',
          },
        ],
      );
      final result = await checker().checkForUpdate();
      expect((result as UpdateCheckSuccess).sha256, isNull);
    });
  });
}
