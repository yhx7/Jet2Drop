import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// Stable key used for the local desktop receiver token.
const directTransferTokenStorageKey = 'direct_transfer_token';

/// Injectable boundary for the direct receiver's local secret.
///
/// A direct receiver must not fall back to [SharedPreferences] when this
/// storage is unavailable. Keeping this boundary injectable lets tests use a
/// deterministic in-memory implementation without weakening production
/// storage guarantees.
abstract interface class DirectTransferSecretStore {
  Future<String?> read();

  Future<void> write(String token);
}

/// Production adapter backed by the platform keychain/credential vault.
class FlutterSecureDirectTransferSecretStore
    implements DirectTransferSecretStore {
  FlutterSecureDirectTransferSecretStore({FlutterSecureStorage? storage})
    : _storage =
          storage ??
          const FlutterSecureStorage(
            mOptions: MacOsOptions(usesDataProtectionKeychain: false),
          );

  final FlutterSecureStorage _storage;

  @override
  Future<String?> read() => _storage.read(key: directTransferTokenStorageKey);

  @override
  Future<void> write(String token) =>
      _storage.write(key: directTransferTokenStorageKey, value: token);
}

/// Raised when a direct receiver cannot obtain a token from secure storage.
class DirectTransferSecretException implements Exception {
  const DirectTransferSecretException(this.message, {this.cause});

  final String message;
  final Object? cause;

  @override
  String toString() => message;
}
