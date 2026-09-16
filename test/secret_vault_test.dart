import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:jet2drop/infrastructure/secret_vault.dart';

class _MemoryBackend implements SecretVaultBackend {
  String? value;
  int reads = 0;
  int writes = 0;
  Duration readDelay = Duration.zero;

  @override
  Future<String?> read() async {
    reads++;
    if (readDelay > Duration.zero) await Future<void>.delayed(readDelay);
    return value;
  }

  @override
  Future<void> write(String value) async {
    writes++;
    this.value = value;
  }
}

class _MemorySecureStorage extends FlutterSecureStorage {
  _MemorySecureStorage(this.value);

  String? value;
  int reads = 0;
  int writes = 0;

  @override
  Future<String?> read({
    required String key,
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) async {
    reads++;
    return value;
  }

  @override
  Future<void> write({
    required String key,
    required String? value,
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) async {
    writes++;
    this.value = value;
  }
}

void main() {
  test('macOS keychain migration preserves old and newer secrets', () async {
    if (!Platform.isMacOS) return;
    final current = _MemorySecureStorage('{"direct-token":"new"}');
    final legacy = _MemorySecureStorage(
      '{"direct-token":"old","sftp_password":"saved"}',
    );
    final backend = FlutterSecureSecretVaultBackend(
      storage: current,
      legacyStorage: legacy,
    );

    final vault = Jet2DropSecretVault(backend: backend);
    expect(await vault.read('sftp_password'), 'saved');
    expect(await vault.read('direct-token'), 'new');
    expect(legacy.reads, 1);
    expect(current.writes, 1);

    final reopened = Jet2DropSecretVault(backend: backend);
    expect(await reopened.read('sftp_password'), 'saved');
    expect(legacy.reads, 1);
  });

  test('all secrets share one cached backend item', () async {
    final backend = _MemoryBackend();
    final vault = Jet2DropSecretVault(backend: backend);

    await Future.wait([
      vault.write('password', 'one'),
      vault.write('direct-token', 'two'),
      vault.write('peer-token', 'three'),
    ]);

    expect(await vault.read('password'), 'one');
    expect(await vault.read('direct-token'), 'two');
    expect(await vault.read('peer-token'), 'three');
    expect(backend.reads, 1);
    expect(backend.value, contains('password'));
    expect(backend.value, contains('peer-token'));
  });

  test('concurrent first reads share one backend access', () async {
    final backend = _MemoryBackend()
      ..value = '{"token":"value"}'
      ..readDelay = const Duration(milliseconds: 10);
    final vault = Jet2DropSecretVault(backend: backend);

    final values = await Future.wait([
      vault.read('token'),
      vault.read('token'),
      vault.read('token'),
    ]);

    expect(values, everyElement('value'));
    expect(backend.reads, 1);
  });

  test(
    'corrupt vault is replaced without exposing another storage key',
    () async {
      final backend = _MemoryBackend()..value = '{broken';
      final vault = Jet2DropSecretVault(backend: backend);

      expect(await vault.read('missing'), isNull);
      await vault.write('password', 'restored');

      expect(backend.reads, 1);
      expect(backend.writes, 1);
      expect(await vault.read('password'), 'restored');
    },
  );
}
