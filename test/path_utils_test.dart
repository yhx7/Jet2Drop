import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:crypto/crypto.dart';
import 'package:jet2drop/core/path_utils.dart';
import 'package:jet2drop/core/quick_transfer.dart';
import 'package:jet2drop/core/connection_retry.dart';
import 'package:jet2drop/core/transfer_control.dart';
import 'package:jet2drop/infrastructure/local_repository_gateway.dart';
import 'package:jet2drop/infrastructure/serialized_repository_gateway.dart';

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
    String? downloadedChecksum;
    await gateway.downloadFile(
      remotePath: 'docs/report.bin',
      target: target,
      onChecksum: (value) => downloadedChecksum = value,
    );
    expect(await target.readAsBytes(), [10, 20, 30, 40]);
    expect(downloadedChecksum, sha256.convert([10, 20, 30, 40]).toString());
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

  test('resumed download checksum covers the bytes already on disk', () async {
    final root = await Directory.systemTemp.createTemp('jet2drop-resume-hash-');
    addTearDown(() => root.delete(recursive: true));
    final gateway = LocalRepositoryGateway(root.path);
    await gateway.initialize();
    addTearDown(gateway.dispose);
    await File(
      '${root.path}${Platform.pathSeparator}source.bin',
    ).writeAsBytes([1, 2, 3, 4]);
    final target = File('${root.path}${Platform.pathSeparator}target.bin');
    const resumeId = 'resume-checksum';
    await File(
      '${target.path}.jet2drop-download-$resumeId.part',
    ).writeAsBytes([9, 9]);
    String? checksum;

    await gateway.downloadFile(
      remotePath: 'source.bin',
      target: target,
      resumeId: resumeId,
      onChecksum: (value) => checksum = value,
    );

    expect(await target.readAsBytes(), [9, 9, 3, 4]);
    expect(checksum, sha256.convert([9, 9, 3, 4]).toString());
    expect(checksum, isNot(sha256.convert([1, 2, 3, 4]).toString()));
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

  test(
    'connection retry resets only before retrying failed operations',
    () async {
      var attempts = 0;
      var resets = 0;
      final retry = ConnectionRetry(
        resetConnection: () async => resets++,
        delayForAttempt: (_) => Duration.zero,
        isRecoverable: (_) => true,
      );
      final result = await retry.run(() async {
        attempts++;
        if (attempts < 3) throw StateError('temporary connection failure');
        return 'connected';
      });
      expect(result, 'connected');
      expect(attempts, 3);
      expect(resets, 2);
    },
  );

  test('connection retry does not repeat a cancelled transfer', () async {
    var attempts = 0;
    final retry = ConnectionRetry(
      resetConnection: () async {},
      delayForAttempt: (_) => Duration.zero,
    );
    await expectLater(
      () => retry.run<void>(() async {
        attempts++;
        throw const TransferCancelled();
      }),
      throwsA(isA<TransferCancelled>()),
    );
    expect(attempts, 1);
  });

  test('deferred transfer yields without becoming cancelled', () async {
    var aborted = false;
    final control = TransferControl();
    control.bind(onCancel: () async => aborted = true);
    await control.defer();
    expect(aborted, isTrue);
    expect(control.isDeferred, isTrue);
    expect(control.isCancelled, isFalse);
    await expectLater(control.checkpoint, throwsA(isA<TransferDeferred>()));
  });

  test('connection retry does not repeat permanent failures', () async {
    var attempts = 0;
    var resets = 0;
    final retry = ConnectionRetry(
      resetConnection: () async => resets++,
      delayForAttempt: (_) => Duration.zero,
    );
    await expectLater(
      () => retry.run<void>(() async {
        attempts++;
        throw StateError('A file with the same name already exists.');
      }),
      throwsStateError,
    );
    expect(attempts, 1);
    expect(resets, 0);
  });

  test('local upload resumes a stable partial file', () async {
    final root = await Directory.systemTemp.createTemp('jet2drop-resume-');
    addTearDown(() => root.delete(recursive: true));
    final gateway = LocalRepositoryGateway(root.path);
    await gateway.initialize();
    final bytes = List<int>.generate(128 * 1024, (index) => index % 251);
    final source = File('${root.path}${Platform.pathSeparator}source.bin');
    await source.writeAsBytes(bytes);
    final partial = File(
      '${root.path}${Platform.pathSeparator}result.bin.jet2drop-upload-resume-1.part',
    );
    await partial.writeAsBytes(bytes.take(8192).toList());
    var firstProgress = -1;
    String? uploadedChecksum;
    await gateway.uploadFile(
      source: source,
      targetDirectory: '',
      targetName: 'result.bin',
      overwrite: true,
      resumeId: 'resume-1',
      onProgress: (current, _) {
        if (firstProgress < 0) firstProgress = current;
      },
      onChecksum: (value) => uploadedChecksum = value,
    );
    expect(firstProgress, 8192);
    expect(uploadedChecksum, sha256.convert(bytes).toString());
    expect(
      await File(
        '${root.path}${Platform.pathSeparator}result.bin',
      ).readAsBytes(),
      bytes,
    );
    expect(await partial.exists(), isFalse);
  });

  test('deferring an upload preserves its partial for the next task', () async {
    final root = await Directory.systemTemp.createTemp('jet2drop-yield-');
    addTearDown(() => root.delete(recursive: true));
    final gateway = LocalRepositoryGateway(root.path);
    await gateway.initialize();
    final bytes = List<int>.generate(256 * 1024, (index) => index % 251);
    final source = File('${root.path}${Platform.pathSeparator}source.bin');
    await source.writeAsBytes(bytes);
    final control = TransferControl();
    var requested = false;
    await expectLater(
      () => gateway.uploadFile(
        source: source,
        targetDirectory: '',
        targetName: 'result.bin',
        overwrite: true,
        resumeId: 'yield-1',
        control: control,
        onProgress: (current, _) {
          if (!requested && current > 0) {
            requested = true;
            unawaited(control.defer());
          }
        },
      ),
      throwsA(isA<TransferDeferred>()),
    );
    final partial = File(
      '${root.path}${Platform.pathSeparator}result.bin.jet2drop-upload-yield-1.part',
    );
    final partialSize = await partial.length();
    expect(partialSize, greaterThan(0));
    var resumedAt = -1;
    await gateway.uploadFile(
      source: source,
      targetDirectory: '',
      targetName: 'result.bin',
      overwrite: true,
      resumeId: 'yield-1',
      onProgress: (current, _) {
        if (resumedAt < 0) resumedAt = current;
      },
    );
    expect(resumedAt, partialSize);
    expect(
      await File(
        '${root.path}${Platform.pathSeparator}result.bin',
      ).readAsBytes(),
      bytes,
    );
  });

  test('temporary recovery restores backups and removes stale parts', () async {
    final root = await Directory.systemTemp.createTemp('jet2drop-recovery-');
    addTearDown(() => root.delete(recursive: true));
    final gateway = LocalRepositoryGateway(root.path);
    await gateway.initialize();
    final backup = File(
      '${root.path}${Platform.pathSeparator}important.txt.jet2drop-backup-test',
    );
    await backup.writeAsString('preserved');
    final stale = File(
      '${root.path}${Platform.pathSeparator}orphan.bin.jet2drop-upload-test.part',
    );
    await stale.writeAsBytes([1, 2, 3]);
    await stale.setLastModified(
      DateTime.now().subtract(const Duration(days: 8)),
    );
    await gateway.recoverTemporaryFiles('');
    expect(
      await File(
        '${root.path}${Platform.pathSeparator}important.txt',
      ).readAsString(),
      'preserved',
    );
    expect(await backup.exists(), isFalse);
    expect(await stale.exists(), isFalse);
  });

  test(
    'local overwrite replaces bytes without leaving upload fragments',
    () async {
      final root = await Directory.systemTemp.createTemp('jet2drop-overwrite-');
      addTearDown(() => root.delete(recursive: true));
      final gateway = LocalRepositoryGateway(root.path);
      await gateway.initialize();
      final first = File('${root.path}${Platform.pathSeparator}first.bin');
      final second = File('${root.path}${Platform.pathSeparator}second.bin');
      await first.writeAsBytes([1, 2, 3]);
      await second.writeAsBytes([4, 5, 6, 7]);
      await gateway.uploadFile(
        source: first,
        targetDirectory: '',
        targetName: 'same.bin',
        overwrite: true,
      );
      await gateway.uploadFile(
        source: second,
        targetDirectory: '',
        targetName: 'same.bin',
        overwrite: true,
      );
      expect(
        await File(
          '${root.path}${Platform.pathSeparator}same.bin',
        ).readAsBytes(),
        [4, 5, 6, 7],
      );
      expect(
        (await gateway.listDirectory(
          '',
        )).any((entry) => entry.name.contains('.jet2drop-upload-')),
        isFalse,
      );
    },
  );

  test('cancelled local upload cleans its temporary file', () async {
    final root = await Directory.systemTemp.createTemp('jet2drop-cancel-');
    addTearDown(() => root.delete(recursive: true));
    final gateway = LocalRepositoryGateway(root.path);
    await gateway.initialize();
    final source = File('${root.path}${Platform.pathSeparator}source.bin');
    await source.writeAsBytes(List<int>.filled(64 * 1024, 9));
    final control = TransferControl();
    await control.cancel();
    await expectLater(
      () => gateway.uploadFile(
        source: source,
        targetDirectory: '',
        targetName: 'cancelled.bin',
        overwrite: true,
        control: control,
      ),
      throwsA(isA<TransferCancelled>()),
    );
    expect(
      (await gateway.listDirectory(
        '',
      )).any((entry) => entry.name.contains('.jet2drop-upload-')),
      isFalse,
    );
    expect(
      await File('${root.path}${Platform.pathSeparator}cancelled.bin').exists(),
      isFalse,
    );
  });

  test(
    'quick transfer cleanup removes expired payloads and manifests',
    () async {
      final root = await Directory.systemTemp.createTemp('jet2drop-cleanup-');
      addTearDown(() => root.delete(recursive: true));
      final package = Directory('${root.path}${Platform.pathSeparator}inbox');
      await package.create();
      const id = 'expired-message';
      final expired = QuickTransferManifest(
        id: id,
        name: 'expired.txt',
        size: 3,
        sha256: 'unused',
        createdAt: DateTime.utc(2020),
        expiresAt: DateTime.utc(2020, 1, 2),
        chunkSize: 3,
      );
      await File(
        '${package.path}${Platform.pathSeparator}$id.json',
      ).writeAsString(jsonEncode(expired.toJson()));
      await File(
        '${package.path}${Platform.pathSeparator}$id.bin',
      ).writeAsBytes([1, 2, 3]);
      await QuickTransferService().cleanup(package);
      expect(
        await File('${package.path}${Platform.pathSeparator}$id.json').exists(),
        isFalse,
      );
      expect(
        await File('${package.path}${Platform.pathSeparator}$id.bin').exists(),
        isFalse,
      );
    },
  );

  group('sanitizeTransferFileName', () {
    test('replaces characters rejected by Windows and path separators', () {
      expect(sanitizeTransferFileName('a<b>:c/\\d?.jpg'), 'a_b__c__d_.jpg');
    });

    test('protects reserved Windows device names', () {
      expect(sanitizeTransferFileName('CON.txt'), '_CON.txt');
      expect(sanitizeTransferFileName('nul'), '_nul');
    });

    test('removes trailing dots and preserves an extension when shortened', () {
      expect(sanitizeTransferFileName('report... '), 'report');
      final result = sanitizeTransferFileName('${'a' * 220}.mp4');
      expect(result.length, 180);
      expect(result, endsWith('.mp4'));
    });
  });
}
