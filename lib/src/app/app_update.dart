import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';

import 'app_update_platform_stub.dart'
    if (dart.library.io) 'app_update_platform_io.dart'
    as host;

/// Public releases only. No token, custom server, redirect or executable code.
const appUpdateRepository = 'blueokanna/Segmeris';
final appUpdateApi = Uri.https(
  'api.github.com',
  '/repos/$appUpdateRepository/releases',
  {'per_page': '100'},
);
const appUpdateInterval = Duration(hours: 24);

@immutable
class AppVersion implements Comparable<AppVersion> {
  const AppVersion(this.major, this.minor, this.patch, this.pre, this.build);

  final BigInt major;
  final BigInt minor;
  final BigInt patch;
  final List<String> pre;
  final int? build;

  static AppVersion? tryParse(String text, {String? buildNumber}) {
    final match = RegExp(
      r'^v?(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)'
      r'(?:-([0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*))?'
      r'(?:\+([0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*))?$',
    ).firstMatch(text);
    if (match == null || match.end != text.length) return null;
    final pre = match[4]?.split('.') ?? const <String>[];
    if (pre.any((p) => RegExp(r'^0\d+$').hasMatch(p))) return null;
    final numbers = [for (var i = 1; i <= 3; i++) BigInt.tryParse(match[i]!)];
    if (numbers.any((n) => n == null)) return null;
    final buildText = buildNumber ?? match[5] ?? '';
    final build = RegExp(r'^\d+$').hasMatch(buildText)
        ? int.tryParse(buildText)
        : null;
    return AppVersion(
      numbers[0]!,
      numbers[1]!,
      numbers[2]!,
      List.unmodifiable(pre),
      build != null && build >= 0 ? build : null,
    );
  }

  String get core => '$major.$minor.$patch';

  /// SemVer precedence ignores build metadata. Numeric package build numbers
  /// are compared separately, only for the same release version.
  @override
  int compareTo(AppVersion other) {
    for (final pair in [
      (major, other.major),
      (minor, other.minor),
      (patch, other.patch),
    ]) {
      final result = pair.$1.compareTo(pair.$2);
      if (result != 0) return result;
    }
    if (pre.isEmpty || other.pre.isEmpty) {
      return pre.isEmpty == other.pre.isEmpty ? 0 : (pre.isEmpty ? 1 : -1);
    }
    for (var i = 0; i < pre.length && i < other.pre.length; i++) {
      final a = pre[i];
      final b = other.pre[i];
      final numericA = RegExp(r'^\d+$').hasMatch(a);
      final numericB = RegExp(r'^\d+$').hasMatch(b);
      final result = numericA && numericB
          ? (a.length == b.length
                ? a.compareTo(b)
                : a.length.compareTo(b.length))
          : numericA != numericB
          ? (numericA ? -1 : 1)
          : a.compareTo(b);
      if (result != 0) return result;
    }
    return pre.length.compareTo(other.pre.length);
  }

  bool isNewerThan(AppVersion other) {
    final precedence = compareTo(other);
    return precedence > 0 ||
        (precedence == 0 &&
            build != null &&
            other.build != null &&
            build! > other.build!);
  }
}

@immutable
class AppUpdateTarget {
  const AppUpdateTarget(this.platform, this.architecture);
  final String platform;
  final String architecture;

  factory AppUpdateTarget.current() =>
      AppUpdateTarget(host.updateOperatingSystem(), host.updateArchitecture());

  List<String> get assetSuffixes => switch ((platform, architecture)) {
    ('android', 'arm64') => const ['android-arm64-v8a.apk'],
    ('android', 'arm') => const ['android-armeabi-v7a.apk'],
    ('android', 'x64') => const ['android-x86_64.apk'],
    ('windows', 'x64') => const ['windows-x64-setup.exe', 'windows-x64.zip'],
    ('linux', 'x64') => const ['linux-x64.tar.gz'],
    ('macos', 'arm64') => const ['macos-arm64-unsigned.zip', 'macos-arm64.zip'],
    ('macos', 'x64') => const ['macos-x64-unsigned.zip', 'macos-x64.zip'],
    _ => const [],
  };
}

bool _officialUri(Uri uri) =>
    uri.scheme == 'https' &&
    uri.host == 'github.com' &&
    uri.port == 443 &&
    uri.userInfo.isEmpty &&
    !uri.hasQuery &&
    !uri.hasFragment;

bool isOfficialUpdateUrl(Uri uri, {required String tag, String? assetName}) {
  if (!_officialUri(uri) ||
      AppVersion.tryParse(tag) == null ||
      RegExp(r'%2f|%5c|%2e', caseSensitive: false).hasMatch(uri.toString())) {
    return false;
  }
  final expected = assetName == null
      ? ['blueokanna', 'Segmeris', 'releases', 'tag', tag]
      : ['blueokanna', 'Segmeris', 'releases', 'download', tag, assetName];
  return listEquals(uri.pathSegments, expected) &&
      !uri.pathSegments.any(
        (s) => s.contains('/') || s.contains('\\') || s == '..',
      );
}

@immutable
class AppUpdateAsset {
  const AppUpdateAsset({
    required this.name,
    required this.url,
    required this.size,
  });
  final String name;
  final Uri url;
  final int size;
}

@immutable
class AppUpdateRelease {
  const AppUpdateRelease({
    required this.tag,
    required this.version,
    required this.notes,
    required this.pageUrl,
    required this.asset,
    this.checksumsUrl,
  });
  final String tag;
  final AppVersion version;
  final String notes;
  final Uri pageUrl;
  final AppUpdateAsset? asset;
  final Uri? checksumsUrl;

  static AppUpdateRelease? fromJson(
    Map<String, dynamic> json,
    AppUpdateTarget target,
  ) {
    if (json['draft'] != false || json['prerelease'] != false) return null;
    final tag = json['tag_name'];
    if (tag is! String) return null;
    final parsedVersion = AppVersion.tryParse(tag);
    if (parsedVersion == null || parsedVersion.pre.isNotEmpty) return null;
    var version = parsedVersion;
    final page = Uri.tryParse(
      json['html_url'] is String ? json['html_url'] as String : '',
    );
    if (page == null || !isOfficialUpdateUrl(page, tag: tag)) return null;
    var notes = json['body'] is String ? json['body'] as String : '';
    final marker = RegExp(r'<!-- segmeris-release (\{[^\r\n]*\}) -->')
        .firstMatch(notes);
    if (marker != null) {
      try {
        final metadata = jsonDecode(marker[1]!);
        if (metadata is Map &&
            metadata['version'] == version.core &&
            metadata['build_number'] is int &&
            (metadata['build_number'] as int) >= 0) {
          version = AppVersion.tryParse(
            tag,
            buildNumber: '${metadata['build_number']}',
          )!;
        }
      } on FormatException {
        /* An invalid optional marker cannot change the version. */
      }
      notes = notes.replaceFirst(marker[0]!, '').trim();
    }
    final assets = json['assets'] is List ? json['assets'] as List : const [];
    final names = <String>{};
    Uri? checksumsUrl;
    for (final item in assets) {
      if (item is! Map || item['name'] is! String) continue;
      if (!names.add(item['name'] as String)) return null;
      if (item['name'] == 'SHA256SUMS' &&
          item['state'] == 'uploaded' &&
          item['size'] is int &&
          (item['size'] as int) > 0 &&
          item['browser_download_url'] is String) {
        final uri = Uri.tryParse(item['browser_download_url'] as String);
        if (uri != null &&
            isOfficialUpdateUrl(uri, tag: tag, assetName: 'SHA256SUMS')) {
          checksumsUrl = uri;
        }
      }
    }
    AppUpdateAsset? selected;
    for (final suffix in target.assetSuffixes) {
      final expectedNames = {'Segmeris-$tag-$suffix', 'Segmeris-$suffix'};
      for (final item in assets) {
        if (item is! Map ||
            item['name'] is! String ||
            !expectedNames.contains(item['name'])) {
          continue;
        }
        final name = item['name'] as String;
        final url = Uri.tryParse(
          item['browser_download_url'] is String
              ? item['browser_download_url'] as String
              : '',
        );
        if (url == null ||
            !isOfficialUpdateUrl(url, tag: tag, assetName: name) ||
            item['size'] is! int ||
            (item['size'] as int) <= 0 ||
            item['state'] != 'uploaded') {
          continue;
        }
        selected = AppUpdateAsset(
          name: name,
          url: url,
          size: item['size'] as int,
        );
        break;
      }
      if (selected != null) break;
    }
    return AppUpdateRelease(
      tag: tag,
      version: version,
      notes: notes,
      pageUrl: page,
      asset: checksumsUrl == null ? null : selected,
      checksumsUrl: checksumsUrl,
    );
  }
}

abstract interface class AppUpdateStore {
  Future<String?> read();
  Future<void> write(String value);
}

class PreferencesAppUpdateStore implements AppUpdateStore {
  const PreferencesAppUpdateStore();
  static const key = 'segmeris.app_update.success.v1';
  @override
  Future<String?> read() async =>
      (await SharedPreferences.getInstance()).getString(key);
  @override
  Future<void> write(String value) async {
    final preferences = await SharedPreferences.getInstance();
    if (!await preferences.setString(key, value)) {
      throw StateError('Could not save update check');
    }
  }
}

class AppUpdateException implements Exception {
  const AppUpdateException(this.message, {this.retryAt});
  final String message;
  final DateTime? retryAt;
  @override
  String toString() => message;
}

@immutable
class AppUpdateCheck {
  const AppUpdateCheck({
    required this.release,
    required this.checkedAt,
    required this.cached,
  });
  final AppUpdateRelease? release;
  final DateTime checkedAt;
  final bool cached;
}

class AppUpdateService {
  AppUpdateService({
    required this.currentVersion,
    required this.target,
    required this.store,
    http.Client? client,
    DateTime Function()? clock,
    this.timeout = const Duration(seconds: 12),
  }) : _client = client ?? http.Client(),
       _clock = clock ?? DateTime.now;

  final AppVersion currentVersion;
  final AppUpdateTarget target;
  final AppUpdateStore store;
  final http.Client _client;
  final DateTime Function() _clock;
  final Duration timeout;
  Future<AppUpdateCheck>? _inFlight;
  Map<String, dynamic>? _memoryCache;
  Completer<void>? _abort;
  DateTime? _retryAt;
  bool _disposed = false;
  DateTime? get retryAt => _retryAt;
  static const _storageTimeout = Duration(seconds: 2);

  Future<AppUpdateCheck> check({bool manual = false}) {
    if (_disposed) {
      return Future.error(
        const AppUpdateException('Update checker is closed.'),
      );
    }
    return _inFlight ??= _check(manual).whenComplete(() => _inFlight = null);
  }

  Future<AppUpdateCheck> _check(bool manual) async {
    final now = _clock().toUtc();
    try {
      final cached =
          _memoryCache ??
          jsonDecode(await store.read().timeout(_storageTimeout) ?? 'null');
      if (cached is Map<String, dynamic>) {
        _memoryCache = cached;
        final retry = DateTime.tryParse(cached['retry_at'] as String? ?? '');
        if (retry != null &&
            retry.isAfter(now) &&
            retry.difference(now) <= appUpdateInterval) {
          _retryAt = retry;
        }
        final checked = DateTime.tryParse(
          cached['checked_at'] as String? ?? '',
        );
        final age = checked == null ? null : now.difference(checked);
        if (!manual &&
            age != null &&
            !age.isNegative &&
            age < appUpdateInterval &&
            cached['releases'] is List) {
          return AppUpdateCheck(
            release: _select(cached['releases'] as List),
            checkedAt: checked!,
            cached: true,
          );
        }
      }
    } catch (_) {
      /* Corrupt or unavailable storage must not disable checks. */
    }
    if (_disposed) throw const AppUpdateException('Update checker is closed.');
    if (_retryAt != null && now.isBefore(_retryAt!)) {
      throw AppUpdateException(
        'GitHub rate limit reached. Please retry after ${_retryAt!.toLocal()}.',
        retryAt: _retryAt,
      );
    }
    final abort = Completer<void>();
    _abort = abort;
    try {
      final fetched = await _fetch(abort.future).timeout(timeout);
      final release = _select(fetched.releases);
      final checkedAt = _clock().toUtc();
      _memoryCache = {
        'checked_at': checkedAt.toIso8601String(),
        'releases': fetched.releases,
        if (fetched.etag != null) 'etag': fetched.etag,
        if (_retryAt != null) 'retry_at': _retryAt!.toIso8601String(),
      };
      await _persist();
      return AppUpdateCheck(
        release: release,
        checkedAt: checkedAt,
        cached: false,
      );
    } on AppUpdateException catch (error) {
      if (error.retryAt != null) {
        // Save the server's retry deadline separately from the last SUCCESS.
        _memoryCache = {
          ...?_memoryCache,
          'retry_at': error.retryAt!.toIso8601String(),
        };
        await _persist();
      }
      rethrow;
    } on TimeoutException {
      throw const AppUpdateException('Update check timed out. Please retry.');
    } catch (_) {
      throw const AppUpdateException(
        'Could not check for updates. Check your connection and retry.',
      );
    } finally {
      // IOClient and BrowserClient abort the actual connection/stream here.
      if (!abort.isCompleted) abort.complete();
      if (identical(_abort, abort)) _abort = null;
    }
  }

  Future<void> _persist() async {
    try {
      await store.write(jsonEncode(_memoryCache)).timeout(_storageTimeout);
    } catch (_) {
      /* A failed disk write cannot turn a successful check into failure. */
    }
  }

  Future<({List<dynamic> releases, String? etag})> _fetch(
    Future<void> abort,
  ) async {
    final oldEtag = _memoryCache?['etag'];
    final oldReleases = _memoryCache?['releases'];
    final etag =
        oldEtag is String &&
            oldEtag.length <= 256 &&
            !oldEtag.contains(RegExp(r'[\r\n]')) &&
            oldReleases is List
        ? oldEtag
        : null;
    final request =
        http.AbortableRequest('GET', appUpdateApi, abortTrigger: abort)
          ..followRedirects = false
          ..maxRedirects = 0
          ..headers.addAll({
            'Accept': 'application/vnd.github+json',
            'X-GitHub-Api-Version': '2022-11-28',
            'User-Agent': 'Segmeris-update-checker',
            'If-None-Match': ?etag,
          });
    final response = await _client.send(request);
    if (response.statusCode == 403 ||
        response.statusCode == 429 ||
        response.headers['x-ratelimit-remaining'] == '0') {
      _retryAt = _retryDeadline(response.headers, _clock().toUtc());
    }
    if (response.statusCode == 304 && etag != null && oldReleases is List) {
      unawaited(response.stream.listen((_) {}).cancel());
      return (releases: oldReleases, etag: etag);
    }
    if (response.statusCode != 200) {
      unawaited(response.stream.listen((_) {}).cancel());
      if (response.statusCode == 403 || response.statusCode == 429) {
        throw AppUpdateException(
          'GitHub rate limit reached. Please retry after ${_retryAt!.toLocal()}.',
          retryAt: _retryAt,
        );
      }
      throw AppUpdateException(
        'GitHub update check failed (HTTP ${response.statusCode}). Please retry.',
      );
    }
    final bytes = BytesBuilder(copy: false);
    await for (final chunk in response.stream) {
      if (bytes.length + chunk.length > 4 * 1024 * 1024) {
        throw const AppUpdateException('The update response is too large.');
      }
      bytes.add(chunk);
    }
    final data = jsonDecode(utf8.decode(bytes.takeBytes()));
    if (data is! List ||
        data.any(
          (item) =>
              item is! Map<String, dynamic> ||
              item['draft'] is! bool ||
              item['prerelease'] is! bool ||
              item['tag_name'] is! String ||
              item['html_url'] is! String ||
              item['assets'] is! List,
        )) {
      throw const AppUpdateException(
        'GitHub returned an invalid release list.',
      );
    }
    // Retain only the public release fields consumed by this checker.
    final releases = [
      for (final item in data)
        {
          for (final key in [
            'draft',
            'prerelease',
            'tag_name',
            'html_url',
            'body',
          ])
            key: item[key],
          'assets': [
            if (item['assets'] is List)
              for (final asset in item['assets'] as List)
                if (asset is Map)
                  {
                    for (final key in [
                      'name',
                      'browser_download_url',
                      'size',
                      'state',
                    ])
                      key: asset[key],
                  },
          ],
        },
    ];
    return (releases: releases, etag: response.headers['etag']);
  }

  static DateTime _retryDeadline(Map<String, String> headers, DateTime now) {
    final seconds = int.tryParse(headers['retry-after'] ?? '');
    final reset = int.tryParse(headers['x-ratelimit-reset'] ?? '');
    final retryDate = _httpDate(headers['retry-after']);
    final candidates = <DateTime>[
      if (seconds != null && seconds >= 0 && seconds <= 86400)
        now.add(Duration(seconds: seconds)),
      ?retryDate,
      if (reset != null && reset >= 0 && reset < 8640000000000)
        DateTime.fromMillisecondsSinceEpoch(reset * 1000, isUtc: true),
    ];
    var deadline = now.add(const Duration(minutes: 1));
    var valid = false;
    for (final candidate in candidates) {
      if (candidate.isAfter(now) &&
          candidate.difference(now) <= appUpdateInterval) {
        valid = true;
        if (candidate.isAfter(deadline)) deadline = candidate;
      }
    }
    return valid ? deadline : now.add(const Duration(hours: 1));
  }

  static DateTime? _httpDate(String? value) {
    if (value == null) return null;
    final match = RegExp(
      r'^[A-Za-z]{3}, (\d{2}) ([A-Za-z]{3}) (\d{4}) (\d{2}):(\d{2}):(\d{2}) GMT$',
    ).firstMatch(value);
    if (match == null) return null;
    const months = [
      'Jan',
      'Feb',
      'Mar',
      'Apr',
      'May',
      'Jun',
      'Jul',
      'Aug',
      'Sep',
      'Oct',
      'Nov',
      'Dec',
    ];
    final month = months.indexOf(match[2]!);
    if (month < 0) return null;
    return DateTime.utc(
      int.parse(match[3]!),
      month + 1,
      int.parse(match[1]!),
      int.parse(match[4]!),
      int.parse(match[5]!),
      int.parse(match[6]!),
    );
  }

  AppUpdateRelease? _select(List<dynamic> releases) {
    AppUpdateRelease? newest;
    for (final json in releases) {
      if (json is! Map<String, dynamic> ||
          json['draft'] is! bool ||
          json['prerelease'] is! bool) {
        throw const AppUpdateException('GitHub returned an invalid release.');
      }
      if (json['draft'] == true || json['prerelease'] == true) continue;
      final version = json['tag_name'] is String
          ? AppVersion.tryParse(json['tag_name'] as String)
          : null;
      if (version == null) continue; // Ignore historical non-version tags.
      if (version.pre.isNotEmpty) continue;
      final candidate = AppUpdateRelease.fromJson(json, target);
      if (candidate == null) {
        throw const AppUpdateException(
          'GitHub returned an invalid release URL or duplicate assets.',
        );
      }
      if (candidate.version.isNewerThan(currentVersion) &&
          (newest == null || candidate.version.isNewerThan(newest.version))) {
        newest = candidate;
      }
    }
    return newest;
  }

  void dispose() {
    _disposed = true;
    final abort = _abort;
    if (abort != null && !abort.isCompleted) abort.complete();
    _client.close();
  }
}

/// The host owns this notifier and disposes it with its app state.
/// Checking never downloads or installs; [openRelease] is a user action only.
class AppUpdateController extends ChangeNotifier {
  AppUpdateController(this.service, {Future<bool> Function(Uri)? opener})
    : _opener =
          opener ??
          ((uri) => launchUrl(uri, mode: LaunchMode.externalApplication));
  final AppUpdateService service;
  final Future<bool> Function(Uri) _opener;
  bool checking = false;
  bool opening = false;
  bool dismissed = false;
  String? error;
  AppUpdateCheck? result;
  bool _disposed = false;
  AppUpdateRelease? get release => result?.release;
  bool get hasUpdate => release != null && !dismissed;

  static Future<AppUpdateController> create() async {
    final package = await PackageInfo.fromPlatform().timeout(
      const Duration(seconds: 12),
    );
    final version = AppVersion.tryParse(
      package.version,
      buildNumber: package.buildNumber,
    );
    if (version == null) {
      throw const AppUpdateException('Installed app version is invalid.');
    }
    return AppUpdateController(
      AppUpdateService(
        currentVersion: version,
        target: AppUpdateTarget.current(),
        store: const PreferencesAppUpdateStore(),
      ),
    );
  }

  Future<void> check({bool manual = false}) async {
    if (_disposed || checking) return;
    checking = true;
    error = null;
    if (manual) dismissed = false;
    notifyListeners();
    try {
      final next = await service.check(manual: manual);
      if (_disposed) return;
      if (next.release?.tag != release?.tag) dismissed = false;
      result = next;
    } catch (e) {
      if (!_disposed) {
        error = e is AppUpdateException
            ? e.message
            : 'Could not check for updates. Please retry.';
      }
    } finally {
      if (!_disposed) {
        checking = false;
        notifyListeners();
      }
    }
  }

  void dismiss() {
    if (!_disposed) {
      dismissed = true;
      notifyListeners();
    }
  }

  Future<bool> openRelease({bool downloadAsset = false}) async {
    final available = release;
    if (_disposed || opening || available == null) return false;
    final asset = downloadAsset ? available.asset : null;
    final url = asset?.url ?? available.pageUrl;
    if (!isOfficialUpdateUrl(url, tag: available.tag, assetName: asset?.name)) {
      return false;
    }
    opening = true;
    error = null;
    notifyListeners();
    try {
      final opened = await _opener(url);
      if (!opened && !_disposed) {
        error = 'Could not open the browser. Please retry.';
      }
      return opened;
    } catch (_) {
      if (!_disposed) error = 'Could not open the browser. Please retry.';
      return false;
    } finally {
      if (!_disposed) {
        opening = false;
        notifyListeners();
      }
    }
  }

  @override
  void dispose() {
    _disposed = true;
    service.dispose();
    super.dispose();
  }
}
