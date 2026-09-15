import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:jet2drop/core/models/quick_device.dart';
import 'package:jet2drop/infrastructure/quick_device_store.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _FakeSecretStore implements QuickDeviceSecretStore {
  final values = <String, String>{};
  final deleted = <String>[];
  Duration readDelay = Duration.zero;

  @override
  Future<String?> read(String deviceId) async {
    if (readDelay > Duration.zero) await Future<void>.delayed(readDelay);
    return values[deviceId];
  }

  @override
  Future<void> write(String deviceId, String token) async {
    values[deviceId] = token;
  }

  @override
  Future<void> delete(String deviceId) async {
    deleted.add(deviceId);
    values.remove(deviceId);
  }
}

void main() {
  late SharedPreferences preferences;
  late _FakeSecretStore secrets;
  late QuickDeviceStore store;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    preferences = await SharedPreferences.getInstance();
    await preferences.clear();
    secrets = _FakeSecretStore();
    store = QuickDeviceStore(preferences: preferences, secretStore: secrets);
  });

  QuickDevice device({
    String id = 'device',
    String name = 'Device',
    DateTime? updatedAt,
    String? token = 'peer-secret',
    String? endpoint = 'http://100.64.0.2:37123',
    bool canReceiveDirect = true,
  }) => QuickDevice(
    id: id,
    name: name,
    updatedAt: updatedAt ?? DateTime.utc(2026, 9, 3),
    platform: QuickDevicePlatform.macos,
    directEndpoint: endpoint,
    directToken: token,
    protocol: 'direct',
    canReceiveDirect: canReceiveDirect,
  );

  test('upsert stores metadata separately from the peer token', () async {
    await store.upsert(device());

    final raw = preferences.getString(quickDeviceMetadataKey);
    expect(raw, isNotNull);
    expect(raw, contains('directEndpoint'));
    expect(raw, isNot(contains('peer-secret')));
    expect(secrets.values['device'], 'peer-secret');

    final loaded = await store.load();
    expect(loaded, hasLength(1));
    expect(loaded.single.directToken, 'peer-secret');
    expect(loaded.single.supportsDirectTransfer, isTrue);
  });

  test(
    'upsert and merge preserve omitted tokens while updating metadata',
    () async {
      await store.upsert(device());
      await store.upsert(device(name: 'Renamed', token: null));
      var loaded = await store.load();
      expect(loaded.single.name, 'Renamed');
      expect(loaded.single.directToken, 'peer-secret');

      await store.merge([
        device(name: 'Latest', token: null),
        device(id: 'other', name: 'Other', token: 'other-secret'),
        device(name: 'Last duplicate', token: null),
      ]);
      loaded = await store.load();
      expect(loaded.map((item) => item.id), ['device', 'other']);
      expect(loaded.first.name, 'Last duplicate');
      expect(loaded.first.directToken, 'peer-secret');
      expect(loaded.last.directToken, 'other-secret');
    },
  );

  test(
    'legacy token in metadata is migrated and scrubbed immediately',
    () async {
      final legacy = device().toJson();
      await preferences.setString(
        quickDeviceMetadataKey,
        jsonEncode(<Object>[legacy]),
      );

      final loaded = await store.load();
      expect(loaded.single.directToken, 'peer-secret');
      expect(secrets.values['device'], 'peer-secret');
      expect(
        preferences.getString(quickDeviceMetadataKey),
        isNot(contains('peer-secret')),
      );
    },
  );

  test('remove clears both metadata and secure token', () async {
    await store.upsert(device());
    await store.remove('device');

    expect(await store.load(), isEmpty);
    expect(secrets.values, isEmpty);
    expect(secrets.deleted, contains('device'));
  });

  test(
    'concurrent upserts and merges serialize without losing devices',
    () async {
      await store.upsert(device());
      secrets.readDelay = const Duration(milliseconds: 1);
      final operations = <Future<void>>[
        store.upsert(device(id: 'one', token: 'one-secret')),
        store.merge([
          device(id: 'two', token: 'two-secret'),
          device(id: 'three', token: 'three-secret'),
        ]),
        store.upsert(device(id: 'four', token: 'four-secret')),
        store.upsert(device(name: 'last-write')),
      ];

      await Future.wait(operations);
      final loaded = await store.load();
      expect(loaded.map((item) => item.id), [
        'device',
        'one',
        'two',
        'three',
        'four',
      ]);
      expect(
        loaded.singleWhere((item) => item.id == 'device').name,
        'last-write',
      );
      expect(loaded.map((item) => item.directToken), [
        'peer-secret',
        'one-secret',
        'two-secret',
        'three-secret',
        'four-secret',
      ]);
    },
  );

  test('endpoint change revokes the old token instead of reusing it', () async {
    await store.upsert(device());
    await store.upsert(
      device(endpoint: 'http://100.64.0.2:37124', token: null),
    );

    final loaded = await store.load();
    expect(loaded.single.directEndpoint, 'http://100.64.0.2:37124');
    expect(loaded.single.directToken, isNull);
    expect(loaded.single.supportsDirectTransfer, isFalse);
    expect(secrets.values, isEmpty);
    expect(secrets.deleted, contains('device'));
  });

  test(
    'direct capability revocation clears a token on the same endpoint',
    () async {
      await store.upsert(device());
      await store.upsert(device(token: null, canReceiveDirect: false));

      final loaded = await store.load();
      expect(loaded.single.canReceiveDirect, isFalse);
      expect(loaded.single.directToken, isNull);
      expect(secrets.values, isEmpty);
      expect(secrets.deleted, contains('device'));
    },
  );

  test(
    'endpoint rotation keeps only an explicitly supplied replacement token',
    () async {
      await store.upsert(device());
      await store.upsert(
        device(
          endpoint: 'http://100.64.0.2:37124',
          token: 'replacement-secret',
        ),
      );

      final loaded = await store.load();
      expect(loaded.single.directToken, 'replacement-secret');
      expect(secrets.values['device'], 'replacement-secret');
    },
  );

  test(
    'malformed metadata and invalid records do not hide valid devices',
    () async {
      await preferences.setString(quickDeviceMetadataKey, '{not-json');
      expect(await store.load(), isEmpty);

      await preferences.setString(
        quickDeviceMetadataKey,
        jsonEncode(<String, Object>{
          'version': 1,
          'devices': <Object>[
            <String, Object>{'id': 'missing-fields'},
            device(id: 'valid').toMetadataJson(),
          ],
        }),
      );
      final loaded = await store.load();
      expect(loaded.map((item) => item.id), ['valid']);
    },
  );

  test('preferences loader is injectable', () async {
    var calls = 0;
    final injected = QuickDeviceStore(
      preferencesLoader: () async {
        calls++;
        return preferences;
      },
      secretStore: secrets,
    );

    await injected.upsert(device());
    await injected.load();
    expect(calls, 1);
  });
}
