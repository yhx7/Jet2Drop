import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';

import 'checksum.dart';
import 'path_utils.dart';
import 'repository_gateway.dart';
import 'transfer_control.dart';

/// The direct photo path is deliberately a small HTTP protocol.  It is not a
/// second repository implementation: the receiver only accepts one complete
/// request and publishes one file after its hash has been checked.
const photoTransferPath = '/v1/photo';
const photoTransferMaxBytes = 10 * 1024 * 1024 * 1024;

const _photoMimeByExtension = <String, String>{
  'jpg': 'image/jpeg',
  'jpeg': 'image/jpeg',
  'png': 'image/png',
  'webp': 'image/webp',
  'gif': 'image/gif',
  'bmp': 'image/bmp',
  'heic': 'image/heic',
  'heif': 'image/heif',
  'avif': 'image/avif',
};

String? photoMimeTypeForName(String name) =>
    _photoMimeByExtension[_photoExtension(name)];

bool isSupportedPhotoTransfer({
  required String name,
  required String? mimeType,
}) {
  final expected = photoMimeTypeForName(name);
  if (expected == null || mimeType == null) return false;
  final actual = mimeType.split(';').first.trim().toLowerCase();
  if (actual == expected) return true;
  return (_photoExtension(name) == 'heic' && actual == 'image/heif') ||
      (_photoExtension(name) == 'heif' && actual == 'image/heic');
}

String _photoExtension(String name) {
  final dot = name.lastIndexOf('.');
  return dot < 0 ? '' : name.substring(dot + 1).toLowerCase();
}

class PhotoTransferReceipt {
  const PhotoTransferReceipt({
    required this.name,
    required this.size,
    required this.sha256,
  });

  final String name;
  final int size;
  final String sha256;
}

class PhotoTransferException implements Exception {
  const PhotoTransferException(this.message, {this.statusCode});

  final String message;
  final int? statusCode;

  @override
  String toString() => message;
}

/// A desktop receiver bound only to an address selected from Tailscale's
/// CGNAT range.  [saveDirectoryProvider] is evaluated when each request
/// starts, so a directory change affects new photos only.
class PhotoTransferServer {
  PhotoTransferServer({
    required this.token,
    required this.saveDirectoryProvider,
    this.port = 0,
    this.bindAddress,
    this.endpointHost,
  });

  final String token;
  final Future<String?> Function() saveDirectoryProvider;
  final int port;
  final InternetAddress? bindAddress;
  final String? endpointHost;

  HttpServer? _server;
  String? _endpoint;
  Future<void> _reservationTail = Future<void>.value();
  final Set<String> _reservedPaths = <String>{};

  String? get endpoint => _endpoint;
  bool get isRunning => _server != null;

  /// Starts on an explicitly supplied address, or discovers a Tailscale IPv4
  /// address.  False means this machine has no usable Tailscale address yet;
  /// it is not a reason to stop the rest of the application from starting.
  Future<bool> start() async {
    if (token.trim().isEmpty) {
      throw ArgumentError.value(
        token,
        'token',
        'Photo transfer token is required.',
      );
    }
    if (_server != null) return true;
    final address = bindAddress ?? await findTailscaleIpv4Address();
    if (address == null) return false;
    final server = await HttpServer.bind(address, port, shared: false);
    _server = server;
    final host = endpointHost ?? address.address;
    _endpoint = Uri(scheme: 'http', host: host, port: server.port).toString();
    unawaited(server.forEach(_handle));
    return true;
  }

  Future<void> stop() async {
    final server = _server;
    _server = null;
    _endpoint = null;
    if (server != null) await server.close(force: true);
  }

  Future<void> _handle(HttpRequest request) async {
    if (request.method != 'POST' || request.uri.path != photoTransferPath) {
      await _respond(request.response, HttpStatus.notFound, '照片接口不存在。');
      return;
    }
    if (request.headers.value('x-jet2drop-token') != token) {
      await _respond(request.response, HttpStatus.unauthorized, '照片令牌无效。');
      return;
    }
    final rawName = request.uri.queryParameters['name'];
    if (rawName == null || rawName.trim().isEmpty) {
      await _respond(request.response, HttpStatus.badRequest, '照片文件名缺失。');
      return;
    }
    final name = sanitizeTransferFileName(rawName);
    final size = request.contentLength;
    if (size <= 0 || size > photoTransferMaxBytes) {
      await _respond(request.response, HttpStatus.badRequest, '照片大小无效。');
      return;
    }

    if (!isSupportedPhotoTransfer(
      name: name,
      mimeType: request.headers.contentType?.mimeType,
    )) {
      await _respond(request.response, HttpStatus.badRequest, '照片类型不受支持。');
      return;
    }

    // Reserve a target name before consuming the stream.  The reservation is
    // held until the final rename so simultaneous requests cannot overwrite
    // one another, including on case-insensitive file systems.
    File? partial;
    File? target;
    try {
      final directoryPath = await saveDirectoryProvider();
      if (directoryPath == null || directoryPath.trim().isEmpty) {
        throw const PhotoTransferException('请先设置快传接收默认保存目录。');
      }
      final directory = Directory(directoryPath.trim());
      final stat = await directory.stat();
      if (stat.type != FileSystemEntityType.directory) {
        throw const PhotoTransferException('快传接收默认保存位置不是文件夹。');
      }
      final reserved = await _reserveTarget(directory, name);
      target = reserved;
      partial = File('${target.path}.jet2drop-photo-${uniqueSuffix()}.part');
      final sink = partial.openWrite();
      var received = 0;
      final digestSink = _DigestSink();
      final hashing = sha256.startChunkedConversion(digestSink);
      try {
        await for (final chunk in request) {
          received += chunk.length;
          if (received > size) {
            throw const PhotoTransferException('照片数据超过声明大小。');
          }
          hashing.add(chunk);
          sink.add(chunk);
        }
        await sink.flush();
      } finally {
        await sink.close();
        hashing.close();
      }
      if (received != size) {
        throw const PhotoTransferException('照片传输未完整结束。');
      }
      final checksum = digestSink.value?.toString();
      if (checksum == null) {
        throw const PhotoTransferException('照片校验失败。');
      }
      await partial.rename(target.path);
      partial = null;
      await _respond(
        request.response,
        HttpStatus.ok,
        jsonEncode({
          'name': target.uri.pathSegments.last,
          'size': size,
          'sha256': checksum,
        }),
      );
    } on PhotoTransferException catch (exception) {
      await _deletePartial(partial);
      await _respond(
        request.response,
        exception.statusCode ?? HttpStatus.conflict,
        exception.message,
      );
    } on FileSystemException {
      await _deletePartial(partial);
      await _respond(
        request.response,
        HttpStatus.conflict,
        '快传接收默认保存目录无效或不可写。',
      );
    } catch (exception) {
      await _deletePartial(partial);
      await _respond(
        request.response,
        HttpStatus.internalServerError,
        '照片保存失败。',
      );
    } finally {
      if (target != null) _reservedPaths.remove(_reservationKey(target.path));
    }
  }

  Future<File> _reserveTarget(Directory directory, String name) {
    final run = _reservationTail.then((_) async {
      final names = <String>{};
      await for (final entity in directory.list(followLinks: false)) {
        names.add(entity.uri.pathSegments.last.toLowerCase());
      }
      final dot = name.lastIndexOf('.');
      final stem = dot > 0 ? name.substring(0, dot) : name;
      final extension = dot > 0 ? name.substring(dot) : '';
      for (var index = 1; ; index++) {
        final candidateName = index == 1 ? name : '$stem ($index)$extension';
        final candidate = File(
          '${directory.path}${Platform.pathSeparator}$candidateName',
        );
        final key = _reservationKey(candidate.path);
        if (!names.contains(candidateName.toLowerCase()) &&
            !_reservedPaths.contains(key)) {
          _reservedPaths.add(key);
          return candidate;
        }
      }
    });
    _reservationTail = run.then<void>((_) {}, onError: (_, _) {});
    return run;
  }

  String _reservationKey(String path) => path.toLowerCase();

  Future<void> _deletePartial(File? partial) async {
    if (partial == null) return;
    try {
      if (await partial.exists()) await partial.delete();
    } on FileSystemException {
      // The peer can close the socket while the OS removes the incomplete
      // file.  A missing partial is already the desired cleanup result.
    }
  }

  Future<void> _respond(
    HttpResponse response,
    int status,
    String message,
  ) async {
    response.statusCode = status;
    response.headers.contentType = ContentType.json;
    response.write(
      jsonEncode(
        status == HttpStatus.ok
            ? jsonDecode(message)
            : <String, Object>{'error': message},
      ),
    );
    await response.close();
  }

  static Future<InternetAddress?> findTailscaleIpv4Address() async {
    final interfaces = await NetworkInterface.list(
      includeLoopback: false,
      type: InternetAddressType.IPv4,
    );
    for (final interface in interfaces) {
      for (final address in interface.addresses) {
        final bytes = address.rawAddress;
        if (bytes.length == 4 &&
            bytes[0] == 100 &&
            bytes[1] >= 64 &&
            bytes[1] <= 127) {
          return address;
        }
      }
    }
    return null;
  }
}

class PhotoTransferClient {
  PhotoTransferClient({
    this.connectionTimeout = const Duration(seconds: 12),
    this.requestTimeout = const Duration(minutes: 30),
  }) : _httpClient = HttpClient() {
    _httpClient
      ..connectionTimeout = connectionTimeout
      ..autoUncompress = false
      ..idleTimeout = const Duration(minutes: 2);
  }

  final Duration connectionTimeout;
  final Duration requestTimeout;
  final HttpClient _httpClient;

  Future<PhotoTransferReceipt> send({
    required String endpoint,
    required String token,
    required File source,
    String? fileName,
    String? mimeType,
    ProgressCallback? onProgress,
    TransferControl? control,
  }) async {
    final name = sanitizeTransferFileName(
      fileName ?? source.uri.pathSegments.last,
    );
    final size = await source.length();
    if (size > photoTransferMaxBytes) {
      throw const PhotoTransferException('照片大小超过限制。');
    }
    final parsed = Uri.tryParse(endpoint);
    if (parsed == null || parsed.host.isEmpty || parsed.port <= 0) {
      throw const PhotoTransferException('目标设备的照片直传地址无效。');
    }
    final uri = parsed.replace(
      path: photoTransferPath,
      queryParameters: {'name': name},
    );
    final request = await _httpClient.postUrl(uri).timeout(connectionTimeout);
    request.headers
      ..set('X-Jet2Drop-Token', token)
      ..contentLength = size
      ..set('Content-Type', mimeType ?? 'application/octet-stream');
    final checksum = Sha256Accumulator();
    var transferred = 0;
    control?.bind(
      onCancel: () async {
        request.abort();
      },
    );
    try {
      await request
          .addStream(
            source.openRead().asyncMap((chunk) async {
              await control?.checkpoint();
              checksum.add(chunk);
              transferred += chunk.length;
              onProgress?.call(transferred, size);
              return chunk;
            }),
          )
          .timeout(requestTimeout);
      final response = await request.close().timeout(requestTimeout);
      final body = await response.transform(utf8.decoder).join();
      Map<String, dynamic> decoded;
      try {
        decoded = jsonDecode(body) as Map<String, dynamic>;
      } catch (_) {
        throw const PhotoTransferException('照片接收端返回了无效结果。');
      }
      if (response.statusCode != HttpStatus.ok) {
        throw PhotoTransferException(
          decoded['error'] as String? ?? '照片接收失败。',
          statusCode: response.statusCode,
        );
      }
      final serverChecksum = decoded['sha256'] as String?;
      final expectedChecksum = checksum.close();
      final finalSize = (decoded['size'] as num?)?.toInt();
      final finalName = decoded['name'] as String?;
      if (serverChecksum == null ||
          finalName == null ||
          finalSize != size ||
          serverChecksum != expectedChecksum) {
        throw const PhotoTransferException('照片校验失败，未保存。');
      }
      onProgress?.call(size, size);
      return PhotoTransferReceipt(
        name: sanitizeTransferFileName(finalName),
        size: finalSize!,
        sha256: serverChecksum,
      );
    } on PhotoTransferException {
      rethrow;
    } on TransferCancelled {
      request.abort();
      rethrow;
    } on TimeoutException {
      request.abort();
      if (control?.isCancelled == true) throw const TransferCancelled();
      throw const PhotoTransferException('照片直传超时，请重新发送。');
    } on SocketException {
      request.abort();
      if (control?.isCancelled == true) throw const TransferCancelled();
      throw const PhotoTransferException('照片直传连接失败，请确认接收端在线后重新发送。');
    } on HttpException {
      request.abort();
      if (control?.isCancelled == true) throw const TransferCancelled();
      throw const PhotoTransferException('照片直传连接失败，请确认接收端在线后重新发送。');
    } finally {
      // Keep-alive is intentional.  The client is disposed with the app.
    }
  }

  Future<void> dispose() async => _httpClient.close(force: true);
}

class _DigestSink implements Sink<Digest> {
  Digest? value;

  @override
  void add(Digest event) => value = event;

  @override
  void close() {}
}
