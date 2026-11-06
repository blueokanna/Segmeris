import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Native credentials use the platform vault. Web credentials last only for
/// this page session; JavaScript storage cannot provide an OS-backed vault.
class CredentialStore {
  CredentialStore._();

  static const _storage = FlutterSecureStorage(
    aOptions: AndroidOptions(resetOnError: false),
    mOptions: MacOsOptions(usesDataProtectionKeychain: false),
  );
  static final _session = <String, String>{};
  static Future<void>? _pending;

  static Future<T> _serial<T>(Future<T> Function() action) async {
    final previous = _pending;
    final completion = Completer<void>();
    _pending = completion.future;
    try {
      if (previous != null) await previous;
      return await action();
    } finally {
      if (identical(_pending, completion.future)) _pending = null;
      completion.complete();
    }
  }

  static Future<String?> read(String key) => _serial(() async {
        final prefs = await SharedPreferences.getInstance();
        if (kIsWeb) {
          await prefs.remove(key);
          return _session[key];
        }
        final stored = await _storage.read(key: key);
        if (stored != null) {
          await prefs.remove(key);
          return stored;
        }
        final legacy = prefs.getString(key);
        if (legacy != null) {
          await _storage.write(key: key, value: legacy);
          // Never delete the only copy before the vault confirms the write.
          if (await _storage.read(key: key) != legacy) {
            throw StateError('Credential migration could not be verified');
          }
          await prefs.remove(key);
        }
        return legacy;
      });

  static Future<void> write(String key, String? value) => _serial(() async {
        if (kIsWeb) {
          if (value == null || value.isEmpty) {
            _session.remove(key);
          } else {
            _session[key] = value;
          }
        } else if (value == null || value.isEmpty) {
          await _storage.delete(key: key);
        } else {
          await _storage.write(key: key, value: value);
        }
        final prefs = await SharedPreferences.getInstance();
        await prefs.remove(key);
      });
}
