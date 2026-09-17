import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jet2drop/core/photo_transfer.dart';
import 'package:jet2drop/core/transfer_control.dart';
import 'support/temp_directory.dart';

const _token = 'direct-test-token';

void main() {
  group('protocol version 2 sender and receiver', () {
    test(
      'streams a file with a digest trailer and publishes the final name',
      () async {
        final receiver = await _startReceiver();
        final root = receiver.root;
        final source = File('${root.path}${Platform.pathSeparator}payload.bin');
        final bytes = <int>[
          ...utf8.encode('PK\x03\x04'),
          ...List<int>.generate(64 * 1024, (i) => i % 251),
        ];
        await source.writeAsBytes(bytes);
        final client = DirectTransferClient();
        addTearDown(client.dispose);

        final receipt = await client.send(
          endpoint: receiver.server.endpoint!,
          token: _token,
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

    test('accepts an empty file carried entirely by the trailer', () async {
      final receiver = await _startReceiver();
      final root = receiver.root;
      final source = File(
        '${root.path}${Platform.pathSeparator}_source-empty.bin',
      );
      await source.writeAsBytes(const <int>[]);
      final client = DirectTransferClient();
      addTearDown(client.dispose);
      final progress = <List<int>>[];

      final receipt = await client.send(
        endpoint: receiver.server.endpoint!,
        token: _token,
        source: source,
        fileName: 'empty.bin',
        onProgress: (current, total) => progress.add(<int>[current, total]),
      );

      expect(receipt.size, 0);
      expect(receipt.sha256, sha256.convert(const <int>[]).toString());
      final target = File('${root.path}${Platform.pathSeparator}empty.bin');
      expect(await target.exists(), isTrue);
      expect(await target.length(), 0);
      expect(progress, isNotEmpty);
      expect(progress.last, <int>[0, 0]);
      expect(await _partFiles(root), isEmpty);
    });

    test(
      'counts only file bytes in progress, never the digest trailer',
      () async {
        final receiver = await _startReceiver();
        final root = receiver.root;
        final source = File(
          '${root.path}${Platform.pathSeparator}_source-progress.bin',
        );
        final bytes = List<int>.generate(300 * 1024, (i) => i % 239);
        await source.writeAsBytes(bytes);
        final client = DirectTransferClient();
        addTearDown(client.dispose);
        final progress = <List<int>>[];

        final receipt = await client.send(
          endpoint: receiver.server.endpoint!,
          token: _token,
          source: source,
          fileName: 'progress.bin',
          onProgress: (current, total) => progress.add(<int>[current, total]),
        );

        expect(receipt.size, bytes.length);
        expect(progress, isNotEmpty);
        expect(
          progress.every((entry) => entry[1] == bytes.length),
          isTrue,
          reason: 'the 64-byte trailer must never be reported as file progress',
        );
        expect(progress.every((entry) => entry[0] <= bytes.length), isTrue);
        expect(progress.last, <int>[bytes.length, bytes.length]);
      },
    );

    test(
      'starts the request body before the source file has been read fully',
      () async {
        final receiver = await _startReceiver();
        final root = receiver.root;
        final source = File(
          '${root.path}${Platform.pathSeparator}_source-stream.bin',
        );
        final bytes = List<int>.generate(1024 * 1024, (i) => i % 233);
        await source.writeAsBytes(bytes);

        final firstChunkSent = Completer<void>();
        final releaseRemaining = Completer<void>();
        final client = DirectTransferClient(
          sourceOpener: (file, start, end) async* {
            // Hand the first 256 KiB to the HTTP request, then stay blocked
            // until the test has observed receiver-side activity.  A sender
            // that hashed the file up front could never reach this state.
            final firstEnd = start + 256 * 1024 < end
                ? start + 256 * 1024
                : end;
            yield await file
                .openRead(start, firstEnd)
                .fold<List<int>>(<int>[], (all, chunk) => all..addAll(chunk));
            firstChunkSent.complete();
            await releaseRemaining.future;
            yield* file.openRead(firstEnd, end);
          },
        );
        addTearDown(client.dispose);

        final pending = client.send(
          endpoint: receiver.server.endpoint!,
          token: _token,
          source: source,
          fileName: 'stream.bin',
        );
        await firstChunkSent.future.timeout(const Duration(seconds: 10));
        expect(firstChunkSent.isCompleted, isTrue);

        var observedBeforeFullRead = false;
        if (!releaseRemaining.isCompleted) {
          observedBeforeFullRead = await _waitForValue(() async {
            final partials = await _partFiles(root);
            return partials.isNotEmpty && await partials.first.length() > 0;
          });
        }
        if (!releaseRemaining.isCompleted) releaseRemaining.complete();

        final receipt = await pending;
        expect(
          observedBeforeFullRead,
          isTrue,
          reason:
              'the receiver must see body bytes while the source is only '
              'partially read, which proves there is no digest pre-pass',
        );
        expect(receipt.size, bytes.length);
        expect(receipt.sha256, sha256.convert(bytes).toString());
        expect(
          await File(
            '${root.path}${Platform.pathSeparator}stream.bin',
          ).readAsBytes(),
          bytes,
        );
        expect(await _partFiles(root), isEmpty);
      },
    );

    test('honours caller-supplied digest metadata when it matches', () async {
      final receiver = await _startReceiver();
      final root = receiver.root;
      final source = File(
        '${root.path}${Platform.pathSeparator}_source-supplied.bin',
      );
      final bytes = List<int>.generate(4096, (i) => i % 197);
      await source.writeAsBytes(bytes);
      final client = DirectTransferClient();
      addTearDown(client.dispose);
      final digest = sha256.convert(bytes).toString();

      final receipt = await client.send(
        endpoint: receiver.server.endpoint!,
        token: _token,
        source: source,
        fileName: 'supplied.bin',
        sha256: digest,
        expectedSha256: digest.toUpperCase(),
      );

      expect(receipt.sha256, digest);
      expect(
        await File(
          '${root.path}${Platform.pathSeparator}supplied.bin',
        ).readAsBytes(),
        bytes,
      );
      expect(await _partFiles(root), isEmpty);
    });

    test(
      'rejects invalid or inconsistent caller-supplied digest metadata',
      () async {
        final receiver = await _startReceiver();
        final root = receiver.root;
        final source = File(
          '${root.path}${Platform.pathSeparator}_source-rejected.bin',
        );
        final bytes = List<int>.generate(4096, (i) => i % 191);
        await source.writeAsBytes(bytes);
        final client = DirectTransferClient();
        addTearDown(client.dispose);
        final zeroDigest = List<String>.filled(64, '0').join();

        await expectLater(
          () => client.send(
            endpoint: receiver.server.endpoint!,
            token: _token,
            source: source,
            fileName: 'rejected.bin',
            sha256: 'not-a-digest',
          ),
          throwsA(isA<DirectTransferException>()),
        );
        await expectLater(
          () => client.send(
            endpoint: receiver.server.endpoint!,
            token: _token,
            source: source,
            fileName: 'rejected.bin',
            sha256: zeroDigest,
            expectedSha256: sha256.convert(bytes).toString(),
          ),
          throwsA(isA<DirectTransferException>()),
        );
        // The computed digest must agree with the supplied value, and a mismatch
        // found mid-stream aborts the request before the trailer is written.
        await expectLater(
          () => client.send(
            endpoint: receiver.server.endpoint!,
            token: _token,
            source: source,
            fileName: 'rejected.bin',
            sha256: zeroDigest,
          ),
          throwsA(isA<DirectTransferException>()),
        );
        await _waitFor(() async => (await _partFiles(root)).isEmpty);
        expect(
          await File(
            '${root.path}${Platform.pathSeparator}rejected.bin',
          ).exists(),
          isFalse,
        );
      },
    );

    test(
      'cancel aborts the request and leaves no partial or final file',
      () async {
        final receiver = await _startReceiver();
        final root = receiver.root;
        final source = File(
          '${root.path}${Platform.pathSeparator}_source-cancel.bin',
        );
        final bytes = List<int>.generate(512 * 1024, (i) => i % 241);
        await source.writeAsBytes(bytes);

        final firstChunkSent = Completer<void>();
        final releaseRemaining = Completer<void>();
        final client = DirectTransferClient(
          sourceOpener: (file, start, end) async* {
            var first = true;
            await for (final chunk in file.openRead(start, end)) {
              if (first) {
                first = false;
                yield chunk;
                firstChunkSent.complete();
                await releaseRemaining.future;
              } else {
                yield chunk;
              }
            }
          },
        );
        addTearDown(client.dispose);
        final control = TransferControl();
        final pending = client.send(
          endpoint: receiver.server.endpoint!,
          token: _token,
          source: source,
          fileName: 'cancel.bin',
          control: control,
        );
        await firstChunkSent.future.timeout(const Duration(seconds: 10));
        await control.cancel();
        if (!releaseRemaining.isCompleted) releaseRemaining.complete();

        await expectLater(pending, throwsA(isA<TransferCancelled>()));
        await _waitFor(() async => (await _partFiles(root)).isEmpty);
        expect(
          await File(
            '${root.path}${Platform.pathSeparator}cancel.bin',
          ).exists(),
          isFalse,
        );
      },
    );

    test('a receiver that drops the connection fails the send', () async {
      final root = await Directory.systemTemp.createTemp(
        'jet2drop-direct-drop-',
      );
      addTearDown(() => deleteTempDirectory(root));
      final dropping = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => dropping.close(force: true));
      dropping.listen((request) async {
        final socket = await request.response.detachSocket(writeHeaders: false);
        socket.destroy();
      });
      final source = File('${root.path}${Platform.pathSeparator}drop.bin');
      await source.writeAsBytes(List<int>.generate(2048, (i) => i % 181));
      final client = DirectTransferClient();
      addTearDown(client.dispose);

      await expectLater(
        () => client.send(
          endpoint:
              'http://${InternetAddress.loopbackIPv4.address}:${dropping.port}',
          token: _token,
          source: source,
          fileName: 'drop.bin',
        ),
        throwsA(isA<DirectTransferException>()),
      );
    });

    test('concurrent sends with one name publish two distinct files', () async {
      final receiver = await _startReceiver();
      final root = receiver.root;
      final source = File(
        '${root.path}${Platform.pathSeparator}concurrent.bin',
      );
      final bytes = List<int>.generate(48 * 1024, (i) => i % 179);
      await source.writeAsBytes(bytes);
      final client = DirectTransferClient();
      addTearDown(client.dispose);

      final receipts = await Future.wait(<Future<DirectTransferReceipt>>[
        client.send(
          endpoint: receiver.server.endpoint!,
          token: _token,
          source: source,
          fileName: 'report.bin',
        ),
        client.send(
          endpoint: receiver.server.endpoint!,
          token: _token,
          source: source,
          fileName: 'report.bin',
        ),
      ]);

      expect(receipts.map((receipt) => receipt.name).toSet().length, 2);
      expect(receipts.map((receipt) => receipt.name), contains('report.bin'));
      expect(
        receipts.every(
          (receipt) => receipt.sha256 == sha256.convert(bytes).toString(),
        ),
        isTrue,
      );
      expect(await _partFiles(root), isEmpty);
    });
  });

  group('protocol version 2 receiver validation', () {
    test(
      'rejects a request without a usable protocol version header',
      () async {
        final receiver = await _startReceiver();
        final root = receiver.root;
        final bytes = utf8.encode('legacy body');
        final legacyHeaders = <String, String>{
          directTransferTokenHeader: _token,
          directTransferSha256Header: sha256.convert(bytes).toString(),
        };

        expect(
          await _rawStatus(
            receiver,
            name: 'legacy-generic.bin',
            headers: legacyHeaders,
            body: bytes,
          ),
          HttpStatus.badRequest,
        );
        expect(
          await _rawStatus(
            receiver,
            name: 'version-one.bin',
            headers: <String, String>{
              ...legacyHeaders,
              directTransferProtocolVersionHeader: '1',
              directTransferFileLengthHeader: '${bytes.length}',
            },
            body: bytes,
            contentLength: bytes.length + directTransferChecksumTrailerLength,
          ),
          HttpStatus.badRequest,
        );
        expect(
          await _rawStatus(
            receiver,
            name: 'version-garbage.bin',
            headers: <String, String>{
              directTransferTokenHeader: _token,
              directTransferProtocolVersionHeader: 'v2',
              directTransferFileLengthHeader: '${bytes.length}',
            },
            body: bytes,
            contentLength: bytes.length + directTransferChecksumTrailerLength,
          ),
          HttpStatus.badRequest,
        );
        await _expectNothingPublished(root, const <String>[
          'legacy-generic.bin',
          'version-one.bin',
          'version-garbage.bin',
        ]);
      },
    );

    test(
      'rejects missing, malformed and overflowing file length headers',
      () async {
        final receiver = await _startReceiver();
        final root = receiver.root;
        final headers = <String, String>{
          directTransferTokenHeader: _token,
          directTransferProtocolVersionHeader: '$directTransferProtocolVersion',
        };

        expect(
          await _rawStatus(
            receiver,
            name: 'no-length.bin',
            headers: headers,
            body: const <int>[1, 2, 3],
          ),
          HttpStatus.badRequest,
        );
        for (final value in <String>[
          '',
          'abc',
          '-5',
          '3.5',
          '99999999999999999999',
        ]) {
          expect(
            await _rawStatus(
              receiver,
              name: 'bad-length.bin',
              headers: <String, String>{
                ...headers,
                directTransferFileLengthHeader: value,
              },
              body: const <int>[1, 2, 3],
            ),
            HttpStatus.badRequest,
            reason: 'file length header "$value" must be rejected',
          );
        }
        await _expectNothingPublished(root, const <String>[
          'no-length.bin',
          'bad-length.bin',
        ]);
      },
    );

    test(
      'rejects a body length that does not match the declared file length',
      () async {
        final receiver = await _startReceiver();
        final root = receiver.root;
        final bytes = utf8.encode('declared length mismatch');
        final digest = sha256.convert(bytes).toString();

        // File-Length says 10 but the HTTP body is barely longer than the file.
        expect(
          await _rawStatus(
            receiver,
            name: 'length-mismatch.bin',
            headers: <String, String>{
              directTransferTokenHeader: _token,
              directTransferProtocolVersionHeader:
                  '$directTransferProtocolVersion',
              directTransferFileLengthHeader: '10',
            },
            body: <int>[...bytes, ...ascii.encode(digest)],
          ),
          HttpStatus.badRequest,
        );
        // File-Length agrees with Content-Length, but it declares 32 bytes
        // more content than the file whose digest is in the trailer, so the
        // receiver hashes different bytes than the sender did.
        final declaredFile = <int>[...bytes, ...List<int>.filled(32, 0)];
        expect(
          await _rawStatus(
            receiver,
            name: 'truncated-content.bin',
            headers: <String, String>{
              directTransferTokenHeader: _token,
              directTransferProtocolVersionHeader:
                  '$directTransferProtocolVersion',
              directTransferFileLengthHeader: '${declaredFile.length}',
            },
            body: <int>[...declaredFile, ...ascii.encode(digest)],
          ),
          isNot(HttpStatus.ok),
        );
        await _expectNothingPublished(root, const <String>[
          'length-mismatch.bin',
          'truncated-content.bin',
        ]);
      },
    );

    test(
      'rejects a wrong, missing, malformed or extra-long digest trailer',
      () async {
        final receiver = await _startReceiver();
        final root = receiver.root;
        final bytes = utf8.encode('trailer verification payload');
        final digest = sha256.convert(bytes).toString();
        final wrongBytes = utf8.encode('different trailer payload');
        final wrongDigest = sha256.convert(wrongBytes).toString();

        Future<int?> post(String name, List<int> body, {int? fileLength}) =>
            _rawStatus(
              receiver,
              name: name,
              headers: <String, String>{
                directTransferTokenHeader: _token,
                directTransferProtocolVersionHeader:
                    '$directTransferProtocolVersion',
                directTransferFileLengthHeader: '${fileLength ?? bytes.length}',
              },
              body: body,
            );

        // A digest that does not describe the received bytes.
        expect(
          await post('wrong-digest.bin', <int>[
            ...bytes,
            ...ascii.encode(wrongDigest),
          ]),
          isNot(HttpStatus.ok),
        );
        // Missing trailer: the body is only the file.
        expect(
          await post('missing-trailer.bin', bytes, fileLength: bytes.length),
          isNot(HttpStatus.ok),
        );
        // Truncated trailer.
        expect(
          await post('short-trailer.bin', <int>[
            ...bytes,
            ...ascii.encode(digest).sublist(0, 40),
          ]),
          isNot(HttpStatus.ok),
        );
        // Upper-case and non-hex trailers are format errors.
        expect(
          await post('upper-trailer.bin', <int>[
            ...bytes,
            ...ascii.encode(digest.toUpperCase()),
          ]),
          HttpStatus.conflict,
        );
        expect(
          await post('nonhex-trailer.bin', <int>[
            ...bytes,
            ...ascii.encode('z' * 64),
          ]),
          HttpStatus.conflict,
        );
        // Content longer than the declared file length shifts the trailer.
        expect(
          await post('overlong.bin', <int>[
            ...bytes,
            0x41,
            ...ascii.encode(digest),
          ], fileLength: bytes.length),
          isNot(HttpStatus.ok),
        );
        await _expectNothingPublished(root, const <String>[
          'wrong-digest.bin',
          'missing-trailer.bin',
          'short-trailer.bin',
          'upper-trailer.bin',
          'nonhex-trailer.bin',
          'overlong.bin',
        ]);
      },
    );

    test('applies the 10 GB limit to file content only', () async {
      final receiver = await _startReceiver(maxBytes: 100);
      final root = receiver.root;
      final bytes = List<int>.generate(100, (i) => i % 173);
      final digest = sha256.convert(bytes).toString();

      expect(
        await _rawStatus(
          receiver,
          name: 'boundary.bin',
          headers: <String, String>{
            directTransferTokenHeader: _token,
            directTransferProtocolVersionHeader:
                '$directTransferProtocolVersion',
            directTransferFileLengthHeader: '100',
          },
          body: <int>[...bytes, ...ascii.encode(digest)],
        ),
        HttpStatus.ok,
      );
      expect(
        await File(
          '${root.path}${Platform.pathSeparator}boundary.bin',
        ).readAsBytes(),
        bytes,
      );

      expect(
        await _rawStatus(
          receiver,
          name: 'over-limit.bin',
          headers: <String, String>{
            directTransferTokenHeader: _token,
            directTransferProtocolVersionHeader:
                '$directTransferProtocolVersion',
            directTransferFileLengthHeader: '101',
          },
          contentLength: 101 + directTransferChecksumTrailerLength,
        ),
        HttpStatus.requestEntityTooLarge,
      );
      await _expectNothingPublished(root, const <String>['over-limit.bin']);

      // The declared ceiling is checked against file content only, so the
      // 64-byte trailer never pushes a legal file over the limit: 100 content
      // bytes plus the trailer were accepted above.  The production default is
      // the asserted 10 GB ceiling; a 20-digit length is rejected as an
      // overflow by the parser instead of wrapping.
      expect(receiver.server.maxBytes, 100);
      expect(
        await _rawStatus(
          receiver,
          name: 'overflow-length.bin',
          headers: <String, String>{
            directTransferTokenHeader: _token,
            directTransferProtocolVersionHeader:
                '$directTransferProtocolVersion',
            directTransferFileLengthHeader:
                '${directTransferMaxBytes + 1}000000000',
          },
          body: const <int>[1, 2, 3],
        ),
        HttpStatus.badRequest,
      );
      await _expectNothingPublished(root, const <String>[
        'overflow-length.bin',
      ]);
    });

    test(
      'generic route requires the version header while legacy photo permits omission',
      () async {
        final receiver = await _startReceiver(legacyPhotoCompatibility: true);
        final root = receiver.root;
        final http = HttpClient();
        addTearDown(() => http.close(force: true));

        final missingVersion = await http.postUrl(
          Uri.parse(receiver.server.endpoint!).replace(
            path: directTransferPath,
            queryParameters: {'name': 'missing.bin'},
          ),
        );
        missingVersion.headers
          ..set(directTransferTokenHeader, _token)
          ..contentLength = 3
          ..contentType = ContentType.binary;
        missingVersion.add(<int>[1, 2, 3]);
        final missingVersionResponse = await missingVersion.close();
        expect(missingVersionResponse.statusCode, HttpStatus.badRequest);
        await missingVersionResponse.drain<void>();
        expect(
          await File(
            '${root.path}${Platform.pathSeparator}missing.bin',
          ).exists(),
          isFalse,
        );

        final legacyRequest = await http.postUrl(
          Uri.parse(receiver.server.endpoint!).replace(
            path: photoTransferPath,
            queryParameters: {'name': 'legacy.jpg'},
          ),
        );
        legacyRequest.headers
          ..set(directTransferTokenHeader, _token)
          ..contentLength = 3
          ..set(HttpHeaders.contentTypeHeader, 'image/jpeg');
        legacyRequest.add(<int>[4, 5, 6]);
        final legacyResponse = await legacyRequest.close();
        expect(legacyResponse.statusCode, HttpStatus.ok);
        await legacyResponse.drain<void>();
        expect(
          await File(
            '${root.path}${Platform.pathSeparator}legacy.jpg',
          ).readAsBytes(),
          <int>[4, 5, 6],
        );
        expect(await _partFiles(root), isEmpty);
      },
    );
  });

  group('protocol version compatibility', () {
    test(
      'a version 2 sender fails against a version 1 receiver without downgrading',
      () async {
        final root = await Directory.systemTemp.createTemp(
          'jet2drop-direct-legacy-receiver-',
        );
        addTearDown(() => deleteTempDirectory(root));
        final legacyReceiver = await HttpServer.bind(
          InternetAddress.loopbackIPv4,
          0,
        );
        addTearDown(() => legacyReceiver.close(force: true));
        var requests = 0;
        HttpHeaders? observedHeaders;
        legacyReceiver.listen((request) async {
          requests++;
          observedHeaders = request.headers;
          await request.drain<void>();
          // The version 1 receiver required the historical digest header and
          // never looked at a body trailer.
          final legacyDigest = request.headers.value(
            directTransferSha256Header,
          );
          request.response
            ..statusCode = legacyDigest == null
                ? HttpStatus.badRequest
                : HttpStatus.ok
            ..headers.contentType = ContentType.json
            ..write(
              jsonEncode(<String, Object>{'error': '直传必须提供 SHA-256 元数据。'}),
            );
          await request.response.close();
        });
        final source = File('${root.path}${Platform.pathSeparator}legacy.bin');
        final bytes = List<int>.generate(2048, (i) => i % 167);
        await source.writeAsBytes(bytes);
        final client = DirectTransferClient();
        addTearDown(client.dispose);

        await expectLater(
          () => client.send(
            endpoint:
                'http://${InternetAddress.loopbackIPv4.address}:${legacyReceiver.port}',
            token: _token,
            source: source,
            fileName: 'legacy.bin',
          ),
          throwsA(isA<DirectTransferException>()),
        );
        expect(requests, 1, reason: 'the sender must not retry with version 1');
        expect(
          observedHeaders?.value(directTransferProtocolVersionHeader),
          '$directTransferProtocolVersion',
        );
        expect(
          observedHeaders?.value(directTransferFileLengthHeader),
          '${bytes.length}',
        );
        expect(
          observedHeaders?.value(directTransferSha256Header),
          isNull,
          reason: 'the version 2 request must not carry version 1 metadata',
        );
      },
    );

    test('the health endpoint advertises protocol version 2', () async {
      final receiver = await _startReceiver();
      final client = DirectTransferClient();
      addTearDown(client.dispose);

      final available = await client.probe(
        endpoint: receiver.server.endpoint!,
        token: _token,
      );

      expect(available.canReceive, isTrue);
      expect(available.isOnline, isTrue);
      expect(available.supportsDirectReceive, isTrue);
      expect(available.protocolVersion, 2);
      expect(available.protocolVersion, directTransferProtocolVersion);
      expect(available.maxBytes, directTransferMaxBytes);

      final unauthorized = await client.probe(
        endpoint: receiver.server.endpoint!,
        token: 'wrong-token',
      );
      expect(unauthorized.canReceive, isFalse);
      expect(unauthorized.isOnline, isTrue);
      expect(unauthorized.statusCode, HttpStatus.unauthorized);
    });

    test('authenticated health probe reports directory availability', () async {
      final root = await Directory.systemTemp.createTemp(
        'jet2drop-direct-probe-',
      );
      addTearDown(() => deleteTempDirectory(root));
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
            jsonEncode(<String, Object>{
              'protocol': 'direct',
              'version': 1,
              'supportsDirectReceive': true,
            }),
          );
        await request.response.close();
      });
      final incompatible = await directoryClient.probe(
        endpoint:
            'http://${InternetAddress.loopbackIPv4.address}:${incompatibleServer.port}',
        token: 'any-token',
      );
      expect(incompatible.isOnline, isTrue);
      expect(incompatible.canReceive, isFalse);
      expect(incompatible.error, contains('不支持'));

      final offline = await directoryClient.probe(
        endpoint: 'http://${InternetAddress.loopbackIPv4.address}:1',
        token: 'any-token',
        timeout: const Duration(milliseconds: 200),
      );
      expect(offline.isOnline, isFalse);
    });
  });

  group('existing behaviour', () {
    test('wrong token and a truncated request leave no partial file', () async {
      final receiver = await _startReceiver();
      final root = receiver.root;
      final client = DirectTransferClient();
      addTearDown(client.dispose);
      final source = File('${root.path}${Platform.pathSeparator}source.txt');
      await source.writeAsString('direct payload');

      await expectLater(
        () => client.send(
          endpoint: receiver.server.endpoint!,
          token: 'wrong-token',
          source: source,
          fileName: 'wrong.txt',
        ),
        throwsA(isA<DirectTransferException>()),
      );
      expect(await _partFiles(root), isEmpty);
      expect(
        await File('${root.path}${Platform.pathSeparator}wrong.txt').exists(),
        isFalse,
      );

      // A request that declares 100 file bytes but disconnects after 74 bytes
      // must never publish anything.  The half-closed socket means no status
      // assertion is meaningful here; the file system is the evidence.
      final body = <int>[
        ...utf8.encode('short body'),
        ...ascii.encode(sha256.convert(utf8.encode('short body')).toString()),
      ];
      await _rawStatus(
        receiver,
        name: 'truncated.txt',
        headers: <String, String>{
          directTransferTokenHeader: _token,
          directTransferProtocolVersionHeader: '$directTransferProtocolVersion',
          directTransferFileLengthHeader: '100',
        },
        body: body,
        contentLength: 100 + directTransferChecksumTrailerLength,
        pad: false,
      );
      await _waitFor(() async => (await _partFiles(root)).isEmpty);
      expect(
        await File(
          '${root.path}${Platform.pathSeparator}truncated.txt',
        ).exists(),
        isFalse,
      );
    });

    test('same names are serialized and sanitized', () async {
      final receiver = await _startReceiver();
      final root = receiver.root;
      final client = DirectTransferClient();
      addTearDown(client.dispose);
      final source = File('${root.path}${Platform.pathSeparator}source');
      await source.writeAsBytes(<int>[1, 2, 3, 4]);

      final first = await client.send(
        endpoint: receiver.server.endpoint!,
        token: _token,
        source: source,
        fileName: '../report.txt',
      );
      final second = await client.send(
        endpoint: receiver.server.endpoint!,
        token: _token,
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
        addTearDown(() => deleteTempDirectory(root));
        final server = DirectTransferServer(
          token: 'bind-token',
          bindAddress: InternetAddress.anyIPv4,
          saveDirectoryProvider: () async => root.path,
        );
        await expectLater(server.start(), throwsArgumentError);
      },
    );
  });
}

class _Receiver {
  const _Receiver(this.root, this.server);

  final Directory root;
  final DirectTransferServer server;
}

Future<_Receiver> _startReceiver({
  int maxBytes = directTransferMaxBytes,
  bool legacyPhotoCompatibility = false,
}) async {
  final root = await Directory.systemTemp.createTemp('jet2drop-direct-');
  final server = DirectTransferServer(
    token: _token,
    bindAddress: InternetAddress.loopbackIPv4,
    endpointHost: InternetAddress.loopbackIPv4.address,
    saveDirectoryProvider: () async => root.path,
    maxBytes: maxBytes,
    legacyPhotoCompatibility: legacyPhotoCompatibility,
  );
  // A cancelled or aborted send can still hold its .part handle for a moment
  // after the test body finished, so the cleanup is retried instead of racing
  // the receiver's own close.  Teardowns run in reverse registration order, so
  // [server.stop] is registered last and therefore runs first.
  addTearDown(() => deleteTempDirectory(root));
  addTearDown(server.stop);
  expect(await server.start(), isTrue);
  return _Receiver(root, server);
}

Future<List<File>> _partFiles(Directory root) async =>
    (await root.list().toList())
        .whereType<File>()
        .where((file) => file.path.endsWith('.part'))
        .toList();

/// Sends one raw HTTP request and reports the response status.
///
/// A receiver only flushes a response once the declared body has been drained,
/// so by default the payload is padded with zero bytes to the declared
/// Content-Length.  Pass `pad: false` for a genuinely truncated request; the
/// socket is then half-closed so the receiver sees the short body, and only
/// file-system effects can be asserted.
Future<int?> _rawStatus(
  _Receiver receiver, {
  required String name,
  required Map<String, String> headers,
  List<int> body = const <int>[],
  int? contentLength,
  String? path,
  bool pad = true,
}) async {
  final endpoint = Uri.parse(receiver.server.endpoint!);
  final declared = contentLength ?? body.length;
  final payload = pad && declared > body.length
      ? <int>[...body, ...List<int>.filled(declared - body.length, 0)]
      : body;
  final socket = await Socket.connect(
    InternetAddress.loopbackIPv4,
    endpoint.port,
  );
  final received = <int>[];
  var closed = false;
  socket.listen(
    received.addAll,
    onDone: () => closed = true,
    onError: (_) => closed = true,
    cancelOnError: true,
  );
  final request = StringBuffer()
    ..write(
      'POST ${path ?? directTransferPath}'
      '?name=${Uri.encodeQueryComponent(name)} HTTP/1.1\r\n',
    )
    ..write('Host: ${endpoint.host}:${endpoint.port}\r\n');
  headers.forEach((key, value) => request.write('$key: $value\r\n'));
  request.write('Content-Length: $declared\r\n\r\n');
  try {
    socket.write(request.toString());
    if (payload.isNotEmpty) socket.add(payload);
    await socket.flush();
    if (!pad) await socket.close();
  } on SocketException {
    // A receiver that rejects the request early may close the socket first.
  }
  final deadline = DateTime.now().add(const Duration(seconds: 2));
  while (!closed &&
      DateTime.now().isBefore(deadline) &&
      !_responseText(received).contains('\r\n\r\n')) {
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  socket.destroy();
  return _statusCode(received);
}

String _responseText(List<int> bytes) =>
    String.fromCharCodes(bytes.where((byte) => byte < 0x80));

int? _statusCode(List<int> bytes) {
  final match = RegExp(
    r'^HTTP/\d\.\d (\d{3})',
  ).firstMatch(_responseText(bytes));
  if (match == null) return null;
  return int.tryParse(match.group(1)!);
}

Future<void> _expectNothingPublished(Directory root, List<String> names) async {
  await _waitFor(() async => (await _partFiles(root)).isEmpty);
  expect(await _partFiles(root), isEmpty);
  for (final name in names) {
    expect(
      await File('${root.path}${Platform.pathSeparator}$name').exists(),
      isFalse,
      reason: '$name must not be published',
    );
  }
}

Future<bool> _waitForValue(Future<bool> Function() predicate) async {
  for (var attempt = 0; attempt < 50; attempt++) {
    if (await predicate()) return true;
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
  return await predicate();
}

Future<void> _waitFor(Future<bool> Function() predicate) async {
  expect(
    await _waitForValue(predicate),
    isTrue,
    reason: 'the expected state was not reached in time',
  );
}
