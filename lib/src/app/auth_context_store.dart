import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';
import 'package:segmeris/src/rust/api/downloader.dart';

/// Whether a request context carries anything an anonymous request would not.
///
/// The engine fills in its own defaults for whatever is absent, so an empty
/// context means "no session", not "broken session".
bool hasAuthOverrides(RequestContext context) =>
    context.cookie.trim().isNotEmpty ||
    context.userAgent.trim().isNotEmpty ||
    context.referer.trim().isNotEmpty ||
    context.origin.trim().isNotEmpty ||
    context.headers.isNotEmpty;

/// The authorized session, kept across launches.
///
/// Signing in is the expensive, user-visible part of reaching a gated stream:
/// making the owner repeat it on every start would be a defect, not a
/// preference. The session is account material, so it lives in the app's
/// private preferences — the Android manifest sets `allowBackup="false"` to
/// keep it out of cloud backups — and it is deleted the moment the user asks
/// for it to be cleared.
///
/// Serialization is versioned and total: an unreadable or future payload
/// yields `null` (no session) rather than a crash on startup.
class AuthContextStore {
  const AuthContextStore._();

  static const _key = 'authContext';
  static const _version = 1;

  /// The stored session, or `null` when there is none worth applying.
  static Future<RequestContext?> load() async {
    final prefs = await _preferences();
    if (prefs == null) {
      return null;
    }
    final raw = prefs.getString(_key);
    if (raw == null || raw.trim().isEmpty) {
      return null;
    }
    Object? decoded;
    try {
      decoded = jsonDecode(raw);
    } on FormatException {
      return null;
    }
    if (decoded is! Map || decoded['v'] != _version) {
      return null;
    }

    final headers = <HeaderEntry>[];
    final rawHeaders = decoded['headers'];
    if (rawHeaders is List) {
      for (final entry in rawHeaders) {
        if (entry is! Map) {
          continue;
        }
        final name = _text(entry['name']);
        final value = _text(entry['value']);
        if (name.isEmpty || value.isEmpty) {
          continue;
        }
        headers.add(HeaderEntry(name: name, value: value));
      }
    }

    final context = RequestContext(
      userAgent: _text(decoded['ua']),
      referer: _text(decoded['referer']),
      origin: _text(decoded['origin']),
      cookie: _text(decoded['cookie']),
      headers: headers,
    );
    return hasAuthOverrides(context) ? context : null;
  }

  /// Persist the session, or drop the stored one when nothing is left.
  static Future<void> save(RequestContext context) async {
    final prefs = await _preferences();
    if (prefs == null) {
      return;
    }
    if (!hasAuthOverrides(context)) {
      await prefs.remove(_key);
      return;
    }
    await prefs.setString(
      _key,
      jsonEncode({
        'v': _version,
        'ua': context.userAgent,
        'referer': context.referer,
        'origin': context.origin,
        'cookie': context.cookie,
        'headers': [
          for (final header in context.headers)
            {'name': header.name, 'value': header.value},
        ],
      }),
    );
  }

  static Future<void> clear() async {
    final prefs = await _preferences();
    await prefs?.remove(_key);
  }

  /// Preferences, or `null` when the platform store is unreachable.
  ///
  /// Storage that cannot be opened must not break a launch or a download: a
  /// session that cannot be read simply means "not signed in" this run.
  static Future<SharedPreferences?> _preferences() async {
    try {
      return await SharedPreferences.getInstance();
    } on Exception {
      return null;
    }
  }

  static String _text(Object? value) => value is String ? value : '';
}
