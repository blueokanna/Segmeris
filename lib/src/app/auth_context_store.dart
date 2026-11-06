import 'dart:convert';

import 'credential_store.dart';
import 'package:segmeris/src/rust/api/downloader.dart';

bool hasAuthOverrides(RequestContext context) =>
    context.cookie.trim().isNotEmpty ||
    context.userAgent.trim().isNotEmpty ||
    context.referer.trim().isNotEmpty ||
    context.origin.trim().isNotEmpty ||
    context.headers.isNotEmpty;

class AuthContextStore {
  const AuthContextStore._();

  static const _key = 'authContext';
  static const _version = 1;

  /// The stored session, or `null` when there is none worth applying.
  static Future<RequestContext?> load() async {
    String? raw;
    try {
      raw = await CredentialStore.read(_key);
    } on Exception {
      return null;
    }
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
    if (!hasAuthOverrides(context)) {
      await CredentialStore.write(_key, null);
      return;
    }
    await CredentialStore.write(
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

  static Future<void> clear() => CredentialStore.write(_key, null);

  static String _text(Object? value) => value is String ? value : '';
}
