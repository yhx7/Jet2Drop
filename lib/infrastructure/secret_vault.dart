import 'dart:convert';
import 'dart:io';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'direct_transfer_secret_store.dart';
import 'quick_device_store.dart';

const jet2DropSecretVaultStorageKey = 'jet2drop_secret_vault_v1';
const jet2DropSecretVaultAccountName = 'com.jet2drop.app.secrets';
const _legacyVaultMigratedKey = '__legacy_keychain_migrated';

abstract interface class SecretVaultBackend {
  Future<String?> read();

  Future<void> write(String value);
}

class FlutterSecureSecretVaultBackend implements SecretVaultBackend {
  FlutterSecureSecretVaultBackend({
    FlutterSecureStorage? storage,
    FlutterSecureStorage? legacyStorage,
  }) : _migrateLegacy = storage == null || legacyStorage != null,
       _storage =
           storage ??
           const FlutterSecureStorage(
             mOptions: MacOsOptions(
               accountName: jet2DropSecretVaultAccountName,
               // Data Protection Keychain requires a development identity.
               // Jet2Drop's current personal ad-hoc builds instead use one
               // dedicated legacy item, avoiding the plugin's shared default.
               usesDataProtectionKeychain: false,
             ),
           ),
       _legacyStorage =
           legacyStorage ??
           const FlutterSecureStorage(
             mOptions: MacOsOptions(usesDataProtectionKeychain: false),
           );

  final FlutterSecureStorage _storage;
  final FlutterSecureStorage _legacyStorage;
  final bool _migrateLegacy;

  @override
  Future<String?> read() async {
    final current = await _storage.read(key: jet2DropSecretVaultStorageKey);
    if (!Platform.isMacOS || !_migrateLegacy) {
      return current;
    }
    final values = _decodeVaultValues(current);
    if (values[_legacyVaultMigratedKey] == '1') return current;

    // The dedicated service was introduced after older builds had already
    // stored credentials under the plugin default. Merge once, keeping newer
    // values when both items exist, then avoid touching the legacy item again.
    final legacy = _decodeVaultValues(
      await _legacyStorage.read(key: jet2DropSecretVaultStorageKey),
    );
    for (final entry in legacy.entries) {
      values.putIfAbsent(entry.key, () => entry.value);
    }
    values[_legacyVaultMigratedKey] = '1';
    final merged = jsonEncode(values);
    await _storage.write(key: jet2DropSecretVaultStorageKey, value: merged);
    return merged;
  }

  @override
  Future<void> write(String value) =>
      _storage.write(key: jet2DropSecretVaultStorageKey, value: value);
}

Map<String, String> _decodeVaultValues(String? raw) {
  if (raw == null || raw.trim().isEmpty) return <String, String>{};
  try {
    final decoded = jsonDecode(raw);
    if (decoded is! Map) return <String, String>{};
    return {
      for (final entry in decoded.entries)
        if (entry.key is String && entry.value is String)
          entry.key as String: entry.value as String,
    };
  } catch (_) {
    return <String, String>{};
  }
}

/// One cached Keychain item for every Jet2Drop secret.
///
/// Keeping all secrets in one application-scoped item prevents a prompt per
/// known peer while the in-memory cache prevents repeated reads in one run.
class Jet2DropSecretVault {
  Jet2DropSecretVault({SecretVaultBackend? backend})
    : _backend = backend ?? FlutterSecureSecretVaultBackend();

  final SecretVaultBackend _backend;
  Map<String, String>? _values;
  Future<Map<String, String>>? _loadFuture;
  Future<void> _operationTail = Future<void>.value();

  Future<String?> read(String key) async {
    await _operationTail;
    final values = await _load();
    return values[key];
  }

  Future<void> write(String key, String value) => _enqueue(() async {
    final values = await _load();
    values[key] = value;
    await _backend.write(jsonEncode(values));
  });

  Future<void> delete(String key) => _enqueue(() async {
    final values = await _load();
    if (values.remove(key) != null) await _backend.write(jsonEncode(values));
  });

  Future<Map<String, String>> _load() async {
    final cached = _values;
    if (cached != null) return cached;
    final pending = _loadFuture;
    if (pending != null) return pending;
    final operation = _loadUncached();
    _loadFuture = operation;
    try {
      return await operation;
    } finally {
      if (identical(_loadFuture, operation)) _loadFuture = null;
    }
  }

  Future<Map<String, String>> _loadUncached() async {
    final values = <String, String>{};
    final raw = await _backend.read();
    if (raw != null && raw.trim().isNotEmpty) {
      try {
        final decoded = jsonDecode(raw);
        if (decoded is Map) {
          for (final entry in decoded.entries) {
            if (entry.key is String && entry.value is String) {
              values[entry.key as String] = entry.value as String;
            }
          }
        }
      } catch (_) {
        // A corrupt vault starts empty. The next successful write replaces it.
      }
    }
    _values = values;
    return values;
  }

  Future<void> _enqueue(Future<void> Function() operation) {
    final next = _operationTail.then((_) => operation());
    _operationTail = next.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    return next;
  }
}

class VaultDirectTransferSecretStore implements DirectTransferSecretStore {
  VaultDirectTransferSecretStore(this.vault);

  final Jet2DropSecretVault vault;

  @override
  Future<String?> read() => vault.read(directTransferTokenStorageKey);

  @override
  Future<void> write(String token) =>
      vault.write(directTransferTokenStorageKey, token);
}

class VaultQuickDeviceSecretStore implements QuickDeviceSecretStore {
  VaultQuickDeviceSecretStore(this.vault);

  final Jet2DropSecretVault vault;

  @override
  Future<String?> read(String deviceId) =>
      vault.read(quickDevicePeerTokenKey(deviceId));

  @override
  Future<void> write(String deviceId, String token) =>
      vault.write(quickDevicePeerTokenKey(deviceId), token);

  @override
  Future<void> delete(String deviceId) =>
      vault.delete(quickDevicePeerTokenKey(deviceId));
}
