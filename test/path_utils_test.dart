import 'package:flutter_test/flutter_test.dart';
import 'package:jet2drop/core/path_utils.dart';
import 'package:jet2drop/core/quick_transfer.dart';
import 'package:jet2drop/infrastructure/local_repository_gateway.dart';
import 'package:jet2drop/infrastructure/serialized_repository_gateway.dart';
import 'dart:io';

void main() {
  test('normalizes platform separators without traversal', () {
    expect(normalizeRelativePath(r'code\\sample.dart'), 'code/sample.dart');
    expect(joinRelativePath('code', 'sample.dart'), 'code/sample.dart');
  });

  test('rejects path traversal', () {
    expect(() => normalizeRelativePath('../private'), throwsArgumentError);
  });

  test('publishes and receives a checksummed payload', () async {
    final root = await Directory.systemTemp.createTemp('jet2drop-test-');
    addTearDown(() => root.delete(recursive: true));
    final source = File('${root.path}${Platform.pathSeparator}photo.jpg');
    await source.writeAsBytes(
      List<int>.generate(100000, (index) => index % 251),
    );
    final service = QuickTransferService(chunkSize: 1024);
    final manifest = await service.publish(
      source,
      Directory('${root.path}/inbox'),
      senderDevice: 'windows',
      targetDevice: 'android',
    );
    expect(manifest.size, 100000);
    expect(manifest.sha256, isNotEmpty);
    expect(manifest.senderDevice, 'windows');
    expect(manifest.targetDevice, 'android');
    final claimed = manifest.copyWith(
      claimedAt: DateTime.utc(2026, 8, 12),
      claimedBy: 'android',
    );
    expect(claimed.isClaimed, isTrue);
    expect(claimed.claimedBy, 'android');
    expect(QuickTransferManifest.fromJson(claimed.toJson()).isClaimed, isTrue);
    final target = File('${root.path}/received.jpg');
    await service.receive(manifest, Directory('${root.path}/inbox'), target);
    expect(await target.readAsBytes(), await source.readAsBytes());
  });

  test('http receiver publishes only after PUT completes', () async {
    final root = await Directory.systemTemp.createTemp('jet2drop-http-');
    addTearDown(() => root.delete(recursive: true));
    final receiver = QuickTransferHttpReceiver(
      packageDir: Directory('${root.path}/inbox'),
    );
    await receiver.start(address: InternetAddress.loopbackIPv4);
    addTearDown(receiver.close);
    final client = HttpClient();
    final request = await client.put(
      InternetAddress.loopbackIPv4.host,
      receiver.port,
      '/v1/${receiver.token}/abc',
    );
    request.headers.set('x-file-name', 'hello.txt');
    request.add([1, 2, 3, 4]);
    final response = await request.close();
    expect(response.statusCode, HttpStatus.created);
    final payload = File('${root.path}/inbox/abc.bin');
    expect(await payload.readAsBytes(), [1, 2, 3, 4]);
    client.close();
  });

  test('local repository uploads atomically and downloads bytes', () async {
    final root = await Directory.systemTemp.createTemp('jet2drop-repo-');
    addTearDown(() => root.delete(recursive: true));
    final gateway = LocalRepositoryGateway(root.path);
    await gateway.initialize();
    final source = File('${root.path}/source.bin');
    await source.writeAsBytes([10, 20, 30, 40]);
    await File('${root.path}/100%进度.txt').writeAsString('ok');
    final rootEntries = await gateway.listDirectory('');
    expect(rootEntries.any((entry) => entry.name == '100%进度.txt'), isTrue);
    await gateway.createDirectory('', 'docs');
    await gateway.uploadFile(
      source: source,
      targetDirectory: 'docs',
      targetName: 'report.bin',
      overwrite: false,
    );
    expect((await gateway.listDirectory('docs')).single.name, 'report.bin');
    final target = File('${root.path}/downloaded.bin');
    await gateway.downloadFile(remotePath: 'docs/report.bin', target: target);
    expect(await target.readAsBytes(), [10, 20, 30, 40]);
    await expectLater(
      () => gateway.uploadFile(
        source: source,
        targetDirectory: 'docs',
        targetName: 'report.bin',
        overwrite: false,
      ),
      throwsA(isA<FileSystemException>()),
    );
    await gateway.deleteEntry('docs/report.bin', recursive: false);
    expect(await File('${root.path}/docs/report.bin').exists(), isFalse);
    await gateway.deleteEntry('docs', recursive: true);
    expect(await Directory('${root.path}/docs').exists(), isFalse);
    await expectLater(
      () => gateway.deleteEntry('', recursive: true),
      throwsArgumentError,
    );
    expect(() => gateway.listDirectory('../outside'), throwsArgumentError);
  });

  test(
    'serialized gateway preserves operations after a failed request',
    () async {
      final root = await Directory.systemTemp.createTemp('jet2drop-serial-');
      addTearDown(() => root.delete(recursive: true));
      final gateway = SerializedRepositoryGateway(
        LocalRepositoryGateway(root.path),
      );
      await gateway.initialize();
      await expectLater(
        () => gateway.deleteEntry('missing.bin', recursive: false),
        throwsA(isA<FileSystemException>()),
      );
      await gateway.createDirectory('', 'after-failure');
      expect((await gateway.listDirectory('')).single.name, 'after-failure');
    },
  );
}
