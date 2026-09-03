import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:jet2drop/core/photo_transfer.dart';

void main() {
  test(
    'photo HTTP transfer streams, verifies and auto-renames safely',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'jet2drop-photo-http-',
      );
      addTearDown(() => root.delete(recursive: true));
      final sourceDirectory = Directory(
        '${root.path}${Platform.pathSeparator}source',
      );
      await sourceDirectory.create();
      final source = File(
        '${sourceDirectory.path}${Platform.pathSeparator}原图.jpg',
      );
      final bytes = List<int>.generate(128 * 1024, (index) => index % 251);
      await source.writeAsBytes(bytes);
      final server = PhotoTransferServer(
        token: 'photo-test-token',
        bindAddress: InternetAddress.loopbackIPv4,
        endpointHost: InternetAddress.loopbackIPv4.address,
        saveDirectoryProvider: () async => root.path,
      );
      final client = PhotoTransferClient();
      addTearDown(client.dispose);
      addTearDown(server.stop);
      expect(await server.start(), isTrue);

      final first = await client.send(
        endpoint: server.endpoint!,
        token: 'photo-test-token',
        source: source,
        fileName: '原图.jpg',
        mimeType: 'image/jpeg',
      );
      expect(first.name, '原图.jpg');
      expect(
        await File('${root.path}${Platform.pathSeparator}原图.jpg').readAsBytes(),
        bytes,
      );

      final second = await client.send(
        endpoint: server.endpoint!,
        token: 'photo-test-token',
        source: source,
        fileName: '原图.jpg',
        mimeType: 'image/jpeg',
      );
      expect(second.name, '原图 (2).jpg');
      expect(
        await File(
          '${root.path}${Platform.pathSeparator}原图 (2).jpg',
        ).readAsBytes(),
        bytes,
      );
      expect(
        (await root.list().toList()).whereType<File>().any(
          (file) => file.path.endsWith('.part'),
        ),
        isFalse,
      );
    },
  );

  test(
    'photo HTTP transfer rejects bad authentication and removes incomplete part',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'jet2drop-photo-fail-',
      );
      addTearDown(() => root.delete(recursive: true));
      final server = PhotoTransferServer(
        token: 'photo-test-token',
        bindAddress: InternetAddress.loopbackIPv4,
        endpointHost: InternetAddress.loopbackIPv4.address,
        saveDirectoryProvider: () async => root.path,
      );
      final client = PhotoTransferClient();
      addTearDown(client.dispose);
      addTearDown(server.stop);
      expect(await server.start(), isTrue);
      final source = File('${root.path}${Platform.pathSeparator}small.jpg');
      await source.writeAsBytes([1, 2, 3]);

      await expectLater(
        () => client.send(
          endpoint: server.endpoint!,
          token: 'wrong-token',
          source: source,
          fileName: 'small.jpg',
        ),
        throwsA(isA<PhotoTransferException>()),
      );

      final http = HttpClient();
      addTearDown(() => http.close(force: true));
      final endpoint = Uri.parse(server.endpoint!).replace(
        path: photoTransferPath,
        queryParameters: {'name': 'partial.jpg'},
      );
      final socket = await Socket.connect(
        InternetAddress.loopbackIPv4,
        endpoint.port,
      );
      addTearDown(socket.close);
      socket.write(
        'POST ${endpoint.path}?name=partial.jpg HTTP/1.1\r\n'
        'Host: ${endpoint.host}:${endpoint.port}\r\n'
        'X-Jet2Drop-Token: photo-test-token\r\n'
        'Content-Type: image/jpeg\r\n'
        'Content-Length: 10\r\n\r\n',
      );
      socket.add([1, 2, 3]);
      await socket.flush();
      await socket.close();
      await socket.done;
      expect(
        (await root.list().toList()).whereType<File>().any(
          (file) => file.path.endsWith('.part'),
        ),
        isFalse,
      );
      expect(
        (await root.list().toList()).whereType<File>().any(
          (file) => file.path.endsWith('partial.jpg'),
        ),
        isFalse,
      );
    },
  );

  test('photo endpoint response remains machine-readable', () async {
    final root = await Directory.systemTemp.createTemp('jet2drop-photo-json-');
    addTearDown(() => root.delete(recursive: true));
    final server = PhotoTransferServer(
      token: 'token',
      bindAddress: InternetAddress.loopbackIPv4,
      endpointHost: InternetAddress.loopbackIPv4.address,
      saveDirectoryProvider: () async => root.path,
    );
    addTearDown(server.stop);
    expect(await server.start(), isTrue);
    final http = HttpClient();
    addTearDown(() => http.close(force: true));
    final request = await http.postUrl(
      Uri.parse(server.endpoint!).replace(
        path: photoTransferPath,
        queryParameters: {'name': 'empty.jpg'},
      ),
    );
    request.headers
      ..set('X-Jet2Drop-Token', 'token')
      ..contentLength = 1
      ..set('Content-Type', 'image/jpeg');
    request.add([7]);
    final response = await request.close();
    final body = jsonDecode(await response.transform(utf8.decoder).join());
    expect(response.statusCode, HttpStatus.ok);
    expect(body['name'], 'empty.jpg');
    expect(body['size'], 1);
    expect(body['sha256'], isA<String>());
  });

  test('a directory change only affects requests that start later', () async {
    final root = await Directory.systemTemp.createTemp('jet2drop-photo-dir-');
    addTearDown(() => root.delete(recursive: true));
    final first = Directory('${root.path}${Platform.pathSeparator}first');
    final second = Directory('${root.path}${Platform.pathSeparator}second');
    await first.create();
    await second.create();
    var selectedDirectory = first.path;
    final providerEntered = Completer<void>();
    final releaseProvider = Completer<void>();
    var calls = 0;
    final server = PhotoTransferServer(
      token: 'directory-token',
      bindAddress: InternetAddress.loopbackIPv4,
      endpointHost: InternetAddress.loopbackIPv4.address,
      saveDirectoryProvider: () async {
        final captured = selectedDirectory;
        calls++;
        if (calls == 1) {
          providerEntered.complete();
          await releaseProvider.future;
        }
        return captured;
      },
    );
    final client = PhotoTransferClient();
    addTearDown(client.dispose);
    addTearDown(server.stop);
    expect(await server.start(), isTrue);
    final source = File('${root.path}${Platform.pathSeparator}photo.jpg');
    await source.writeAsBytes([1, 2, 3]);

    final inFlight = client.send(
      endpoint: server.endpoint!,
      token: 'directory-token',
      source: source,
      fileName: 'photo.jpg',
      mimeType: 'image/jpeg',
    );
    await providerEntered.future;
    selectedDirectory = second.path;
    releaseProvider.complete();
    await inFlight;
    await client.send(
      endpoint: server.endpoint!,
      token: 'directory-token',
      source: source,
      fileName: 'photo.jpg',
      mimeType: 'image/jpeg',
    );

    expect(
      await File('${first.path}${Platform.pathSeparator}photo.jpg').exists(),
      isTrue,
    );
    expect(
      await File('${second.path}${Platform.pathSeparator}photo.jpg').exists(),
      isTrue,
    );
  });
}
