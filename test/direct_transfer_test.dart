import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jet2drop/core/photo_transfer.dart';

void main() {
  test(
    'direct transfer accepts text and zip-like bytes without loading them',
    () async {
      final root = await Directory.systemTemp.createTemp('jet2drop-direct-');
      addTearDown(() => root.delete(recursive: true));
      final source = File('${root.path}${Platform.pathSeparator}payload.bin');
      final bytes = <int>[
        ...utf8.encode('PK\x03\x04'),
        ...List<int>.generate(64 * 1024, (i) => i % 251),
      ];
      await source.writeAsBytes(bytes);
      final server = DirectTransferServer(
        token: 'direct-test-token',
        bindAddress: InternetAddress.loopbackIPv4,
        endpointHost: InternetAddress.loopbackIPv4.address,
        saveDirectoryProvider: () async => root.path,
      );
      final client = DirectTransferClient();
      addTearDown(client.dispose);
      addTearDown(server.stop);
      expect(await server.start(), isTrue);

      final receipt = await client.send(
        endpoint: server.endpoint!,
        token: 'direct-test-token',
        source: source,
        fileName: 'archive.zip',
        mimeType: 'application/zip',
      );

      expect(receipt.name, 'archive.zip');
      expect(receipt.size, bytes.length);
      expect(receipt.sha256, sha256.convert(bytes).toString());
      expect(
        await File(
          '${root.path}${Platform.pathSeparator}archive.zip',
        ).readAsBytes(),
        bytes,
      );
      expect(await _partFiles(root), isEmpty);
    },
  );

  test(
    'authenticated health probe reports capability and rejects bad token',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'jet2drop-direct-probe-',
      );
      addTearDown(() => root.delete(recursive: true));
      final server = DirectTransferServer(
        token: 'probe-token',
        bindAddress: InternetAddress.loopbackIPv4,
        endpointHost: InternetAddress.loopbackIPv4.address,
        saveDirectoryProvider: () async => root.path,
      );
      final client = DirectTransferClient();
      addTearDown(client.dispose);
      addTearDown(server.stop);
      expect(await server.start(), isTrue);

      final available = await client.probe(
        endpoint: server.endpoint!,
        token: 'probe-token',
      );
      expect(available.canReceive, isTrue);
      expect(available.isOnline, isTrue);
      expect(available.supportsDirectReceive, isTrue);
      expect(available.maxBytes, directTransferMaxBytes);

      final unauthorized = await client.probe(
        endpoint: server.endpoint!,
        token: 'wrong-token',
      );
      expect(unauthorized.canReceive, isFalse);
      expect(unauthorized.isOnline, isTrue);
      expect(unauthorized.statusCode, HttpStatus.unauthorized);

      String? selectedDirectory = root.path;
      final directoryServer = DirectTransferServer(
        token: 'directory-probe-token',
        bindAddress: InternetAddress.loopbackIPv4,
        endpointHost: InternetAddress.loopbackIPv4.address,
        saveDirectoryProvider: () async => selectedDirectory,
      );
      final directoryClient = DirectTransferClient();
      addTearDown(directoryClient.dispose);
      addTearDown(directoryServer.stop);
      expect(await directoryServer.start(), isTrue);
      expect(
        (await directoryClient.probe(
          endpoint: directoryServer.endpoint!,
          token: 'directory-probe-token',
        )).canReceive,
        isTrue,
      );
      selectedDirectory = null;
      final unavailable = await directoryClient.probe(
        endpoint: directoryServer.endpoint!,
        token: 'directory-probe-token',
      );
      expect(unavailable.isOnline, isTrue);
      expect(unavailable.canReceive, isFalse);
      expect(unavailable.error, contains('目录'));

      final incompatibleServer = await HttpServer.bind(
        InternetAddress.loopbackIPv4,
        0,
      );
      addTearDown(() => incompatibleServer.close(force: true));
      incompatibleServer.listen((request) async {
        request.response
          ..statusCode = HttpStatus.ok
          ..headers.contentType = ContentType.json
          ..write(
            jsonEncode({
              'protocol': 'legacy-photo',
              'version': 1,
              'supportsDirectReceive': true,
            }),
          );
        await request.response.close();
      });
      final incompatible = await client.probe(
        endpoint:
            'http://${InternetAddress.loopbackIPv4.address}:${incompatibleServer.port}',
        token: 'any-token',
      );
      expect(incompatible.isOnline, isTrue);
      expect(incompatible.canReceive, isFalse);
      expect(incompatible.error, contains('不支持'));

      final offline = await client.probe(
        endpoint: 'http://${InternetAddress.loopbackIPv4.address}:1',
        token: 'any-token',
        timeout: const Duration(milliseconds: 200),
      );
      expect(offline.isOnline, isFalse);
    },
  );

  test(
    'wrong token, checksum mismatch and a truncated stream leave no partial',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'jet2drop-direct-fail-',
      );
      addTearDown(() => root.delete(recursive: true));
      final server = DirectTransferServer(
        token: 'direct-fail-token',
        bindAddress: InternetAddress.loopbackIPv4,
        endpointHost: InternetAddress.loopbackIPv4.address,
        saveDirectoryProvider: () async => root.path,
      );
      final client = DirectTransferClient();
      addTearDown(client.dispose);
      addTearDown(server.stop);
      expect(await server.start(), isTrue);
      final source = File('${root.path}${Platform.pathSeparator}source.txt');
      await source.writeAsString('direct payload');

      await expectLater(
        () => client.send(
          endpoint: server.endpoint!,
          token: 'wrong-token',
          source: source,
          fileName: 'wrong.txt',
        ),
        throwsA(isA<DirectTransferException>()),
      );
      await expectLater(
        () => client.send(
          endpoint: server.endpoint!,
          token: 'direct-fail-token',
          source: source,
          fileName: 'mismatch.txt',
          sha256: List<String>.filled(64, '0').join(),
        ),
        throwsA(isA<DirectTransferException>()),
      );
      expect(await _partFiles(root), isEmpty);
      expect(
        await File(
          '${root.path}${Platform.pathSeparator}mismatch.txt',
        ).exists(),
        isFalse,
      );

      final endpoint = Uri.parse(server.endpoint!).replace(
        path: directTransferPath,
        queryParameters: {'name': 'truncated.txt'},
      );
      final socket = await Socket.connect(
        InternetAddress.loopbackIPv4,
        endpoint.port,
      );
      socket.write(
        'POST ${endpoint.path}?name=truncated.txt HTTP/1.1\r\n'
        'Host: ${endpoint.host}:${endpoint.port}\r\n'
        '$directTransferTokenHeader: direct-fail-token\r\n'
        'Content-Type: text/plain\r\n'
        '$directTransferSha256Header: ${sha256.convert(utf8.encode('short body'))}\r\n'
        'Content-Length: 100\r\n\r\n',
      );
      socket.add(utf8.encode('short body'));
      await socket.flush();
      await socket.close();
      await socket.done;
      await _waitFor(() async => (await _partFiles(root)).isEmpty);
      expect(
        await File(
          '${root.path}${Platform.pathSeparator}truncated.txt',
        ).exists(),
        isFalse,
      );
    },
  );

  test(
    'generic endpoint requires SHA-256 while legacy photo permits omission',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'jet2drop-direct-sha-',
      );
      addTearDown(() => root.delete(recursive: true));
      final server = DirectTransferServer(
        token: 'sha-token',
        bindAddress: InternetAddress.loopbackIPv4,
        endpointHost: InternetAddress.loopbackIPv4.address,
        saveDirectoryProvider: () async => root.path,
        legacyPhotoCompatibility: true,
      );
      final http = HttpClient();
      addTearDown(() => http.close(force: true));
      addTearDown(server.stop);
      expect(await server.start(), isTrue);

      final missingShaRequest = await http.postUrl(
        Uri.parse(server.endpoint!).replace(
          path: directTransferPath,
          queryParameters: {'name': 'missing.bin'},
        ),
      );
      missingShaRequest.headers
        ..set(directTransferTokenHeader, 'sha-token')
        ..contentLength = 3
        ..contentType = ContentType.binary;
      missingShaRequest.add([1, 2, 3]);
      final missingShaResponse = await missingShaRequest.close();
      expect(missingShaResponse.statusCode, HttpStatus.badRequest);
      await missingShaResponse.drain<void>();
      expect(
        await File('${root.path}${Platform.pathSeparator}missing.bin').exists(),
        isFalse,
      );

      final legacyRequest = await http.postUrl(
        Uri.parse(server.endpoint!).replace(
          path: photoTransferPath,
          queryParameters: {'name': 'legacy.jpg'},
        ),
      );
      legacyRequest.headers
        ..set(directTransferTokenHeader, 'sha-token')
        ..contentLength = 3
        ..set(HttpHeaders.contentTypeHeader, 'image/jpeg');
      legacyRequest.add([4, 5, 6]);
      final legacyResponse = await legacyRequest.close();
      expect(legacyResponse.statusCode, HttpStatus.ok);
      await legacyResponse.drain<void>();
      expect(
        await File(
          '${root.path}${Platform.pathSeparator}legacy.jpg',
        ).readAsBytes(),
        [4, 5, 6],
      );
    },
  );

  test('same names are serialized and sanitized', () async {
    final root = await Directory.systemTemp.createTemp('jet2drop-direct-name-');
    addTearDown(() => root.delete(recursive: true));
    final server = DirectTransferServer(
      token: 'name-token',
      bindAddress: InternetAddress.loopbackIPv4,
      endpointHost: InternetAddress.loopbackIPv4.address,
      saveDirectoryProvider: () async => root.path,
    );
    final client = DirectTransferClient();
    addTearDown(client.dispose);
    addTearDown(server.stop);
    expect(await server.start(), isTrue);
    final source = File('${root.path}${Platform.pathSeparator}source');
    await source.writeAsBytes([1, 2, 3, 4]);

    final first = await client.send(
      endpoint: server.endpoint!,
      token: 'name-token',
      source: source,
      fileName: '../report.txt',
    );
    final second = await client.send(
      endpoint: server.endpoint!,
      token: 'name-token',
      source: source,
      fileName: '../report.txt',
    );
    expect(first.name, isNot(contains('/')));
    expect(first.name, isNot('../report.txt'));
    expect(second.name, contains('(2)'));
    expect(await _partFiles(root), isEmpty);
  });

  test(
    'wildcard addresses cannot be selected as a receiver bind address',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'jet2drop-direct-bind-',
      );
      addTearDown(() => root.delete(recursive: true));
      final server = DirectTransferServer(
        token: 'bind-token',
        bindAddress: InternetAddress.anyIPv4,
        saveDirectoryProvider: () async => root.path,
      );
      await expectLater(server.start(), throwsArgumentError);
    },
  );
}

Future<List<File>> _partFiles(Directory root) async =>
    (await root.list().toList())
        .whereType<File>()
        .where((file) => file.path.endsWith('.part'))
        .toList();

Future<void> _waitFor(Future<bool> Function() predicate) async {
  for (var attempt = 0; attempt < 30; attempt++) {
    if (await predicate()) return;
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
  expect(await predicate(), isTrue);
}
