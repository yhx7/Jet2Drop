import 'dart:io';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:jet2drop/core/models/file_entry.dart';
import 'package:jet2drop/core/repository_gateway.dart';
import 'package:jet2drop/core/repository_sync.dart';
import 'package:jet2drop/core/transfer_control.dart';
import 'package:jet2drop/infrastructure/local_repository_gateway.dart';

void main() {
  late Directory root;
  late Directory local;
  late Directory remote;
  late RepositorySyncEngine engine;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('jet2drop-sync-test-');
    local = Directory('${root.path}${Platform.pathSeparator}local');
    remote = Directory('${root.path}${Platform.pathSeparator}remote');
    await local.create();
    await remote.create();
    engine = RepositorySyncEngine(
      localRoot: local,
      remote: LocalRepositoryGateway(remote.path),
      ownerId: 'test-owner',
      trustRemoteManifest: false,
    );
    await engine.remote.initialize();
  });

  tearDown(() async {
    if (await root.exists()) await root.delete(recursive: true);
  });

  test(
    'first pull copies the complete remote repository and baseline',
    () async {
      await File('${remote.path}/a.txt').writeAsString('remote');
      await Directory('${remote.path}/folder').create();
      await File('${remote.path}/folder/b.txt').writeAsString('nested');

      final result = await engine.pull();

      expect(result.applied, isTrue);
      expect(await File('${local.path}/a.txt').readAsString(), 'remote');
      expect(await File('${local.path}/folder/b.txt').readAsString(), 'nested');
      expect((await engine.inspect()).status, RepositorySyncStatus.synced);
      expect(
        (await engine.inspect()).local.keys,
        isNot(contains('.jet2drop_sync')),
      );
    },
  );

  test('incremental pull and push preserve unrelated files', () async {
    await File('${remote.path}/a.txt').writeAsString('one');
    await engine.pull();
    await File('${remote.path}/a.txt').writeAsString('two');
    await File('${local.path}/local.txt').writeAsString('local');

    final pulled = await engine.pull();
    expect(pulled.applied, isTrue);
    expect(await File('${local.path}/a.txt').readAsString(), 'two');
    expect(await File('${local.path}/local.txt').readAsString(), 'local');

    await File('${local.path}/a.txt').writeAsString('three');
    final pushed = await engine.push();
    expect(pushed.applied, isTrue);
    expect(await File('${remote.path}/a.txt').readAsString(), 'three');
  });

  test(
    'pushing a new directory with files keeps the published children',
    () async {
      await engine.pull();
      await Directory('${local.path}/folder/empty').create(recursive: true);
      await File('${local.path}/folder/a.txt').writeAsString('child');

      expect((await engine.push()).applied, isTrue);
      expect(await File('${remote.path}/folder/a.txt').readAsString(), 'child');
      expect(await Directory('${remote.path}/folder/empty').exists(), isTrue);
    },
  );

  test('push publishes replacements before deleting old paths', () async {
    await File('${remote.path}/old.txt').writeAsString('old');
    await engine.pull();
    await File('${local.path}/old.txt').delete();
    await File('${local.path}/new.txt').writeAsString('new');

    expect((await engine.push()).applied, isTrue);
    expect(await File('${remote.path}/new.txt').readAsString(), 'new');
    expect(await File('${remote.path}/old.txt').exists(), isFalse);
  });

  test(
    'a manual direction does not consume changes from the other side',
    () async {
      await File('${remote.path}/a.txt').writeAsString('base');
      await engine.pull();
      await File('${remote.path}/a.txt').writeAsString('remote-only');

      final wrongDirection = await engine.push();
      expect(wrongDirection.applied, isFalse);
      expect(await File('${local.path}/a.txt').readAsString(), 'base');
      expect((await engine.inspect()).status, RepositorySyncStatus.changed);

      expect((await engine.pull()).applied, isTrue);
      expect(await File('${local.path}/a.txt').readAsString(), 'remote-only');
    },
  );

  test('conflicts are reported without overwriting either side', () async {
    await File('${remote.path}/a.txt').writeAsString('base');
    await engine.pull();
    await File('${remote.path}/a.txt').writeAsString('remote change');
    await File('${local.path}/a.txt').writeAsString('local change');

    final result = await engine.pull();

    expect(result.applied, isFalse);
    expect(result.conflicts.single.path, 'a.txt');
    expect(
      (await engine.inspect()).status,
      RepositorySyncStatus.needsAttention,
    );
    expect(await File('${local.path}/a.txt').readAsString(), 'local change');
    expect(await File('${remote.path}/a.txt').readAsString(), 'remote change');
  });

  test(
    'same resulting bytes changed on both sides still require attention',
    () async {
      await File('${remote.path}/a.txt').writeAsString('base');
      await engine.pull();
      await File('${remote.path}/a.txt').writeAsString('same edit');
      await File('${local.path}/a.txt').writeAsString('same edit');

      final result = await engine.push();
      expect(result.applied, isFalse);
      expect(
        result.conflicts.single.type,
        RepositorySyncConflictType.modifiedModified,
      );
    },
  );

  test('deletions are applied last and excluded paths are untouched', () async {
    await File('${remote.path}/a.txt').writeAsString('base');
    await File('${remote.path}/ignored.part').writeAsString('remote temp');
    await Directory('${remote.path}/__jet2drop_sync').create();
    await File('${remote.path}/__jet2drop_sync/foreign').writeAsString('meta');
    await engine.pull();
    await File('${local.path}/a.txt').delete();
    await File('${remote.path}/a.txt').writeAsString('new');
    final result = await engine.pull();
    expect(
      result.conflicts.single.type,
      RepositorySyncConflictType.deletedModified,
    );
    expect(
      await File('${remote.path}/__jet2drop_sync/foreign').readAsString(),
      'meta',
    );
    expect(await File('${local.path}/ignored.part').exists(), isFalse);
  });

  test('manifest corruption is recoverable', () async {
    await File('${remote.path}/a.txt').writeAsString('base');
    await engine.pull();
    final baseline = File('${local.path}/.jet2drop_sync/baseline.json');
    await baseline.writeAsString('{broken');
    final snapshot = await engine.inspect();
    expect(snapshot.status, isNot(RepositorySyncStatus.synced));
    expect(
      (await Directory(
        '${local.path}/.jet2drop_sync',
      ).list().toList()).any((entity) => entity.path.contains('.corrupt-')),
      isTrue,
    );
  });

  test(
    'no changes become a stable synced state and baseline survives restart',
    () async {
      await File('${remote.path}/a.txt').writeAsString('same');
      await engine.pull();
      final second = RepositorySyncEngine(
        localRoot: local,
        remote: LocalRepositoryGateway(remote.path),
        ownerId: 'restarted-owner',
        trustRemoteManifest: false,
      );
      await second.remote.initialize();
      expect((await second.inspect()).status, RepositorySyncStatus.synced);
      final result = await second.push();
      expect(result.applied, isTrue);
      expect(result.changedPaths, isEmpty);
    },
  );

  test('modified local versus deleted remote is a conflict', () async {
    await File('${remote.path}/a.txt').writeAsString('base');
    await engine.pull();
    await File('${local.path}/a.txt').writeAsString('local');
    await File('${remote.path}/a.txt').delete();
    final result = await engine.push();
    expect(result.applied, isFalse);
    expect(
      result.conflicts.single.type,
      RepositorySyncConflictType.modifiedDeleted,
    );
    expect(await File('${local.path}/a.txt').readAsString(), 'local');
  });

  test('file and directory changes at one path are a conflict', () async {
    await File('${remote.path}/a.txt').writeAsString('base');
    await engine.pull();
    await File('${local.path}/a.txt').delete();
    await Directory('${local.path}/a.txt').create();
    await File('${local.path}/a.txt/nested').writeAsString('local');
    final result = await engine.push();
    expect(result.applied, isFalse);
    expect(
      result.conflicts.single.type,
      RepositorySyncConflictType.typeChanged,
    );
  });

  test('a failed commit restores formal remote files', () async {
    final failingRemote = _FailingMoveGateway(remote.path, failOnMove: 2);
    engine = RepositorySyncEngine(
      localRoot: local,
      remote: failingRemote,
      ownerId: 'failing-owner',
      trustRemoteManifest: false,
    );
    await failingRemote.initialize();
    await File('${remote.path}/a.txt').writeAsString('base-a');
    await File('${remote.path}/b.txt').writeAsString('base-b');
    await engine.pull();
    await File('${local.path}/a.txt').writeAsString('local-a');
    await File('${local.path}/b.txt').writeAsString('local-b');
    await expectLater(engine.push(), throwsA(isA<Exception>()));
    expect(await File('${remote.path}/a.txt').readAsString(), 'base-a');
    expect(await File('${remote.path}/b.txt').readAsString(), 'base-b');
  });

  test(
    'active locks block a commit and stale locks can be reclaimed',
    () async {
      await File('${remote.path}/a.txt').writeAsString('base');
      await engine.pull();
      await File('${remote.path}/a.txt').writeAsString('remote');
      final lockDirectory = Directory('${remote.path}/__jet2drop_sync');
      await lockDirectory.create(recursive: true);
      final lock = File('${lockDirectory.path}/lock.json');
      await lock.writeAsString(
        jsonEncode({
          'owner': 'other-device',
          'timestamp': DateTime.now().toUtc().millisecondsSinceEpoch,
        }),
      );

      await expectLater(engine.pull(), throwsA(isA<RepositorySyncException>()));
      expect(await File('${local.path}/a.txt').readAsString(), 'base');

      await lock.writeAsString(
        jsonEncode({
          'owner': 'other-device',
          'timestamp': DateTime.now()
              .subtract(const Duration(hours: 1))
              .toUtc()
              .millisecondsSinceEpoch,
        }),
      );
      expect((await engine.pull()).applied, isTrue);
      expect(await File('${local.path}/a.txt').readAsString(), 'remote');
    },
  );

  test('a remote change during staging fails the version check', () async {
    await File('${remote.path}/a.txt').writeAsString('base');
    final competing = _CompetingGateway(remote.path);
    engine = RepositorySyncEngine(
      localRoot: local,
      remote: competing,
      ownerId: 'competing-owner',
      trustRemoteManifest: false,
    );
    await competing.initialize();
    await engine.pull();
    await File('${local.path}/a.txt').writeAsString('local');

    await expectLater(
      engine.push(),
      throwsA(isA<RepositorySyncVersionException>()),
    );
    expect(await File('${local.path}/a.txt').readAsString(), 'local');
    expect(await File('${remote.path}/a.txt').readAsString(), 'competitor');
  });

  test('manifest encoding is compact and malformed entries are rejected', () {
    final manifest = RepositorySyncManifest(
      revision: 7,
      createdAt: DateTime.utc(2026, 1, 2),
      entries: {
        'a.txt': RepositorySyncEntry(
          path: 'a.txt',
          type: FileEntryType.file,
          size: 3,
          modifiedAt: DateTime.utc(2026, 1, 2),
          sha256: 'a' * 64,
        ),
      },
    );
    final decoded = RepositorySyncManifest.decode(manifest.encode());
    expect(decoded.revision, 7);
    expect(decoded.entries['a.txt']?.sha256, 'a' * 64);
    expect(
      () => RepositorySyncManifest.decode(
        '{"v":1,"r":0,"t":0,"e":[{"p":"a","t":"f","s":0,"m":0,"h":"bad"}]}',
      ),
      throwsFormatException,
    );
  });
}

class _FailingMoveGateway extends LocalRepositoryGateway {
  _FailingMoveGateway(super.rootPath, {required this.failOnMove});

  final int failOnMove;
  var moveCount = 0;

  @override
  Future<void> moveEntry(
    String sourcePath,
    String targetPath, {
    bool overwrite = false,
  }) {
    moveCount++;
    if (moveCount == failOnMove) {
      throw FileSystemException('Injected commit failure.');
    }
    return super.moveEntry(sourcePath, targetPath, overwrite: overwrite);
  }
}

class _CompetingGateway extends LocalRepositoryGateway {
  _CompetingGateway(super.rootPath);

  var _changedFormalFile = false;

  @override
  Future<void> uploadFile({
    required File source,
    required String targetDirectory,
    required String targetName,
    required bool overwrite,
    String? resumeId,
    ProgressCallback? onProgress,
    ChecksumCallback? onChecksum,
    TransferControl? control,
  }) async {
    await super.uploadFile(
      source: source,
      targetDirectory: targetDirectory,
      targetName: targetName,
      overwrite: overwrite,
      resumeId: resumeId,
      onProgress: onProgress,
      onChecksum: onChecksum,
      control: control,
    );
    if (!_changedFormalFile &&
        targetDirectory.contains('__jet2drop_sync/staging/')) {
      _changedFormalFile = true;
      await File('$rootPath/a.txt').writeAsString('competitor');
    }
  }
}
