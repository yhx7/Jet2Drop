import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';

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
        name: json['name'] as String,
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

  Future<QuickTransferManifest> publish(
    File source,
    Directory packageDir, {
    Duration ttl = const Duration(hours: 24),
    String senderDevice = '',
    String targetDevice = '',
    void Function(int, int)? onProgress,
  }) async {
    await packageDir.create(recursive: true);
    final id = '${DateTime.now().microsecondsSinceEpoch}-${_safeName(source)}';
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
      name: source.uri.pathSegments.last,
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
    await temp.rename(target.path);
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

/// Minimal receiver used by the direct Tailscale path. Clients upload raw
/// bytes with PUT and publish the manifest only after checksum verification.
class QuickTransferHttpReceiver {
  QuickTransferHttpReceiver({
    required this.packageDir,
    this.ttl = const Duration(hours: 24),
  });

  final Directory packageDir;
  final Duration ttl;
  HttpServer? _server;
  late final String token;

  int get port => _server?.port ?? 0;

  Future<void> start({InternetAddress? address, int port = 0}) async {
    if (_server != null) return;
    token = base64Url.encode(
      List<int>.generate(24, (index) => (index * 73 + 41) & 0xff),
    );
    await packageDir.create(recursive: true);
    _server = await HttpServer.bind(address ?? InternetAddress.anyIPv4, port);
    _server!.listen(_handle);
  }

  Future<void> _handle(HttpRequest request) async {
    final parts = request.uri.pathSegments;
    if (request.method != 'PUT' ||
        parts.length != 3 ||
        parts[0] != 'v1' ||
        parts[1] != token) {
      request.response.statusCode = HttpStatus.notFound;
      await request.response.close();
      return;
    }
    final id = parts[2].replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_');
    final name = request.headers.value('x-file-name') ?? id;
    final temp = File('${packageDir.path}${Platform.pathSeparator}$id.part');
    final output = temp.openWrite();
    final digest = _DigestSink();
    final hashing = sha256.startChunkedConversion(digest);
    var size = 0;
    try {
      await for (final chunk in request) {
        hashing.add(chunk);
        output.add(chunk);
        size += chunk.length;
      }
      await output.flush();
    } finally {
      await output.close();
      hashing.close();
    }
    final now = DateTime.now().toUtc();
    final manifest = QuickTransferManifest(
      id: id,
      name: name,
      size: size,
      sha256: digest.value!.toString(),
      createdAt: now,
      expiresAt: now.add(ttl),
      chunkSize: size > 32 * 1024 * 1024 ? 8 * 1024 * 1024 : size,
    );
    await temp.rename('${packageDir.path}${Platform.pathSeparator}$id.bin');
    await File(
      '${packageDir.path}${Platform.pathSeparator}$id.json',
    ).writeAsString(jsonEncode(manifest.toJson()), flush: true);
    request.response
      ..statusCode = HttpStatus.created
      ..headers.contentType = ContentType.json
      ..write(jsonEncode(manifest.toJson()));
    await request.response.close();
  }

  Future<void> close() async {
    await _server?.close(force: true);
    _server = null;
  }
}
