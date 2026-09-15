import 'package:flutter_test/flutter_test.dart';
import 'package:jet2drop/core/models/quick_device.dart';

void main() {
  test(
    'generic desktop direct capability round-trips independently of photo',
    () {
      final device = QuickDevice(
        id: 'mac',
        name: 'Mac',
        updatedAt: DateTime.utc(2026, 9, 3),
        platform: QuickDevicePlatform.macos,
        directEndpoint: 'http://100.64.0.2:37123',
        directToken: 'peer-secret',
        protocol: 'direct',
        protocolVersion: 1,
        canReceiveDirect: true,
      );

      expect(device.supportsDirectReceive, isTrue);
      expect(device.supportsDirectTransfer, isTrue);
      expect(device.supportsPhotoTransfer, isFalse);

      final restored = QuickDevice.fromJson(
        Map<String, dynamic>.from(device.toJson()),
      );
      expect(restored.platform, QuickDevicePlatform.macos);
      expect(restored.protocol, 'direct');
      expect(restored.protocolVersion, 1);
      expect(restored.directEndpoint, device.directEndpoint);
      expect(restored.directToken, device.directToken);
      expect(restored.canReceiveDirect, isTrue);
      expect(restored.supportsDirectTransfer, isTrue);
    },
  );

  test(
    'Android never advertises direct receive even with malformed metadata',
    () {
      final device = QuickDevice.fromJson({
        'id': 'android',
        'name': 'Phone',
        'updatedAt': '2026-09-03T00:00:00Z',
        'platform': 'android',
        'directEndpoint': 'http://100.64.0.3:37123',
        'directToken': 'peer-secret',
        'protocol': 'direct',
        'canReceiveDirect': true,
      });

      expect(device.canReceiveDirect, isFalse);
      expect(device.supportsDirectReceive, isFalse);
      expect(device.supportsDirectTransfer, isFalse);
    },
  );

  test('new parser accepts documented device aliases and old photo JSON', () {
    final device = QuickDevice.fromJson({
      'deviceId': 'windows',
      'deviceName': 'Windows',
      'lastSeenAt': '2026-09-03T00:00:00Z',
      'platform': 'Windows',
      'supportsDirectReceive': true,
      'directEndpoint': 'http://100.64.0.4:37123',
      'directToken': 'token',
      'directProtocolVersion': '1',
    });
    expect(device.id, 'windows');
    expect(device.name, 'Windows');
    expect(device.platform, QuickDevicePlatform.windows);
    expect(device.supportsDirectTransfer, isTrue);

    final old = QuickDevice.fromJson({
      'id': 'old',
      'name': 'Old',
      'updatedAt': '2026-09-03T00:00:00Z',
      'photoEndpoint': 'http://100.64.0.5:1234',
      'photoToken': 'photo-token',
    });
    expect(old.supportsPhotoTransfer, isTrue);
    expect(old.supportsDirectTransfer, isFalse);
  });

  test('metadata JSON never contains either token field', () {
    final metadata = QuickDevice(
      id: 'device',
      name: 'Device',
      updatedAt: DateTime.utc(2026, 9, 3),
      directEndpoint: 'http://100.64.0.6:37123',
      directToken: 'direct-secret',
      photoEndpoint: 'http://100.64.0.6:1234',
      photoToken: 'photo-secret',
      canReceiveDirect: true,
    ).toMetadataJson();

    expect(metadata.containsKey('directToken'), isFalse);
    expect(metadata.containsKey('photoToken'), isFalse);
    expect(metadata['directEndpoint'], 'http://100.64.0.6:37123');
  });
}
