/// Operating systems that can advertise a quick-transfer endpoint.
enum QuickDevicePlatform { unknown, windows, macos, android, ios, linux }

extension QuickDevicePlatformJson on QuickDevicePlatform {
  String get wireName => name;

  static QuickDevicePlatform fromJson(Object? value) {
    if (value is! String) return QuickDevicePlatform.unknown;
    final normalized = value
        .trim()
        .toLowerCase()
        .replaceAll('-', '')
        .replaceAll('_', '');
    switch (normalized) {
      case 'windows':
        return QuickDevicePlatform.windows;
      case 'macos':
      case 'osx':
        return QuickDevicePlatform.macos;
      case 'android':
        return QuickDevicePlatform.android;
      case 'ios':
      case 'iphoneos':
        return QuickDevicePlatform.ios;
      case 'linux':
        return QuickDevicePlatform.linux;
      default:
        return QuickDevicePlatform.unknown;
    }
  }
}

/// Well-known direct protocol identifiers.
///
/// The [QuickDevice.protocol] field remains a string so a newer desktop
/// service can advertise a protocol without requiring an older client to
/// understand a new enum value first.
abstract final class QuickDeviceProtocol {
  static const direct = 'direct';
  static const directV1 = 'direct-v1';
}

/// A discovered quick-transfer recipient.
///
/// `photoEndpoint` and `photoToken` are retained for the first-generation
/// photo-only registration JSON. New direct transfers use
/// `directEndpoint`/`directToken` and the generic capability fields below.
class QuickDevice {
  const QuickDevice({
    required this.id,
    required this.name,
    required this.updatedAt,
    this.photoEndpoint,
    this.photoToken,
    this.platform = QuickDevicePlatform.unknown,
    this.directEndpoint,
    this.directToken,
    this.protocol,
    this.protocolVersion = 1,
    bool canReceiveDirect = false,
    bool? supportsDirectReceive,
    this.canReceiveRelay = true,
  }) : canReceiveDirect = platform == QuickDevicePlatform.android
           ? false
           : supportsDirectReceive ?? canReceiveDirect;

  static const schemaVersion = 2;

  final String id;
  final String name;
  final DateTime updatedAt;

  /// Legacy photo-only direct endpoint and token.
  final String? photoEndpoint;
  final String? photoToken;

  final QuickDevicePlatform platform;
  final String? directEndpoint;
  final String? directToken;
  final String? protocol;
  final int protocolVersion;
  final bool canReceiveDirect;
  final bool canReceiveRelay;

  String get deviceId => id;

  String get deviceName => name;

  DateTime get lastSeenAt => updatedAt;

  String? get directProtocol => protocol;

  int get directProtocolVersion => protocolVersion;

  /// Alias matching the field returned by the legacy direct health endpoint.
  bool get supportsDirectReceive =>
      platform != QuickDevicePlatform.android && canReceiveDirect;

  /// Whether this record has enough authenticated, generic direct metadata to
  /// start a transfer. An endpoint alone never advertises capability.
  bool get supportsDirectTransfer =>
      supportsDirectReceive &&
      _hasText(directEndpoint) &&
      _hasText(directToken) &&
      protocolVersion > 0;

  bool get supportsRelayTransfer => canReceiveRelay;

  /// The old photo path remains intentionally independent of generic direct
  /// transfer capability. This prevents legacy JSON from accidentally making
  /// an Android or photo-only recipient eligible for arbitrary files.
  bool get supportsPhotoTransfer =>
      _hasText(photoEndpoint) && _hasText(photoToken);

  /// Full wire representation. The local store uses [toMetadataJson] so
  /// tokens never enter SharedPreferences.
  Map<String, Object> toJson() {
    final result = <String, Object>{
      'schemaVersion': schemaVersion,
      'id': id,
      'name': name,
      'updatedAt': updatedAt.toUtc().toIso8601String(),
      'platform': platform.wireName,
      'canReceiveDirect': canReceiveDirect,
      'supportsDirectReceive': canReceiveDirect,
      'canReceiveRelay': canReceiveRelay,
      'protocolVersion': protocolVersion,
      'directProtocolVersion': protocolVersion,
    };
    if (_hasText(protocol)) result['protocol'] = protocol!;
    if (directEndpoint != null) result['directEndpoint'] = directEndpoint!;
    if (directToken != null) result['directToken'] = directToken!;
    if (photoEndpoint != null) result['photoEndpoint'] = photoEndpoint!;
    if (photoToken != null) result['photoToken'] = photoToken!;
    return result;
  }

  /// Metadata representation for the local device cache. Sensitive peer
  /// tokens are deliberately omitted and are stored by [QuickDeviceStore].
  Map<String, Object> toMetadataJson() {
    final result = toJson();
    result.remove('directToken');
    result.remove('photoToken');
    return result;
  }

  static QuickDevice fromJson(Map<String, dynamic> json) {
    final platform = QuickDevicePlatformJson.fromJson(json['platform']);
    final directCapability =
        _boolValue(json['canReceiveDirect']) ??
        _boolValue(json['supportsDirectReceive']);
    final relayCapability = _boolValue(json['canReceiveRelay']);
    final protocolVersion =
        _intValue(json['protocolVersion']) ??
        _intValue(json['directProtocolVersion']) ??
        1;
    final updatedAt = _dateValue(json['updatedAt'] ?? json['lastSeenAt']);

    return QuickDevice(
      id: _requiredString(json, 'id', fallbackKey: 'deviceId'),
      name: _requiredString(json, 'name', fallbackKey: 'deviceName'),
      updatedAt: updatedAt,
      platform: platform,
      directEndpoint: _stringValue(json['directEndpoint']),
      directToken: _stringValue(json['directToken']),
      protocol: _stringValue(json['protocol']),
      protocolVersion: protocolVersion,
      canReceiveDirect: directCapability ?? false,
      canReceiveRelay: relayCapability ?? true,
      photoEndpoint: _stringValue(json['photoEndpoint']),
      photoToken: _stringValue(json['photoToken']),
    );
  }

  /// Alias useful when callers have already read a metadata-only record.
  static QuickDevice fromMetadataJson(Map<String, dynamic> json) =>
      fromJson(json);

  static bool _hasText(String? value) =>
      value != null && value.trim().isNotEmpty;

  static String? _stringValue(Object? value) => value is String ? value : null;

  static String _requiredString(
    Map<String, dynamic> json,
    String key, {
    required String fallbackKey,
  }) {
    final value = json[key] ?? json[fallbackKey];
    if (value is! String || value.trim().isEmpty) {
      throw FormatException('Quick device is missing $key.');
    }
    return value;
  }

  static DateTime _dateValue(Object? value) {
    if (value is String) return DateTime.parse(value).toLocal();
    if (value is num) {
      return DateTime.fromMillisecondsSinceEpoch(
        value.toInt(),
        isUtc: true,
      ).toLocal();
    }
    throw const FormatException('Quick device is missing updatedAt.');
  }

  static bool? _boolValue(Object? value) => value is bool ? value : null;

  static int? _intValue(Object? value) {
    if (value is int) return value;
    if (value is num && value.isFinite && value == value.round()) {
      return value.toInt();
    }
    if (value is String) return int.tryParse(value.trim());
    return null;
  }
}
