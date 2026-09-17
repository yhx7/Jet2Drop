import 'dart:io';

import 'checksum.dart';
import 'path_utils.dart';

/// Durable wire format used by both direct and relay quick-transfer paths.
/// Payloads are written to a .part file and the manifest is published last.
class QuickTransferManifest {
  const QuickTransferManifest({
    required this.id,
    required this.name,
    required this.size,
    required this.sha256,
    required this.createdAt,
    required this.expiresAt,
    required this.chunkSize,
    this.senderDevice = '',
    this.targetDevice = '',
    this.claimedAt,
    this.claimedBy = '',
  });

  final String id;
  final String name;
  final int size;
  final String sha256;
  final DateTime createdAt;
  final DateTime expiresAt;
  final int chunkSize;
  final String senderDevice;
  final String targetDevice;
  final DateTime? claimedAt;
  final String claimedBy;

  bool get isClaimed => claimedAt != null;

  QuickTransferManifest copyWith({DateTime? claimedAt, String? claimedBy}) =>
      QuickTransferManifest(
        id: id,
        name: name,
        size: size,
        sha256: sha256,
        createdAt: createdAt,
        expiresAt: expiresAt,
        chunkSize: chunkSize,
        senderDevice: senderDevice,
        targetDevice: targetDevice,
        claimedAt: claimedAt ?? this.claimedAt,
        claimedBy: claimedBy ?? this.claimedBy,
      );

  Map<String, Object> toJson() => {
    'version': 1,
    'id': id,
    'name': name,
    'size': size,
    'sha256': sha256,
    'createdAt': createdAt.toUtc().toIso8601String(),
    'expiresAt': expiresAt.toUtc().toIso8601String(),
    'chunkSize': chunkSize,
    'senderDevice': senderDevice,
    'targetDevice': targetDevice,
    if (claimedAt != null) 'claimedAt': claimedAt!.toUtc().toIso8601String(),
    if (claimedBy.isNotEmpty) 'claimedBy': claimedBy,
  };

  static QuickTransferManifest fromJson(Map<String, dynamic> json) =>
      QuickTransferManifest(
        id: json['id'] as String,
        name: sanitizeTransferFileName(json['name'] as String),
        size: (json['size'] as num).toInt(),
        sha256: json['sha256'] as String,
        createdAt: DateTime.parse(json['createdAt'] as String),
        expiresAt: DateTime.parse(json['expiresAt'] as String),
        chunkSize: (json['chunkSize'] as num).toInt(),
        senderDevice: json['senderDevice'] as String? ?? '',
        targetDevice: json['targetDevice'] as String? ?? '',
        claimedAt: json['claimedAt'] == null
            ? null
            : DateTime.parse(json['claimedAt'] as String),
        claimedBy: json['claimedBy'] as String? ?? '',
      );
}

class QuickTransferService {
  QuickTransferService({this.chunkSize = 8 * 1024 * 1024});

  final int chunkSize;

  QuickTransferManifest describe(
    File source, {
    required int size,
    required String checksum,
    String? name,
    Duration ttl = const Duration(hours: 24),
    String senderDevice = '',
    String targetDevice = '',
    String? transferId,
  }) {
    final now = DateTime.now().toUtc();
    return QuickTransferManifest(
      id:
          transferId ??
          '${DateTime.now().microsecondsSinceEpoch}-${_safeName(source)}',
      name: sanitizeTransferFileName(name ?? source.uri.pathSegments.last),
      size: size,
      sha256: checksum,
      createdAt: now,
      expiresAt: now.add(ttl),
      chunkSize: size > 32 * 1024 * 1024 ? chunkSize : size,
      senderDevice: senderDevice,
      targetDevice: targetDevice,
    );
  }

  Future<String> checksum(File source) async {
    final checksum = Sha256Accumulator();
    await for (final chunk in source.openRead()) {
      checksum.add(chunk);
    }
    return checksum.close();
  }

  /// Verifies a downloaded payload in place and atomically publishes it.
  /// This avoids copying a large quick-transfer payload a second time.
  Future<File> verifyAndPublish(
    QuickTransferManifest manifest,
    File payload,
    File target, {
    void Function(int current, int total)? onProgress,
    String? verifiedChecksum,
    int? verifiedSize,
  }) async {
    if (!await payload.exists()) {
      throw StateError('Transfer payload is missing');
    }
    var read = verifiedSize;
    var checksum = verifiedChecksum;
    if (read == null || checksum == null) {
      read = 0;
      final accumulator = Sha256Accumulator();
      await for (final chunk in payload.openRead()) {
        accumulator.add(chunk);
        read = read! + chunk.length;
        onProgress?.call(read, manifest.size);
      }
      checksum = accumulator.close();
    }
    if (read != manifest.size || checksum != manifest.sha256) {
      throw StateError('Transfer checksum verification failed');
    }
    await target.parent.create(recursive: true);
    final backup = File('${target.path}.jet2drop-backup-${uniqueSuffix()}');
    final hadTarget = await target.exists();
    if (hadTarget) await target.rename(backup.path);
    try {
      // The caller stages the payload next to [target], so this stays a
      // same-volume atomic rename. Windows refuses to rename across volumes
      // (OS error 17), which is why the staging directory must not live in the
      // application support directory when the save directory is on another
      // volume.
      await payload.rename(target.path);
    } catch (_) {
      if (hadTarget && await backup.exists()) await backup.rename(target.path);
      rethrow;
    }
    if (hadTarget && await backup.exists()) {
      try {
        await backup.delete();
      } catch (_) {}
    }
    return target;
  }

  String _safeName(File file) =>
      file.uri.pathSegments.last.replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_');
}
