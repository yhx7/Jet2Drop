// ignore_for_file: prefer_initializing_formals

import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../core/models/quick_device.dart';

/// Versioned key for the local, non-sensitive device metadata cache.
const quickDeviceMetadataKey = 'quick_devices_v1';

/// Prefix used for peer tokens in the platform secure storage.
const quickDevicePeerTokenKeyPrefix = 'quick_device_peer_token_v1_';

/// Returns the secure-storage key for one device without putting arbitrary
/// device-id characters into a platform key namespace.
String quickDevicePeerTokenKey(String deviceId) {
  final encoded = base64UrlEncode(Uint8List.fromList(utf8.encode(deviceId)));
  return '$quickDevicePeerTokenKeyPrefix$encoded';
}

/// Injectable secret-store boundary used by [QuickDeviceStore].
///
/// Keeping this interface small makes the store deterministic in unit tests
/// and prevents tests from depending on platform keychain implementations.
abstract interface class QuickDeviceSecretStore {
  Future<String?> read(String deviceId);

  Future<void> write(String deviceId, String token);

  Future<void> delete(String deviceId);
}

/// Production adapter for FlutterSecureStorage.
class FlutterSecureQuickDeviceSecretStore implements QuickDeviceSecretStore {
  FlutterSecureQuickDeviceSecretStore({FlutterSecureStorage? storage})
    : _storage =
          storage ??
          const FlutterSecureStorage(
            mOptions: MacOsOptions(usesDataProtectionKeychain: false),
          );

  final FlutterSecureStorage _storage;

  @override
  Future<String?> read(String deviceId) =>
      _storage.read(key: quickDevicePeerTokenKey(deviceId));

  @override
  Future<void> write(String deviceId, String token) =>
      _storage.write(key: quickDevicePeerTokenKey(deviceId), value: token);

  @override
  Future<void> delete(String deviceId) =>
      _storage.delete(key: quickDevicePeerTokenKey(deviceId));
}

/// Persistent cache for discovered quick-transfer devices.
///
/// Metadata is stored as a versioned JSON envelope in SharedPreferences. The
/// peer token is never written there; it is kept in [QuickDeviceSecretStore].
/// Both dependencies are injectable so callers and tests do not need this
/// class to reach into a repository connection or a global controller.
class QuickDeviceStore {
  // The public `preferences` parameter intentionally maps to a private field;
  // an initializing formal would expose that implementation detail.
  QuickDeviceStore({
    SharedPreferences? preferences,
    Future<SharedPreferences> Function()? preferencesLoader,
    QuickDeviceSecretStore? secretStore,
    FlutterSecureStorage? secureStorage,
    this.metadataKey = quickDeviceMetadataKey,
  }) : _preferences = preferences,
       _preferencesLoader = preferencesLoader ?? SharedPreferences.getInstance,
       _secretStore =
           secretStore ??
           FlutterSecureQuickDeviceSecretStore(storage: secureStorage);

  static const metadataVersion = 1;

  final String metadataKey;
  SharedPreferences? _preferences;
  final Future<SharedPreferences> Function() _preferencesLoader;
  final QuickDeviceSecretStore _secretStore;
  Future<SharedPreferences>? _preferencesFuture;
  Future<void> _operationTail = Future<void>.value();

  Future<SharedPreferences> _getPreferences() async {
    final cached = _preferences;
    if (cached != null) return cached;
    final pending = _preferencesFuture ??= _preferencesLoader();
    try {
      final loaded = await pending;
      _preferences = loaded;
      return loaded;
    } finally {
      if (identical(_preferencesFuture, pending)) _preferencesFuture = null;
    }
  }

  /// Loads all valid cached devices and hydrates their peer tokens.
  Future<List<QuickDevice>> load() async {
    await _operationTail;
    return _loadInternal();
  }

  Future<List<QuickDevice>> _loadInternal() async {
    final preferences = await _getPreferences();
    final raw = preferences.getString(metadataKey);
    if (raw == null || raw.trim().isEmpty) return <QuickDevice>[];

    final records = _decodeRecords(raw);
    if (records == null) return <QuickDevice>[];

    final devices = <QuickDevice>[];
    final positions = <String, int>{};
    for (final record in records) {
      try {
        // Parsing the full form also permits one-time migration from a
        // pre-store list that accidentally contained photoToken/directToken.
        final device = QuickDevice.fromJson(record);
        if (device.id.trim().isEmpty) continue;
        final position = positions[device.id];
        if (position == null) {
          positions[device.id] = devices.length;
          devices.add(device);
        } else {
          devices[position] = device;
        }
      } on Object {
        // One corrupt device must not hide otherwise valid recipients.
      }
    }

    final hydrated = <QuickDevice>[];
    var hadLegacyToken = false;
    for (final device in devices) {
      hadLegacyToken = hadLegacyToken || _hasText(_peerToken(device));
      hydrated.add(await _hydrateToken(device));
    }
    if (hadLegacyToken) {
      // Remove tokens from a legacy SharedPreferences payload immediately,
      // rather than waiting for a later upsert/merge to rewrite the key.
      await _persist(hydrated);
    }
    return hydrated;
  }

  /// Inserts or updates one device by stable id.
  ///
  /// An omitted token is retained only while the endpoint and advertised
  /// capabilities are unchanged. An endpoint change or capability revocation
  /// invalidates the old credential instead of applying it to a new service.
  Future<void> upsert(QuickDevice device) => _enqueue(() async {
    if (device.id.trim().isEmpty) return;
    final devices = await _loadInternal();
    final index = devices.indexWhere((item) => item.id == device.id);
    final previous = index < 0 ? null : devices[index];
    final resetToken = previous != null && _shouldResetToken(previous, device);
    final merged = previous == null ? device : _mergeTokens(previous, device);
    if (index < 0) {
      devices.add(merged);
    } else {
      devices[index] = merged;
    }
    await _persist(devices);
    if (resetToken && !_hasText(_peerToken(merged))) {
      await _secretStore.delete(device.id);
    }
  });

  /// Merges a discovered batch into the cache, retaining devices not present
  /// in the batch and deduplicating records by stable id.
  Future<void> merge(Iterable<QuickDevice> incoming) => _enqueue(() async {
    final devices = await _loadInternal();
    final resetTokens = <String>{};
    final positions = <String, int>{
      for (var index = 0; index < devices.length; index++)
        devices[index].id: index,
    };

    for (final device in incoming) {
      if (device.id.trim().isEmpty) continue;
      final index = positions[device.id];
      final previous = index == null ? null : devices[index];
      if (previous != null && _shouldResetToken(previous, device)) {
        resetTokens.add(device.id);
      }
      final merged = previous == null ? device : _mergeTokens(previous, device);
      if (_hasText(_peerToken(merged))) resetTokens.remove(device.id);
      if (index == null) {
        positions[device.id] = devices.length;
        devices.add(merged);
      } else {
        devices[index] = merged;
      }
    }
    await _persist(devices);
    for (final deviceId in resetTokens) {
      await _secretStore.delete(deviceId);
    }
  });

  /// Removes a device and its peer token. The operation is idempotent.
  Future<void> remove(String deviceId) => _enqueue(() async {
    final devices = await _loadInternal();
    devices.removeWhere((device) => device.id == deviceId);
    await _persist(devices);
    await _secretStore.delete(deviceId);
  });

  Future<void> _enqueue(Future<void> Function() action) {
    final next = _operationTail.then((_) => action());
    _operationTail = next.then<void>(
      (_) {},
      onError: (Object error, StackTrace stackTrace) {},
    );
    return next;
  }

  Future<QuickDevice> _hydrateToken(QuickDevice device) async {
    var token = await _secretStore.read(device.id);
    final legacyToken = _peerToken(device);
    if (!_hasText(token) && _hasText(legacyToken)) {
      token = legacyToken;
      // Migrate a legacy JSON token before returning it. The next persist
      // writes metadata through toMetadataJson(), so it cannot leak back.
      await _secretStore.write(device.id, token!);
    }
    if (!_hasText(token)) return device;
    final directToken = device.directEndpoint == null
        ? device.directToken
        : device.directToken ?? token;
    final photoToken = device.photoEndpoint == null
        ? device.photoToken
        : device.photoToken ?? token;
    if (!_hasText(directToken) && !_hasText(photoToken)) return device;
    return _withTokens(
      device,
      directToken: directToken,
      photoToken: photoToken,
    );
  }

  Future<void> _persist(Iterable<QuickDevice> devices) async {
    final preferences = await _getPreferences();
    final records = devices
        .where((device) => device.id.trim().isNotEmpty)
        .map((device) => device.toMetadataJson())
        .toList(growable: false);
    final envelope = <String, Object>{
      'version': metadataVersion,
      'devices': records,
    };
    await preferences.setString(metadataKey, jsonEncode(envelope));

    for (final device in devices) {
      final token = _peerToken(device);
      if (_hasText(token)) {
        await _secretStore.write(device.id, token!);
      }
    }
  }

  static List<Map<String, dynamic>>? _decodeRecords(String raw) {
    try {
      final decoded = jsonDecode(raw);
      final value = decoded is List
          ? decoded
          : decoded is Map
          ? decoded['devices']
          : null;
      if (value is! List) return null;
      return value
          .whereType<Map>()
          .map((record) => Map<String, dynamic>.from(record))
          .toList(growable: false);
    } on FormatException {
      return null;
    } on Object {
      return null;
    }
  }

  static QuickDevice _mergeTokens(QuickDevice previous, QuickDevice incoming) {
    final resetToken = _shouldResetToken(previous, incoming);
    return _withTokens(
      incoming,
      directToken: _hasText(incoming.directToken)
          ? incoming.directToken
          : resetToken
          ? null
          : previous.directToken,
      photoToken: _hasText(incoming.photoToken)
          ? incoming.photoToken
          : resetToken
          ? null
          : previous.photoToken,
    );
  }

  static bool _shouldResetToken(QuickDevice previous, QuickDevice incoming) {
    final endpointChanged =
        previous.directEndpoint != incoming.directEndpoint ||
        previous.photoEndpoint != incoming.photoEndpoint;
    final directRevoked =
        previous.supportsDirectReceive && !incoming.supportsDirectReceive;
    final photoRevoked =
        previous.supportsPhotoTransfer && !incoming.supportsPhotoTransfer;
    return endpointChanged || directRevoked || photoRevoked;
  }

  static QuickDevice _withTokens(
    QuickDevice device, {
    String? directToken,
    String? photoToken,
  }) => QuickDevice(
    id: device.id,
    name: device.name,
    updatedAt: device.updatedAt,
    photoEndpoint: device.photoEndpoint,
    photoToken: photoToken,
    platform: device.platform,
    directEndpoint: device.directEndpoint,
    directToken: directToken,
    protocol: device.protocol,
    protocolVersion: device.protocolVersion,
    canReceiveDirect: device.canReceiveDirect,
    canReceiveRelay: device.canReceiveRelay,
  );

  static String? _peerToken(QuickDevice device) {
    if (_hasText(device.directToken)) return device.directToken;
    if (_hasText(device.photoToken)) return device.photoToken;
    return null;
  }

  static bool _hasText(String? value) =>
      value != null && value.trim().isNotEmpty;
}
