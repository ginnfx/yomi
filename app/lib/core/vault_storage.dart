import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

const String _vaultKey = 'yomi.vault.v1';

/// Keeps everything Yomi stores securely in a single Keychain item.
///
/// On a Mac, every Keychain item asks for the login password separately when the
/// app isn't the one that created it, and an app signed without a paid developer
/// account counts as a new app after each update. One item means one question,
/// not one per saved setting. Earlier versions kept one item per setting; they are
/// moved into the vault the first time it is opened, and the old ones removed.
class VaultStorage {
  VaultStorage(this._inner, {required this.legacyKeys, this.isVaultOn = true});

  final FlutterSecureStorage _inner;

  /// Where earlier versions kept each value.
  final List<String> legacyKeys;

  /// Off, values go straight to the platform's storage (Android and iOS have
  /// no per-item prompt).
  final bool isVaultOn;

  Future<Map<String, String>>? _loading;
  Future<void> _writes = Future.value();

  Future<String?> read({required String key}) async {
    if (!isVaultOn) return _inner.read(key: key);
    return (await _load())[key];
  }

  Future<void> write({required String key, required String? value}) async {
    if (!isVaultOn) {
      await _inner.write(key: key, value: value);
      return;
    }
    final values = await _load();
    if (value == null) {
      values.remove(key);
    } else {
      values[key] = value;
    }
    await _save(values);
  }

  Future<void> deleteAll() async {
    if (!isVaultOn) {
      await _inner.deleteAll();
      return;
    }
    _loading = null;
    await _writes;
    await _inner.deleteAll();
  }

  Future<Map<String, String>> _load() => _loading ??= _open();

  Future<Map<String, String>> _open() async {
    final saved = await _inner.read(key: _vaultKey);
    if (saved != null) {
      try {
        final decoded = jsonDecode(saved);
        if (decoded is Map<String, dynamic>) {
          return {
            for (final entry in decoded.entries)
              if (entry.value is String) entry.key: entry.value as String,
          };
        }
      } on FormatException catch (error) {
        debugPrint('The saved login data was damaged: $error');
      }
      return {};
    }
    return _migrate();
  }

  Future<Map<String, String>> _migrate() async {
    final values = <String, String>{};
    for (final key in legacyKeys) {
      final value = await _inner.read(key: key);
      if (value != null) values[key] = value;
    }
    if (values.isEmpty) return values;
    await _inner.write(key: _vaultKey, value: jsonEncode(values));
    for (final key in values.keys) {
      await _inner.delete(key: key);
    }
    return values;
  }

  Future<void> _save(Map<String, String> values) {
    final encoded = jsonEncode(values);
    // One write at a time, in order, so a slow one can't overwrite a newer one.
    _writes = _writes.then((_) => _inner.write(key: _vaultKey, value: encoded));
    return _writes;
  }
}
