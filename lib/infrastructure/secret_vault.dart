import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'direct_transfer_secret_store.dart';
import 'quick_device_store.dart';

const jet2DropSecretVaultStorageKey = 'jet2drop_secret_vault_v1';

abstract interface class SecretVaultBackend {
  Future<String?> read();

  Future<void> write(String value);
}

class FlutterSecureSecretVaultBackend implements SecretVaultBackend {
  FlutterSecureSecretVaultBackend({FlutterSecureStorage? storage})
    : _storage =
          storage ??
          const FlutterSecureStorage(
            mOptions: MacOsOptions(usesDataProtectionKeychain: false),
          );

  final FlutterSecureStorage _storage;

  @override
  Future<String?> read() => _storage.read(key: jet2DropSecretVaultStorageKey);

  @override
  Future<void> write(String value) =>
      _storage.write(key: jet2DropSecretVaultStorageKey, value: value);
}

/// One cached Keychain item for every Jet2Drop secret.
///
/// Ad-hoc macOS builds can prompt again after their code signature changes.
/// Keeping all secrets in one item prevents a prompt per known peer while the
/// in-memory cache prevents repeated reads during one app run.
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
