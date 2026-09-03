import 'package:flutter_test/flutter_test.dart';
import 'package:jet2drop/core/models/quick_device.dart';

void main() {
  test(
    'device registration keeps photo capability optional for old clients',
    () {
      final old = QuickDevice.fromJson({
        'id': 'old-device',
        'name': 'Old',
        'updatedAt': '2026-09-03T00:00:00Z',
      });
      expect(old.photoEndpoint, isNull);
      expect(old.photoToken, isNull);
      expect(old.supportsPhotoTransfer, isFalse);

      final current = QuickDevice(
        id: 'current-device',
        name: 'Current',
        updatedAt: DateTime.utc(2026, 9, 3),
        photoEndpoint: 'http://100.64.0.2:1234',
        photoToken: 'high-entropy-token',
      );
      final restored = QuickDevice.fromJson(
        Map<String, dynamic>.from(current.toJson()),
      );
      expect(restored.photoEndpoint, current.photoEndpoint);
      expect(restored.photoToken, current.photoToken);
      expect(restored.supportsPhotoTransfer, isTrue);
    },
  );

  test('empty capability fields never advertise direct photo transfer', () {
    final device = QuickDevice(
      id: 'device',
      name: 'Device',
      updatedAt: DateTime.now(),
      photoEndpoint: '',
      photoToken: '',
    );
    expect(device.supportsPhotoTransfer, isFalse);
  });
}
