import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'checksum.dart';
import 'path_utils.dart';
import 'repository_gateway.dart';
import 'transfer_control.dart';

/// The direct-transfer protocol is intentionally a single request/response
/// stream.  It is not a queue and it never stores a resumable task.
const directTransferPath = '/v1/direct';
const directTransferHealthPath = '$directTransferPath/health';
const directTransferProbePath = directTransferHealthPath;
const directFileTransferPath = directTransferPath;
const directTransferMaxBytes = 10 * 1024 * 1024 * 1024;
const directTransferProtocolVersion = 1;
const directTransferTokenHeader = 'X-Jet2Drop-Token';
const directTransferSha256Header = 'X-Jet2Drop-SHA256';
const _legacyPhotoTransferPath = '/v1/photo';

typedef DirectTransferFileValidator =
    String? Function(String name, String? mimeType);

/// A successful direct-transfer response.
class DirectTransferReceipt {
  const DirectTransferReceipt({
    required this.name,
    required this.size,
    required this.sha256,
  });

  final String name;
  final int size;
  final String sha256;

  String get checksum => sha256;

  Map<String, Object> toJson() => <String, Object>{
    'name': name,
    'size': size,
    'sha256': sha256,
  };

  static DirectTransferReceipt? tryParse(Object? value) {
    if (value is! Map) return null;
    final name = value['name'];
    final size = value['size'];
    final sha256 = value['sha256'];
    if (name is! String ||
        name.trim().isEmpty ||
        size is! num ||
        !size.isFinite ||
        size < 0 ||
        size != size.round() ||
        sha256 is! String ||
        !_isSha256(sha256)) {
      return null;
    }
    return DirectTransferReceipt(
      name: name,
      size: size.toInt(),
      sha256: sha256.toLowerCase(),
    );
  }
}

class DirectTransferException implements Exception {
  const DirectTransferException(this.message, {this.statusCode, this.cause});

  final String message;
  final int? statusCode;
  final Object? cause;

  @override
  String toString() => message;
}

/// Result of the read-only, authenticated health/capability request.
///
/// A probe does not throw for an offline target.  This keeps it suitable for
/// send-window preflight checks; callers can inspect [canReceive] and show
/// [error] while retaining a status code for diagnostics.
class DirectTransferProbeResult {
  const DirectTransferProbeResult({
    required this.isOnline,
    required this.supportsDirectReceive,
    this.endpoint,
    this.statusCode,
    this.error,
    this.protocolVersion,
    this.maxBytes = directTransferMaxBytes,
  });

  final bool isOnline;
  final bool supportsDirectReceive;
  final String? endpoint;
  final int? statusCode;
  final String? error;
  final int? protocolVersion;
  final int maxBytes;

  bool get online => isOnline;
  bool get directReceive => supportsDirectReceive;
  bool get canReceiveDirect => supportsDirectReceive;
  bool get canReceive => isOnline && supportsDirectReceive;
  bool get available => canReceive;
  bool get isHealthy => canReceive;

  static DirectTransferProbeResult offline({
    String? endpoint,
    int? statusCode,
    String? error,
  }) => DirectTransferProbeResult(
    isOnline: false,
    supportsDirectReceive: false,
    endpoint: endpoint,
    statusCode: statusCode,
    error: error,
  );
}

/// A small authenticated HTTP receiver for one arbitrary file at a time.
///
/// When [bindAddress] is omitted, [start] discovers a Tailscale IPv4 address
/// in 100.64.0.0/10.  Loopback is accepted only for deterministic local
/// integration tests; wildcard and other public addresses are rejected.  No
/// task state is retained after the request completes, so cancellation and
/// failure always remove the current partial file.
class DirectTransferServer {
  DirectTransferServer({
    required this.token,
    required this.saveDirectoryProvider,
    this.port = 0,
    this.bindAddress,
    this.endpointHost,
    this.maxBytes = directTransferMaxBytes,
    this.transferPath = directTransferPath,
    String? healthPath,
    this.requestValidator,
    this.allowEmptyFiles = true,
    this.requireExpectedSha256 = true,
    this.legacyPhotoCompatibility = false,
  }) : _healthPath = healthPath ?? '$transferPath/health';

  final String token;
  final Future<String?> Function() saveDirectoryProvider;
  final int port;
  final InternetAddress? bindAddress;
  final String? endpointHost;
  final int maxBytes;
  final String transferPath;
  final DirectTransferFileValidator? requestValidator;
  final bool allowEmptyFiles;
  final bool requireExpectedSha256;

  /// Also accepts the historical photo route on this same HTTP server.
  ///
  /// The compatibility route deliberately keeps its own photo extension and
  /// MIME validation and permits clients that predate the SHA-256 header. The
  /// generic [transferPath] route remains SHA-256 protected.
  final bool legacyPhotoCompatibility;
  final String _healthPath;

  HttpServer? _server;
  String? _endpoint;
  Future<void> _reservationTail = Future<void>.value();
  final Set<String> _reservedPaths = <String>{};

  String? get endpoint => _endpoint;
  String? get directEndpoint => _endpoint;
  String? get healthEndpoint => _endpoint == null
      ? null
      : Uri.parse(_endpoint!).replace(path: _healthPath).toString();
  String get healthPath => _healthPath;
  bool get isRunning => _server != null;
  bool get supportsDirectReceive => true;

  Map<String, Object> get capabilities => <String, Object>{
    'directReceive': supportsDirectReceive,
    'maxBytes': maxBytes,
  };

  /// Starts the receiver.  `false` means no Tailscale address was available;
  /// callers can retry when the Tailscale connection becomes ready.
  Future<bool> start() async {
    _validateConfiguration();
    if (_server != null) return true;
    final address = bindAddress ?? await findTailscaleIpv4Address();
    if (address == null) return false;
    if (!isAllowedBindAddress(address)) {
      throw ArgumentError.value(
        address.address,
        'bindAddress',
        'Direct transfer may bind only a Tailscale IPv4 address or loopback.',
      );
    }
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

  void _validateConfiguration() {
    if (token.trim().isEmpty) {
      throw ArgumentError.value(
        token,
        'token',
        'Direct transfer token is required.',
      );
    }
    if (token.contains('\r') || token.contains('\n')) {
      throw ArgumentError.value(
        token,
        'token',
        'Direct transfer token contains an invalid header character.',
      );
    }
    if (port < 0 || port > 65535) {
      throw ArgumentError.value(
        port,
        'port',
        'Port must be between 0 and 65535.',
      );
    }
    if (maxBytes < 0 || maxBytes > directTransferMaxBytes) {
      throw ArgumentError.value(
        maxBytes,
        'maxBytes',
        'Direct transfer maximum cannot exceed 10 GB.',
      );
    }
    if (transferPath.isEmpty || !transferPath.startsWith('/')) {
      throw ArgumentError.value(
        transferPath,
        'transferPath',
        'Direct transfer path must be absolute.',
      );
    }
  }

  Future<void> _handle(HttpRequest request) async {
    if (request.uri.path == _healthPath &&
        (request.method == 'GET' || request.method == 'HEAD')) {
      if (!_hasValidToken(request)) {
        await _respondError(
          request.response,
          HttpStatus.unauthorized,
          '直传令牌无效。',
          headOnly: request.method == 'HEAD',
        );
        return;
      }
      final directoryHealth = await _checkSaveDirectory();
      final healthCapabilities = <String, Object>{
        'directReceive': directoryHealth.isAvailable,
        'maxBytes': maxBytes,
      };
      final healthBody = <String, Object>{
        'service': 'jet2drop',
        'protocol': 'direct',
        'version': directTransferProtocolVersion,
        'protocolVersion': directTransferProtocolVersion,
        'online': true,
        'path': transferPath,
        'supportsDirectReceive': directoryHealth.isAvailable,
        'canReceiveDirect': directoryHealth.isAvailable,
        'maxBytes': maxBytes,
        'capabilities': healthCapabilities,
      };
      if (directoryHealth.error != null) {
        healthBody['error'] = directoryHealth.error!;
      }
      await _respondJson(
        request.response,
        HttpStatus.ok,
        healthBody,
        headOnly: request.method == 'HEAD',
      );
      return;
    }

    final isLegacyPhotoRequest =
        legacyPhotoCompatibility &&
        request.uri.path == _legacyPhotoTransferPath &&
        request.uri.path != transferPath;
    final isTransferRequest = request.uri.path == transferPath;
    if (request.method != 'POST' ||
        (!isTransferRequest && !isLegacyPhotoRequest)) {
      await _respondError(request.response, HttpStatus.notFound, '直传接口不存在。');
      return;
    }
    if (!_hasValidToken(request)) {
      await _respondError(request.response, HttpStatus.unauthorized, '直传令牌无效。');
      return;
    }

    final rawName = request.uri.queryParameters['name'];
    if (rawName == null || rawName.trim().isEmpty) {
      await _respondError(request.response, HttpStatus.badRequest, '直传文件名缺失。');
      return;
    }
    final name = sanitizeTransferFileName(rawName);
    final size = request.contentLength;
    final requestAllowsEmptyFiles = isLegacyPhotoRequest
        ? false
        : allowEmptyFiles;
    if (size < 0 ||
        size > maxBytes ||
        (!requestAllowsEmptyFiles && size == 0)) {
      await _respondError(
        request.response,
        size > maxBytes
            ? HttpStatus.requestEntityTooLarge
            : HttpStatus.badRequest,
        '直传文件大小无效。',
      );
      return;
    }

    final mimeType = request.headers.contentType?.mimeType;
    final validationError = isLegacyPhotoRequest
        ? _validateLegacyPhotoTransfer(name, mimeType)
        : requestValidator?.call(name, mimeType);
    if (validationError != null) {
      await _respondError(
        request.response,
        HttpStatus.badRequest,
        validationError,
      );
      return;
    }

    final expectedSha256 = request.headers.value(directTransferSha256Header);
    // /v1/direct must always carry a valid expected digest.  The option is
    // retained for the historical PhotoTransferServer wrapper, whose primary
    // route is /v1/photo rather than /v1/direct.
    final requestRequiresExpectedSha256 = isLegacyPhotoRequest
        ? false
        : (request.uri.path == directTransferPath || requireExpectedSha256);
    if ((requestRequiresExpectedSha256 && expectedSha256 == null) ||
        (expectedSha256 != null && !_isSha256(expectedSha256))) {
      await _respondError(
        request.response,
        HttpStatus.badRequest,
        expectedSha256 == null ? '直传必须提供 SHA-256 元数据。' : '直传 SHA-256 元数据无效。',
      );
      return;
    }

    File? partial;
    File? target;
    try {
      final directoryPath = await saveDirectoryProvider();
      if (directoryPath == null || directoryPath.trim().isEmpty) {
        throw const DirectTransferException('请先设置直连接收默认保存目录。');
      }
      final directory = Directory(directoryPath.trim());
      final stat = await directory.stat();
      if (stat.type != FileSystemEntityType.directory) {
        throw const DirectTransferException('直连接收默认保存位置不是文件夹。');
      }

      target = await _reserveTarget(directory, name);
      partial = File('${target.path}.jet2drop-direct-${uniqueSuffix()}.part');
      final sink = partial.openWrite();
      final checksum = Sha256Accumulator();
      var received = 0;
      try {
        await for (final chunk in request) {
          received += chunk.length;
          if (received > size) {
            throw const DirectTransferException('直传数据超过声明大小。');
          }
          checksum.add(chunk);
          sink.add(chunk);
        }
        await sink.flush();
      } finally {
        try {
          await sink.close();
        } finally {
          checksum.close();
        }
      }

      if (received != size) {
        throw const DirectTransferException('直传未完整结束。');
      }
      final checksumValue = checksum.close();
      if (expectedSha256 != null &&
          checksumValue != expectedSha256.trim().toLowerCase()) {
        throw const DirectTransferException('直传 SHA-256 校验失败，未保存。');
      }
      // The reservation serializes Jet2Drop requests.  If another process
      // created the selected name while the stream was in flight, release
      // that reservation and choose the next safe name instead of replacing
      // it during the atomic rename.
      File selectedTarget = target;
      while (await File(selectedTarget.path).exists()) {
        _reservedPaths.remove(_reservationKey(selectedTarget.path));
        selectedTarget = await _reserveTarget(directory, name);
      }
      target = selectedTarget;
      await partial.rename(selectedTarget.path);
      partial = null;
      await _respondJson(request.response, HttpStatus.ok, <String, Object>{
        'name': selectedTarget.uri.pathSegments.last,
        'size': size,
        'sha256': checksumValue,
      });
    } on DirectTransferException catch (exception) {
      await _deletePartial(partial);
      await _respondError(
        request.response,
        exception.statusCode ?? HttpStatus.conflict,
        exception.message,
      );
    } on FileSystemException {
      await _deletePartial(partial);
      await _respondError(
        request.response,
        HttpStatus.conflict,
        '直连接收默认保存目录无效或不可写。',
      );
    } catch (_) {
      await _deletePartial(partial);
      await _respondError(
        request.response,
        HttpStatus.internalServerError,
        '直连保存失败。',
      );
    } finally {
      if (target != null) _reservedPaths.remove(_reservationKey(target.path));
    }
  }

  bool _hasValidToken(HttpRequest request) =>
      request.headers.value(directTransferTokenHeader) == token;

  Future<_DirectReceiveHealth> _checkSaveDirectory() async {
    File? probe;
    var health = const _DirectReceiveHealth(
      isAvailable: false,
      error: '直连接收默认保存目录检查失败。',
    );
    try {
      final directoryPath = await saveDirectoryProvider();
      if (directoryPath == null || directoryPath.trim().isEmpty) {
        health = const _DirectReceiveHealth(
          isAvailable: false,
          error: '直连接收默认保存目录未设置。',
        );
      } else {
        final directory = Directory(directoryPath.trim());
        final stat = await directory.stat();
        if (stat.type != FileSystemEntityType.directory) {
          health = const _DirectReceiveHealth(
            isAvailable: false,
            error: '直连接收默认保存位置不是文件夹。',
          );
        } else {
          // A successful stat does not prove that a later receive can create
          // its .part file. Exercise the same directory permission with one
          // byte, then remove the uniquely named probe before responding.
          probe = File(
            '${directory.path}${Platform.pathSeparator}'
            '.jet2drop-health-${uniqueSuffix()}.probe',
          );
          await probe.writeAsBytes(const <int>[0x4a], flush: true);
          health = const _DirectReceiveHealth(isAvailable: true);
        }
      }
    } on FileSystemException {
      health = const _DirectReceiveHealth(
        isAvailable: false,
        error: '直连接收默认保存目录不可写或不可访问。',
      );
    } catch (_) {
      health = const _DirectReceiveHealth(
        isAvailable: false,
        error: '直连接收默认保存目录检查失败.',
      );
    }

    if (probe != null) {
      try {
        if (await probe.exists()) await probe.delete();
      } on FileSystemException {
        health = const _DirectReceiveHealth(
          isAvailable: false,
          error: '直连接收默认保存目录探针清理失败。',
        );
      } catch (_) {
        health = const _DirectReceiveHealth(
          isAvailable: false,
          error: '直连接收默认保存目录探针清理失败。',
        );
      }
    }
    return health;
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
      // A peer closing the socket can race the cleanup.  A missing partial is
      // already the desired result.
    }
  }

  Future<void> _respondError(
    HttpResponse response,
    int status,
    String message, {
    bool headOnly = false,
  }) => _respondJson(response, status, <String, Object>{
    'error': message,
  }, headOnly: headOnly);

  Future<void> _respondJson(
    HttpResponse response,
    int status,
    Map<String, Object> body, {
    bool headOnly = false,
  }) async {
    try {
      final encoded = utf8.encode(jsonEncode(body));
      response
        ..statusCode = status
        ..headers.contentType = ContentType.json
        ..headers.contentLength = encoded.length;
      if (!headOnly) response.add(encoded);
      await response.close();
    } on IOException {
      // The sending peer may have cancelled.  There is no useful response to
      // send in that case, but the request handler still needs to finish its
      // partial-file cleanup.
    }
  }

  static bool isAllowedBindAddress(InternetAddress address) {
    final bytes = address.rawAddress;
    if (bytes.length == 4 &&
        bytes[0] == 100 &&
        bytes[1] >= 64 &&
        bytes[1] <= 127) {
      return true;
    }
    // Loopback is intentionally allowed to make the core independently
    // testable.  Production callers omit bindAddress, so only Tailscale is
    // selected automatically.
    return address.isLoopback && bytes.length == 4;
  }

  static Future<InternetAddress?> findTailscaleIpv4Address() async {
    final interfaces = await NetworkInterface.list(
      includeLoopback: false,
      type: InternetAddressType.IPv4,
    );
    for (final interface in interfaces) {
      for (final address in interface.addresses) {
        if (isTailscaleIpv4Address(address)) return address;
      }
    }
    return null;
  }
}

class DirectTransferClient {
  DirectTransferClient({
    this.connectionTimeout = const Duration(seconds: 12),
    this.requestTimeout = const Duration(minutes: 30),
    this.transferPath = directTransferPath,
    this.includeExpectedSha256Header = true,
    String? healthPath,
    HttpClient? httpClient,
  }) : _healthPath = healthPath ?? '$transferPath/health',
       _httpClient = httpClient ?? HttpClient(),
       _ownsHttpClient = httpClient == null {
    _httpClient
      ..connectionTimeout = connectionTimeout
      ..autoUncompress = false
      ..idleTimeout = const Duration(minutes: 2);
  }

  final Duration connectionTimeout;
  final Duration requestTimeout;
  final String transferPath;
  final bool includeExpectedSha256Header;
  final String _healthPath;
  final HttpClient _httpClient;
  final bool _ownsHttpClient;
  bool _disposed = false;

  String get healthPath => _healthPath;

  /// Sends one file from the beginning.  [sha256] / [expectedSha256] can be
  /// supplied by a caller that already streamed the file; otherwise the
  /// client calculates the digest in a streaming pre-pass and sends it as
  /// authenticated request metadata.  No pause, resume, or partial state is
  /// retained.
  Future<DirectTransferReceipt> send({
    required String endpoint,
    required String token,
    required File source,
    String? fileName,
    String? mimeType,
    String? sha256,
    String? expectedSha256,
    ProgressCallback? onProgress,
    TransferControl? control,
  }) async {
    _ensureUsable();
    _validateToken(token);
    final name = sanitizeTransferFileName(
      fileName ?? source.uri.pathSegments.last,
    );
    final size = await _readSourceLength(source);
    if (size > directTransferMaxBytes) {
      throw const DirectTransferException('直传文件大小超过 10 GB 限制。');
    }
    if (control?.isCancelled == true) throw const TransferCancelled();
    final uri = _transferUri(endpoint, name);
    final suppliedSha256 = _resolveSha256(sha256, expectedSha256);
    final expected = suppliedSha256 ?? await _hashSource(source, control);
    if (!_isSha256(expected)) {
      throw const DirectTransferException('直传 SHA-256 元数据无效。');
    }
    if (control?.isCancelled == true) throw const TransferCancelled();

    HttpClientRequest? request;
    var transferred = 0;
    control?.bind(
      // Direct transfer has no resumable state.  Cancellation aborts the
      // current request; pause/resume callbacks are deliberately not bound.
      onCancel: () async => request?.abort(),
    );
    try {
      request = await _httpClient.postUrl(uri).timeout(connectionTimeout);
      if (control?.isCancelled == true) {
        request.abort();
        throw const TransferCancelled();
      }
      request.headers
        ..set(directTransferTokenHeader, token)
        ..contentLength = size
        ..set(
          HttpHeaders.contentTypeHeader,
          mimeType == null || mimeType.trim().isEmpty
              ? 'application/octet-stream'
              : mimeType,
        );
      if (includeExpectedSha256Header) {
        request.headers.set(directTransferSha256Header, expected.toLowerCase());
      }
      await request
          .addStream(
            _sourceStream(source, control).map((chunk) {
              if (control?.isCancelled == true) throw const TransferCancelled();
              transferred += chunk.length;
              onProgress?.call(transferred, size);
              return chunk;
            }),
          )
          .timeout(requestTimeout);
      final response = await request.close().timeout(requestTimeout);
      final body = await response.transform(utf8.decoder).join();
      final decoded = _decodeJson(body);
      if (response.statusCode != HttpStatus.ok) {
        throw DirectTransferException(
          decoded?['error'] as String? ?? '直传失败。',
          statusCode: response.statusCode,
        );
      }
      final receipt = DirectTransferReceipt.tryParse(decoded);
      if (receipt == null ||
          receipt.size != size ||
          receipt.sha256 != expected.toLowerCase()) {
        throw const DirectTransferException('直传校验失败，接收端未确认文件。');
      }
      onProgress?.call(size, size);
      return DirectTransferReceipt(
        name: sanitizeTransferFileName(receipt.name),
        size: receipt.size,
        sha256: receipt.sha256,
      );
    } on DirectTransferException {
      rethrow;
    } on TransferCancelled {
      request?.abort();
      rethrow;
    } on TimeoutException {
      request?.abort();
      if (control?.isCancelled == true) throw const TransferCancelled();
      throw const DirectTransferException('直传超时，请确认接收端在线后重新发送。');
    } on SocketException {
      request?.abort();
      if (control?.isCancelled == true) throw const TransferCancelled();
      throw const DirectTransferException('直传连接失败，请确认接收端在线后重新发送。');
    } on HttpException {
      request?.abort();
      if (control?.isCancelled == true) throw const TransferCancelled();
      throw const DirectTransferException('直传连接失败，请确认接收端在线后重新发送。');
    } on FileSystemException catch (exception) {
      request?.abort();
      throw DirectTransferException('直传源文件读取失败。', cause: exception);
    } on FormatException catch (exception) {
      request?.abort();
      throw DirectTransferException('直传请求参数无效。', cause: exception);
    } catch (exception) {
      request?.abort();
      if (control?.isCancelled == true) throw const TransferCancelled();
      throw DirectTransferException('直传失败。', cause: exception);
    } finally {
      // The receiver owns cleanup of its .part file when this stream aborts.
    }
  }

  /// Authenticated health/capability check for a send-window preflight.
  Future<DirectTransferProbeResult> probe({
    required String endpoint,
    required String token,
    Duration? timeout,
  }) async {
    _ensureUsable();
    final parsed = Uri.tryParse(endpoint);
    if (parsed == null ||
        parsed.host.isEmpty ||
        parsed.port <= 0 ||
        (parsed.scheme != 'http' && parsed.scheme != 'https')) {
      return DirectTransferProbeResult.offline(
        endpoint: endpoint,
        error: '目标设备的直传地址无效。',
      );
    }
    if (token.trim().isEmpty || token.contains('\r') || token.contains('\n')) {
      return DirectTransferProbeResult.offline(
        endpoint: endpoint,
        error: '直传令牌无效。',
      );
    }
    final wait = timeout ?? connectionTimeout;
    final uri = parsed.replace(path: _healthPath, queryParameters: const {});
    HttpClientRequest? request;
    try {
      request = await _httpClient.getUrl(uri).timeout(wait);
      request.headers.set(directTransferTokenHeader, token);
      final response = await request.close().timeout(wait);
      final body = await response.transform(utf8.decoder).join();
      final decoded = _decodeJson(body);
      if (decoded == null) {
        return DirectTransferProbeResult(
          isOnline: true,
          supportsDirectReceive: false,
          endpoint: endpoint,
          statusCode: response.statusCode,
          error: '接收服务返回了无效探测结果。',
        );
      }
      if (response.statusCode != HttpStatus.ok) {
        return DirectTransferProbeResult(
          isOnline: true,
          supportsDirectReceive: false,
          endpoint: endpoint,
          statusCode: response.statusCode,
          error: _stringValue(decoded['error']) ?? '接收服务拒绝了探测请求。',
        );
      }
      final capabilities = decoded['capabilities'];
      final nested = capabilities is Map
          ? capabilities
          : const <String, Object>{};
      final supports =
          decoded['supportsDirectReceive'] == true ||
          decoded['canReceiveDirect'] == true ||
          nested['directReceive'] == true;
      final max =
          _intValue(decoded['maxBytes']) ??
          _intValue(nested['maxBytes']) ??
          directTransferMaxBytes;
      final version =
          _intValue(decoded['version']) ??
          _intValue(decoded['protocolVersion']);
      final protocolCompatible =
          decoded['protocol'] == 'direct' &&
          version == directTransferProtocolVersion;
      if (!protocolCompatible || !supports) {
        return DirectTransferProbeResult(
          isOnline: true,
          supportsDirectReceive: false,
          endpoint: endpoint,
          statusCode: response.statusCode,
          protocolVersion: version,
          maxBytes: max,
          error: _stringValue(decoded['error']) ?? '接收服务不支持当前直传协议。',
        );
      }
      return DirectTransferProbeResult(
        isOnline: true,
        supportsDirectReceive: true,
        endpoint: endpoint,
        statusCode: response.statusCode,
        protocolVersion: version,
        maxBytes: max,
      );
    } on TimeoutException {
      request?.abort();
      return DirectTransferProbeResult.offline(
        endpoint: endpoint,
        error: '探测直传接收服务超时。',
      );
    } on SocketException {
      request?.abort();
      return DirectTransferProbeResult.offline(
        endpoint: endpoint,
        error: '无法连接直传接收服务。',
      );
    } on HttpException {
      request?.abort();
      return DirectTransferProbeResult.offline(
        endpoint: endpoint,
        error: '直传接收服务连接失败。',
      );
    } catch (_) {
      request?.abort();
      return DirectTransferProbeResult.offline(
        endpoint: endpoint,
        error: '直传接收服务连接失败。',
      );
    }
  }

  /// Alias for [probe] for callers that use the more explicit health-check
  /// terminology in send-window orchestration.
  Future<DirectTransferProbeResult> check({
    required String endpoint,
    required String token,
    Duration? timeout,
  }) => probe(endpoint: endpoint, token: token, timeout: timeout);

  Future<bool> isAvailable({
    required String endpoint,
    required String token,
    Duration? timeout,
  }) async => (await probe(
    endpoint: endpoint,
    token: token,
    timeout: timeout,
  )).canReceive;

  Future<int> _readSourceLength(File source) async {
    try {
      return await source.length();
    } on FileSystemException catch (exception) {
      throw DirectTransferException('直传源文件读取失败。', cause: exception);
    }
  }

  Future<String> _hashSource(File source, TransferControl? control) async {
    final checksum = Sha256Accumulator();
    try {
      await for (final chunk in source.openRead()) {
        if (control?.isCancelled == true) throw const TransferCancelled();
        checksum.add(chunk);
      }
      return checksum.close();
    } on FileSystemException catch (exception) {
      checksum.close();
      throw DirectTransferException('直传源文件读取失败。', cause: exception);
    } catch (_) {
      checksum.close();
      rethrow;
    }
  }

  Stream<List<int>> _sourceStream(
    File source,
    TransferControl? control,
  ) async* {
    await for (final chunk in source.openRead()) {
      if (control?.isCancelled == true) throw const TransferCancelled();
      yield chunk;
    }
  }

  Uri _transferUri(String endpoint, String name) {
    final parsed = Uri.tryParse(endpoint);
    if (parsed == null ||
        parsed.host.isEmpty ||
        parsed.port <= 0 ||
        (parsed.scheme != 'http' && parsed.scheme != 'https')) {
      throw const DirectTransferException('目标设备的直传地址无效。');
    }
    return parsed.replace(
      path: transferPath,
      queryParameters: <String, String>{'name': name},
    );
  }

  static Map<String, dynamic>? _decodeJson(String body) {
    try {
      final value = jsonDecode(body);
      return value is Map ? Map<String, dynamic>.from(value) : null;
    } catch (_) {
      return null;
    }
  }

  static String? _resolveSha256(String? first, String? second) {
    if (first != null &&
        second != null &&
        first.trim().toLowerCase() != second.trim().toLowerCase()) {
      throw const DirectTransferException('直传 SHA-256 参数不一致。');
    }
    return (second ?? first)?.trim();
  }

  static int? _intValue(Object? value) {
    if (value is num && value.isFinite && value == value.round()) {
      return value.toInt();
    }
    return null;
  }

  static String? _stringValue(Object? value) => value is String ? value : null;

  static void _validateToken(String token) {
    if (token.trim().isEmpty || token.contains('\r') || token.contains('\n')) {
      throw const DirectTransferException('直传令牌无效。');
    }
  }

  void _ensureUsable() {
    if (_disposed) throw StateError('DirectTransferClient has been disposed.');
  }

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    if (_ownsHttpClient) _httpClient.close(force: true);
  }
}

/// Stateless probe facade for UI/orchestration code that does not otherwise
/// need to keep an HTTP client alive.
class DirectTransferProbe {
  const DirectTransferProbe({this.timeout = const Duration(seconds: 3)});

  final Duration timeout;

  Future<DirectTransferProbeResult> check({
    required String endpoint,
    required String token,
    Duration? timeout,
  }) => probeDirectTransfer(
    endpoint: endpoint,
    token: token,
    timeout: timeout ?? this.timeout,
  );

  Future<DirectTransferProbeResult> probe({
    required String endpoint,
    required String token,
    Duration? timeout,
  }) => check(endpoint: endpoint, token: token, timeout: timeout);
}

/// One-shot convenience helper for callers that only need to preflight an
/// endpoint and do not keep a client instance around.
Future<DirectTransferProbeResult> probeDirectTransfer({
  required String endpoint,
  required String token,
  Duration timeout = const Duration(seconds: 3),
}) async {
  final client = DirectTransferClient(
    connectionTimeout: timeout,
    requestTimeout: timeout,
  );
  try {
    return await client.probe(
      endpoint: endpoint,
      token: token,
      timeout: timeout,
    );
  } finally {
    await client.dispose();
  }
}

class _DirectReceiveHealth {
  const _DirectReceiveHealth({required this.isAvailable, this.error});

  final bool isAvailable;
  final String? error;
}

bool isTailscaleIpv4Address(InternetAddress address) {
  final bytes = address.rawAddress;
  return bytes.length == 4 &&
      bytes[0] == 100 &&
      bytes[1] >= 64 &&
      bytes[1] <= 127;
}

bool _isSha256(String value) =>
    RegExp(r'^[0-9a-fA-F]{64}$').hasMatch(value.trim());

/// Validates the historical photo-only endpoint without importing the
/// compatibility wrapper (which itself imports this library).  The generic
/// `/v1/direct` endpoint remains intentionally unrestricted; this helper is
/// used only when a [DirectTransferServer] is explicitly configured to accept
/// the old `/v1/photo` route alongside it.
String? _validateLegacyPhotoTransfer(String name, String? mimeType) {
  final expected = isPhotoFileName(name) ? mimeTypeForName(name) : null;
  if (expected == null || mimeType == null) return '照片类型不受支持。';
  final actual = normalizeMimeType(mimeType);
  if (actual == expected) return null;
  final extension = fileExtension(name);
  if ((extension == 'heic' && actual == 'image/heif') ||
      (extension == 'heif' && actual == 'image/heic')) {
    return null;
  }
  return '照片类型不受支持。';
}
