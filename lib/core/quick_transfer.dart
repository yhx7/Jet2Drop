import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';

import 'path_utils.dart';

class _DigestSink implements Sink<Digest> {
  Digest? value;

  @override
  void add(Digest event) => value = event;

  @override
  void close() {}
}

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
      name: sanitizeTransferFileName(source.uri.pathSegments.last),
      size: size,
      sha256: checksum,
      createdAt: now,
      expiresAt: now.add(ttl),
      chunkSize: size > 32 * 1024 * 1024 ? chunkSize : size,
      senderDevice: senderDevice,
      targetDevice: targetDevice,
    );
  }

  Future<QuickTransferManifest> inspect(
    File source, {
    Duration ttl = const Duration(hours: 24),
    String senderDevice = '',
    String targetDevice = '',
    String? transferId,
    void Function(int, int)? onProgress,
  }) async {
    final total = await source.length();
    var read = 0;
    final digest = _DigestSink();
    final hashing = sha256.startChunkedConversion(digest);
    await for (final chunk in source.openRead()) {
      hashing.add(chunk);
      read += chunk.length;
      onProgress?.call(read, total);
    }
    hashing.close();
    return describe(
      source,
      size: total,
      checksum: digest.value!.toString(),
      ttl: ttl,
      senderDevice: senderDevice,
      targetDevice: targetDevice,
      transferId: transferId,
    );
  }

  Future<QuickTransferManifest> publish(
    File source,
    Directory packageDir, {
    Duration ttl = const Duration(hours: 24),
    String senderDevice = '',
    String targetDevice = '',
    String? transferId,
    void Function(int, int)? onProgress,
  }) async {
    await packageDir.create(recursive: true);
    final id =
        transferId ??
        '${DateTime.now().microsecondsSinceEpoch}-${_safeName(source)}';
    final payload = File('${packageDir.path}${Platform.pathSeparator}$id.part');
    final total = await source.length();
    var copied = 0;
    final digest = _DigestSink();
    final hashing = sha256.startChunkedConversion(digest);
    final output = payload.openWrite();
    try {
      await for (final chunk in source.openRead()) {
        hashing.add(chunk);
        output.add(chunk);
        copied += chunk.length;
        onProgress?.call(copied, total);
      }
      await output.flush();
    } finally {
      await output.close();
      hashing.close();
    }
    final checksum = digest.value!.toString();
    final now = DateTime.now().toUtc();
    final manifest = QuickTransferManifest(
      id: id,
      name: sanitizeTransferFileName(source.uri.pathSegments.last),
      size: total,
      sha256: checksum,
      createdAt: now,
      expiresAt: now.add(ttl),
      chunkSize: total > 32 * 1024 * 1024 ? chunkSize : total,
      senderDevice: senderDevice,
      targetDevice: targetDevice,
    );
    final finalPayload = File(
      '${packageDir.path}${Platform.pathSeparator}$id.bin',
    );
    await payload.rename(finalPayload.path);
    await File(
      '${packageDir.path}${Platform.pathSeparator}$id.json',
    ).writeAsString(jsonEncode(manifest.toJson()), flush: true);
    return manifest;
  }

  Future<File> receive(
    QuickTransferManifest manifest,
    Directory packageDir,
    File target, {
    void Function(int, int)? onProgress,
  }) async {
    if (manifest.expiresAt.isBefore(DateTime.now().toUtc())) {
      throw StateError('Transfer has expired');
    }
    final source = File(
      '${packageDir.path}${Platform.pathSeparator}${manifest.id}.bin',
    );
    if (!await source.exists()) throw StateError('Transfer payload is missing');
    final temp = File('${target.path}.jet2drop-${manifest.id}.part');
    await temp.parent.create(recursive: true);
    var copied = 0;
    final digest = _DigestSink();
    final hashing = sha256.startChunkedConversion(digest);
    final output = temp.openWrite();
    try {
      await for (final chunk in source.openRead()) {
        hashing.add(chunk);
        output.add(chunk);
        copied += chunk.length;
        onProgress?.call(copied, manifest.size);
      }
      await output.flush();
    } finally {
      await output.close();
      hashing.close();
    }
    if (copied != manifest.size ||
        digest.value!.toString() != manifest.sha256) {
      try {
        await temp.delete();
      } catch (_) {}
      throw StateError('Transfer checksum verification failed');
    }
    final backup = File(
      '${target.path}.jet2drop-backup-${DateTime.now().microsecondsSinceEpoch}',
    );
    final hadTarget = await target.exists();
    if (hadTarget) await target.rename(backup.path);
    try {
      await temp.rename(target.path);
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

  /// Verifies a downloaded payload in place and atomically publishes it.
  /// This avoids copying a large quick-transfer payload a second time.
  Future<File> verifyAndPublish(
    QuickTransferManifest manifest,
    File payload,
    File target, {
    void Function(int current, int total)? onProgress,
  }) async {
    if (!await payload.exists()) {
      throw StateError('Transfer payload is missing');
    }
    var read = 0;
    final digest = _DigestSink();
    final hashing = sha256.startChunkedConversion(digest);
    await for (final chunk in payload.openRead()) {
      hashing.add(chunk);
      read += chunk.length;
      onProgress?.call(read, manifest.size);
    }
    hashing.close();
    if (read != manifest.size || digest.value!.toString() != manifest.sha256) {
      throw StateError('Transfer checksum verification failed');
    }
    await target.parent.create(recursive: true);
    final backup = File('${target.path}.jet2drop-backup-${uniqueSuffix()}');
    final hadTarget = await target.exists();
    if (hadTarget) await target.rename(backup.path);
    try {
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

  Future<List<QuickTransferManifest>> list(Directory packageDir) async {
    if (!await packageDir.exists()) return const [];
    final result = <QuickTransferManifest>[];
    await for (final entity in packageDir.list()) {
      if (entity is! File || !entity.path.endsWith('.json')) continue;
      try {
        final manifest = QuickTransferManifest.fromJson(
          jsonDecode(await entity.readAsString()) as Map<String, dynamic>,
        );
        if (manifest.expiresAt.isAfter(DateTime.now().toUtc())) {
          result.add(manifest);
        }
      } catch (_) {
        // Ignore incomplete or invalid manifests; cleanup handles them later.
      }
    }
    return result;
  }

  Future<void> cleanup(Directory packageDir) async {
    if (!await packageDir.exists()) return;
    final valid = {for (final item in await list(packageDir)) item.id};
    await for (final entity in packageDir.list()) {
      if (entity is! File) continue;
      final name = entity.uri.pathSegments.last;
      final id = name.replaceFirst(RegExp(r'\.(json|bin|part)$'), '');
      if ((name.endsWith('.json') ||
              name.endsWith('.bin') ||
              name.endsWith('.part')) &&
          !valid.contains(id)) {
        try {
          await entity.delete();
        } catch (_) {}
      }
    }
  }

  String _safeName(File file) =>
      file.uri.pathSegments.last.replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_');
}
