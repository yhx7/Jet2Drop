import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/services.dart';
import 'package:jet2drop/app_controller.dart';
import 'package:jet2drop/core/models/quick_device.dart';
import 'package:jet2drop/core/models/transfer_task.dart';
import 'package:jet2drop/core/photo_transfer.dart';
import 'package:jet2drop/core/transfer_control.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final pluginData = Directory.systemTemp.createTempSync(
    'jet2drop-test-support-',
  );
  tearDownAll(() async {
    if (await pluginData.exists()) await pluginData.delete(recursive: true);
  });
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(
        const MethodChannel('jet2drop/windows_lifecycle'),
        (_) async => null,
      );
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(
        const MethodChannel('plugins.flutter.io/path_provider'),
        (_) async => pluginData.path,
      );

  Future<AppController> createController(Directory repository) async {
    SharedPreferences.setMockInitialValues({
      'repository_mode': RepositoryMode.local.name,
      'local_root': repository.path,
    });
    final controller = AppController();
    await controller.initialize();
    await Future<void>.delayed(const Duration(milliseconds: 50));
    return controller;
  }

  test('download is complete only after its final save succeeds', () async {
    final root = await Directory.systemTemp.createTemp('jet2drop-controller-');
    addTearDown(() => root.delete(recursive: true));
    final repository = Directory('${root.path}${Platform.pathSeparator}repo');
    await repository.create();
    await File(
      '${repository.path}${Platform.pathSeparator}source.bin',
    ).writeAsBytes([1, 2, 3, 4]);
    final controller = await createController(repository);
    addTearDown(controller.dispose);
    if (controller.entries.isEmpty) {
      throw StateError(
        'controller initialization failed: ${controller.error}; quick=${controller.quickError}',
      );
    }
    final entry = controller.entries.singleWhere(
      (item) => item.name == 'source.bin',
    );
    final target = File('${root.path}${Platform.pathSeparator}target.bin');
    var saves = 0;

    await expectLater(
      () => controller.downloadFile(
        entry,
        target,
        finalize: (_) async {
          saves++;
          if (saves == 1) throw StateError('save destination unavailable');
        },
      ),
      throwsStateError,
    );
    final task = controller.tasks.single;
    expect(task.status, TransferStatus.failed);
    expect(await target.readAsBytes(), [1, 2, 3, 4]);

    await controller.retryTask(task);
    expect(task.status, TransferStatus.completed);
    expect(saves, 2);
  });

  test(
    'quick receive directory is persisted and changed without fallback',
    () async {
      final root = await Directory.systemTemp.createTemp('jet2drop-save-dir-');
      addTearDown(() => root.delete(recursive: true));
      final repository = Directory('${root.path}${Platform.pathSeparator}repo');
      final firstSave = Directory(
        '${root.path}${Platform.pathSeparator}first-save',
      );
      final secondSave = Directory(
        '${root.path}${Platform.pathSeparator}second-save',
      );
      await repository.create();
      await firstSave.create();
      await secondSave.create();
      final controller = await createController(repository);
      addTearDown(controller.dispose);

      expect(controller.defaultQuickSaveDirectory, isNull);
      await controller.setDefaultQuickSaveDirectory(firstSave.path);
      expect(controller.defaultQuickSaveDirectory, firstSave.path);
      final firstTarget = await controller.defaultQuickReceiveTarget('照片.jpg');
      expect(firstTarget.parent.path, firstSave.path);
      final concurrentTarget = await controller.defaultQuickReceiveTarget(
        '照片.jpg',
      );
      expect(concurrentTarget.path, isNot(firstTarget.path));
      expect(concurrentTarget.uri.pathSegments.last, '照片 (2).jpg');
      final preferences = await SharedPreferences.getInstance();
      expect(preferences.getString('quick_save_directory'), firstSave.path);

      await controller.setDefaultQuickSaveDirectory(secondSave.path);
      expect(controller.defaultQuickSaveDirectory, secondSave.path);
      // A task that already resolved its target keeps its original directory.
      expect(firstTarget.parent.path, firstSave.path);
      final secondTarget = await controller.defaultQuickReceiveTarget('照片.jpg');
      expect(secondTarget.parent.path, secondSave.path);
    },
  );

  test(
    'quick receive directory rejects missing and non-writable targets',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'jet2drop-save-invalid-',
      );
      addTearDown(() => root.delete(recursive: true));
      final repository = Directory('${root.path}${Platform.pathSeparator}repo');
      await repository.create();
      final controller = await createController(repository);
      addTearDown(controller.dispose);
      final missing = '${root.path}${Platform.pathSeparator}missing';
      await expectLater(
        () => controller.setDefaultQuickSaveDirectory(missing),
        throwsStateError,
      );
      final file = File('${root.path}${Platform.pathSeparator}not-a-folder');
      await file.writeAsString('x');
      await expectLater(
        () => controller.setDefaultQuickSaveDirectory(file.path),
        throwsStateError,
      );
    },
  );

  test('sanitized duplicate selections never overwrite one another', () async {
    final root = await Directory.systemTemp.createTemp('jet2drop-names-');
    addTearDown(() => root.delete(recursive: true));
    final repository = Directory('${root.path}${Platform.pathSeparator}repo');
    await repository.create();
    final firstDirectory = Directory(
      '${root.path}${Platform.pathSeparator}first',
    );
    final secondDirectory = Directory(
      '${root.path}${Platform.pathSeparator}second',
    );
    await firstDirectory.create();
    await secondDirectory.create();
    final first = File('${firstDirectory.path}${Platform.pathSeparator}A.txt');
    final second = File(
      '${secondDirectory.path}${Platform.pathSeparator}a.txt',
    );
    await first.writeAsString('first');
    await second.writeAsString('second');
    final controller = await createController(repository);
    addTearDown(controller.dispose);

    await controller.uploadFiles([first, second], overwrite: true);

    expect(
      await File(
        '${repository.path}${Platform.pathSeparator}A.txt',
      ).readAsString(),
      'first',
    );
    expect(
      await File(
        '${repository.path}${Platform.pathSeparator}a (2).txt',
      ).readAsString(),
      'second',
    );
  });

  test('file operation failures remain visible to the caller', () async {
    final root = await Directory.systemTemp.createTemp('jet2drop-errors-');
    addTearDown(() => root.delete(recursive: true));
    final repository = Directory('${root.path}${Platform.pathSeparator}repo');
    await repository.create();
    final controller = await createController(repository);
    addTearDown(controller.dispose);

    await controller.createDirectory('existing');
    await expectLater(
      () => controller.createDirectory('existing'),
      throwsA(isA<FileSystemException>()),
    );
  });

  test(
    'a damaged pending record does not discard valid recovery tasks',
    () async {
      final root = await Directory.systemTemp.createTemp('jet2drop-recovery-');
      addTearDown(() => root.delete(recursive: true));
      final repository = Directory('${root.path}${Platform.pathSeparator}repo');
      await repository.create();
      final source = File('${root.path}${Platform.pathSeparator}pending.bin');
      await source.writeAsBytes([1, 2, 3]);
      SharedPreferences.setMockInitialValues({
        'repository_mode': RepositoryMode.local.name,
        'local_root': repository.path,
        'pending_transfers_v1': jsonEncode([
          {
            'kind': 'upload',
            'id': 'valid-task',
            'name': 'pending.bin',
            'totalBytes': 3,
            'sourcePath': source.path,
            'targetDirectory': '',
            'overwrite': true,
            'ownedSource': false,
          },
          {'kind': 'download', 'id': 'damaged-task'},
        ]),
      });
      final controller = AppController();
      await controller.initialize();
      addTearDown(controller.dispose);

      expect(controller.tasks.map((task) => task.id), ['valid-task']);
      expect(controller.canRetryTask(controller.tasks.single), isTrue);
      final preferences = await SharedPreferences.getInstance();
      expect(
        preferences.getString('pending_transfers_v1'),
        isNot(contains('damaged-task')),
      );
    },
  );

  test('quick inbox refresh stays quiet while a send is active', () async {
    final root = await Directory.systemTemp.createTemp('jet2drop-quick-flow-');
    addTearDown(() => root.delete(recursive: true));
    final repository = Directory('${root.path}${Platform.pathSeparator}repo');
    await repository.create();
    final source = File('${root.path}${Platform.pathSeparator}payload.bin');
    final writer = await source.open(mode: FileMode.write);
    await writer.truncate(8 * 1024 * 1024);
    await writer.close();
    final controller = await createController(repository);
    addTearDown(controller.dispose);
    controller.quickDevices = [
      QuickDevice(id: 'target-device', name: '目标设备', updatedAt: DateTime.now()),
    ];

    final send = controller.publishQuickTransfer(
      source,
      targetDevice: 'target-device',
    );
    for (var attempt = 0; attempt < 200; attempt++) {
      if (controller.hasActiveTransfers) break;
      await Future<void>.delayed(const Duration(milliseconds: 2));
    }
    expect(controller.hasActiveTransfers, isTrue);

    for (var attempt = 0; attempt < 5; attempt++) {
      await controller.refreshQuickTransfer(refreshDevices: true);
    }
    final manifest = await send.timeout(const Duration(seconds: 30));
    await controller.refreshQuickTransfer(refreshDevices: true);

    expect(controller.quickError, isNull);
    expect(controller.quickInbox.map((item) => item.id), contains(manifest.id));
    expect(
      controller.tasks.singleWhere((task) => task.id == manifest.id).status,
      TransferStatus.completed,
    );
  });

  test('repository flow works from create through delete', () async {
    final root = await Directory.systemTemp.createTemp('jet2drop-repo-flow-');
    addTearDown(() => root.delete(recursive: true));
    final repository = Directory('${root.path}${Platform.pathSeparator}repo');
    await repository.create();
    final source = File('${root.path}${Platform.pathSeparator}source.txt');
    await source.writeAsString('real flow payload');
    final controller = await createController(repository);
    addTearDown(controller.dispose);

    await controller.createDirectory('工作资料');
    final folder = controller.entries.singleWhere(
      (entry) => entry.name == '工作资料',
    );
    await controller.open(folder);
    expect(controller.currentPath, '工作资料');

    await controller.uploadFiles([source], overwrite: false);
    final uploaded = controller.entries.singleWhere(
      (entry) => entry.name == 'source.txt',
    );
    expect(controller.tasks.single.status, TransferStatus.completed);

    final preview = await controller.previewFile(uploaded);
    expect(await preview.readAsString(), 'real flow payload');
    await controller.releasePreview(preview);
    final downloaded = File(
      '${root.path}${Platform.pathSeparator}downloaded.txt',
    );
    await controller.downloadFile(uploaded, downloaded);
    expect(await downloaded.readAsString(), 'real flow payload');

    await controller.goUp();
    expect(controller.currentPath, isEmpty);
    await controller.deleteEntry(folder);
    expect(controller.entries.any((entry) => entry.name == '工作资料'), isFalse);
  });

  test('same-name choices preserve the requested result', () async {
    final root = await Directory.systemTemp.createTemp('jet2drop-conflict-');
    addTearDown(() => root.delete(recursive: true));
    final repository = Directory('${root.path}${Platform.pathSeparator}repo');
    await repository.create();
    await File(
      '${repository.path}${Platform.pathSeparator}note.txt',
    ).writeAsString('old');
    final source = File('${root.path}${Platform.pathSeparator}note.txt');
    await source.writeAsString('new');
    final controller = await createController(repository);
    addTearDown(controller.dispose);

    await controller.uploadFiles([source], overwrite: false, keepBoth: true);
    expect(
      await File(
        '${repository.path}${Platform.pathSeparator}note.txt',
      ).readAsString(),
      'old',
    );
    expect(
      await File(
        '${repository.path}${Platform.pathSeparator}note (2).txt',
      ).readAsString(),
      'new',
    );
  });

  test(
    'multiple uploads settle independently and leave no active state',
    () async {
      final root = await Directory.systemTemp.createTemp('jet2drop-multi-');
      addTearDown(() => root.delete(recursive: true));
      final repository = Directory('${root.path}${Platform.pathSeparator}repo');
      await repository.create();
      final first = File('${root.path}${Platform.pathSeparator}first.bin');
      final second = File('${root.path}${Platform.pathSeparator}second.bin');
      await first.writeAsBytes(List<int>.filled(64 * 1024, 1));
      await second.writeAsBytes(List<int>.filled(96 * 1024, 2));
      final controller = await createController(repository);
      addTearDown(controller.dispose);

      await controller.uploadFiles([first, second], overwrite: false);

      expect(controller.tasks, hasLength(2));
      expect(
        controller.tasks.every(
          (task) => task.status == TransferStatus.completed,
        ),
        isTrue,
      );
      expect(controller.hasActiveTransfers, isFalse);
      expect(
        await File(
          '${repository.path}${Platform.pathSeparator}first.bin',
        ).length(),
        64 * 1024,
      );
      expect(
        await File(
          '${repository.path}${Platform.pathSeparator}second.bin',
        ).length(),
        96 * 1024,
      );
    },
  );

  test('sorting, theme and finished-task cleanup behave immediately', () async {
    final root = await Directory.systemTemp.createTemp('jet2drop-state-flow-');
    addTearDown(() => root.delete(recursive: true));
    final repository = Directory('${root.path}${Platform.pathSeparator}repo');
    await repository.create();
    await File(
      '${repository.path}${Platform.pathSeparator}b.txt',
    ).writeAsString('bb');
    await File(
      '${repository.path}${Platform.pathSeparator}a.txt',
    ).writeAsString('a');
    final controller = await createController(repository);
    addTearDown(controller.dispose);

    await controller.setSort(FileSortField.size, ascending: false);
    expect(controller.sortedEntries.map((entry) => entry.name), [
      'b.txt',
      'a.txt',
    ]);
    final oldTheme = controller.isDarkTheme;
    await controller.toggleTheme();
    expect(controller.isDarkTheme, isNot(oldTheme));

    final target = File('${root.path}${Platform.pathSeparator}copy.txt');
    await controller.downloadFile(
      controller.entries.singleWhere((entry) => entry.name == 'a.txt'),
      target,
    );
    expect(controller.tasks, isNotEmpty);
    await controller.clearFinishedTasks();
    expect(controller.tasks, isEmpty);
  });

  test(
    'selection limits reject missing, excessive-count and oversized input',
    () async {
      final root = await Directory.systemTemp.createTemp('jet2drop-limits-');
      addTearDown(() => root.delete(recursive: true));
      final repository = Directory('${root.path}${Platform.pathSeparator}repo');
      await repository.create();
      final controller = await createController(repository);
      addTearDown(controller.dispose);

      await expectLater(
        () => controller.validateTransferSelection([
          File('${root.path}${Platform.pathSeparator}missing.bin'),
        ]),
        throwsA(isA<FileSystemException>()),
      );
      final tiny = File('${root.path}${Platform.pathSeparator}tiny.bin');
      await tiny.writeAsBytes([1]);
      await expectLater(
        () =>
            controller.validateTransferSelection(List<File>.filled(101, tiny)),
        throwsStateError,
      );
      final huge = File('${root.path}${Platform.pathSeparator}huge.bin');
      final writer = await huge.open(mode: FileMode.write);
      await writer.truncate(10 * 1024 * 1024 * 1024 + 1);
      await writer.close();
      await expectLater(
        () => controller.validateTransferSelection([huge]),
        throwsStateError,
      );
    },
  );

  test('quick transfer can be sent, received, claimed and deleted', () async {
    final root = await Directory.systemTemp.createTemp('jet2drop-quick-e2e-');
    addTearDown(() => root.delete(recursive: true));
    final repository = Directory('${root.path}${Platform.pathSeparator}repo');
    await repository.create();
    final source = File('${root.path}${Platform.pathSeparator}photo.bin');
    await source.writeAsBytes(List<int>.generate(256 * 1024, (i) => i % 251));
    final controller = await createController(repository);
    addTearDown(controller.dispose);
    final senderId = controller.deviceId;
    const targetId = 'target-device';
    controller.quickDevices = [
      QuickDevice(id: targetId, name: '接收设备', updatedAt: DateTime.now()),
    ];

    final manifest = await controller.publishQuickTransfer(
      source,
      targetDevice: targetId,
    );
    controller.deviceId = targetId;
    controller.quickDevices = [
      QuickDevice(id: senderId, name: '发送设备', updatedAt: DateTime.now()),
    ];
    await controller.refreshQuickTransfer(refreshDevices: true);
    final visible = controller.quickInbox.singleWhere(
      (item) => item.id == manifest.id,
    );
    final target = File('${root.path}${Platform.pathSeparator}received.bin');
    await controller.receiveQuickTransfer(visible, target: target);

    expect(await target.readAsBytes(), await source.readAsBytes());
    expect(
      controller.quickInbox
          .singleWhere((item) => item.id == manifest.id)
          .isClaimed,
      isTrue,
    );
    await controller.deleteQuickTransfer(
      controller.quickInbox.singleWhere((item) => item.id == manifest.id),
    );
    expect(
      controller.quickInbox.any((item) => item.id == manifest.id),
      isFalse,
    );
  });

  test(
    'explicit photos use direct receive while other files keep relay flow',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'jet2drop-photo-route-',
      );
      addTearDown(() => root.delete(recursive: true));
      final repository = Directory('${root.path}${Platform.pathSeparator}repo');
      final photos = Directory('${root.path}${Platform.pathSeparator}photos');
      await repository.create();
      await photos.create();
      final server = PhotoTransferServer(
        token: 'photo-route-token',
        bindAddress: InternetAddress.loopbackIPv4,
        endpointHost: InternetAddress.loopbackIPv4.address,
        saveDirectoryProvider: () async => photos.path,
      );
      addTearDown(server.stop);
      expect(await server.start(), isTrue);
      final photo = File('${root.path}${Platform.pathSeparator}original.jpg');
      await photo.writeAsBytes([1, 2, 3, 4]);
      final controller = await HttpOverrides.runWithHttpOverrides(
        () => createController(repository),
        _RealHttpOverrides(),
      );
      addTearDown(controller.dispose);
      controller.quickDevices = [
        QuickDevice(
          id: 'target-device',
          name: '接收设备',
          updatedAt: DateTime.now(),
          photoEndpoint: server.endpoint,
          photoToken: 'photo-route-token',
        ),
      ];

      final direct = await controller.publishQuickTransfer(
        photo,
        targetDevice: 'target-device',
        originalName: '手机原图.jpg',
        mimeType: 'image/jpeg',
        isPhoto: true,
      );
      expect(direct.name, '手机原图.jpg');
      expect(
        await File(
          '${photos.path}${Platform.pathSeparator}手机原图.jpg',
        ).readAsBytes(),
        [1, 2, 3, 4],
      );
      expect(
        Directory(
          '${repository.path}${Platform.pathSeparator}__jet2drop_transfer${Platform.pathSeparator}messages',
        ).listSync(),
        isEmpty,
      );
      final directTask = controller.tasks.singleWhere(
        (task) => task.id == direct.id,
      );
      expect(directTask.status, TransferStatus.completed);
      expect(directTask.supportsPause, isFalse);

      final otherPhoto = File('${root.path}${Platform.pathSeparator}other.jpg');
      await otherPhoto.writeAsBytes([9, 8, 7]);
      final relayed = await controller.publishQuickTransfer(
        otherPhoto,
        targetDevice: 'target-device',
        originalName: 'other.jpg',
        mimeType: 'image/jpeg',
      );
      expect(
        await File(
          '${repository.path}${Platform.pathSeparator}__jet2drop_transfer'
          '${Platform.pathSeparator}messages${Platform.pathSeparator}${relayed.id}'
          '${Platform.pathSeparator}manifest.json',
        ).exists(),
        isTrue,
      );
    },
  );

  test('photo route requires matching image MIME and extension', () async {
    final root = await Directory.systemTemp.createTemp('jet2drop-photo-type-');
    addTearDown(() => root.delete(recursive: true));
    final repository = Directory('${root.path}${Platform.pathSeparator}repo');
    await repository.create();
    final source = File('${root.path}${Platform.pathSeparator}photo.jpg');
    await source.writeAsBytes([1]);
    final controller = await createController(repository);
    addTearDown(controller.dispose);
    controller.quickDevices = [
      QuickDevice(
        id: 'target-device',
        name: '接收设备',
        updatedAt: DateTime.now(),
        photoEndpoint: 'http://127.0.0.1:1',
        photoToken: 'photo-route-token',
      ),
    ];

    await expectLater(
      () => controller.publishQuickTransfer(
        source,
        targetDevice: 'target-device',
        originalName: 'photo.jpg',
        mimeType: 'video/mp4',
        isPhoto: true,
      ),
      throwsStateError,
    );
    expect(controller.tasks, isEmpty);
    expect(
      isSupportedPhotoTransfer(name: 'photo.jpg', mimeType: 'image/jpeg'),
      isTrue,
    );
    expect(
      isSupportedPhotoTransfer(name: 'photo.jpg', mimeType: 'image/png'),
      isFalse,
    );
  });

  test(
    'photo send refreshes a cached disabled receiver before creating a task',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'jet2drop-photo-refresh-',
      );
      addTearDown(() => root.delete(recursive: true));
      final repository = Directory('${root.path}${Platform.pathSeparator}repo');
      final photos = Directory('${root.path}${Platform.pathSeparator}photos');
      await repository.create();
      await photos.create();
      final server = PhotoTransferServer(
        token: 'photo-refresh-token',
        bindAddress: InternetAddress.loopbackIPv4,
        endpointHost: InternetAddress.loopbackIPv4.address,
        saveDirectoryProvider: () async => photos.path,
      );
      addTearDown(server.stop);
      expect(await server.start(), isTrue);
      final targetId = 'target-device';
      final registrationDirectory = Directory(
        '${repository.path}${Platform.pathSeparator}__jet2drop_transfer'
        '${Platform.pathSeparator}devices',
      );
      await registrationDirectory.create(recursive: true);
      final registration = File(
        '${registrationDirectory.path}${Platform.pathSeparator}$targetId.json',
      );
      Future<void> writeRegistration({required bool enabled}) async {
        final device = QuickDevice(
          id: targetId,
          name: '接收设备',
          updatedAt: DateTime.now(),
          photoEndpoint: enabled ? server.endpoint : null,
          photoToken: enabled ? 'photo-refresh-token' : null,
        );
        await registration.writeAsString(jsonEncode(device.toJson()));
      }

      await writeRegistration(enabled: false);
      final photo = File('${root.path}${Platform.pathSeparator}original.jpg');
      await photo.writeAsBytes([1, 2, 3, 4]);
      final controller = await HttpOverrides.runWithHttpOverrides(
        () => createController(repository),
        _RealHttpOverrides(),
      );
      addTearDown(controller.dispose);
      await controller.refreshQuickTransfer(refreshDevices: true);
      expect(
        controller.quickDevices
            .singleWhere((device) => device.id == targetId)
            .supportsPhotoTransfer,
        isFalse,
      );

      await writeRegistration(enabled: true);
      final direct = await controller.publishQuickTransfer(
        photo,
        targetDevice: targetId,
        mimeType: 'image/jpeg',
        isPhoto: true,
      );

      expect(direct.name, 'original.jpg');
      expect(
        await File(
          '${photos.path}${Platform.pathSeparator}original.jpg',
        ).readAsBytes(),
        [1, 2, 3, 4],
      );
      expect(
        controller.tasks.singleWhere((task) => task.id == direct.id).status,
        TransferStatus.completed,
      );
    },
  );

  test(
    'forced device refresh rereads registrations even when mtime is unchanged',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'jet2drop-device-cache-',
      );
      addTearDown(() => root.delete(recursive: true));
      final repository = Directory('${root.path}${Platform.pathSeparator}repo');
      await repository.create();
      final controller = await createController(repository);
      addTearDown(controller.dispose);
      final targetId = 'target-device';
      final registration = File(
        '${repository.path}${Platform.pathSeparator}__jet2drop_transfer'
        '${Platform.pathSeparator}devices${Platform.pathSeparator}$targetId.json',
      );
      Future<void> writeRegistration(bool enabled) async {
        final device = QuickDevice(
          id: targetId,
          name: '接收设备',
          updatedAt: DateTime.now(),
          photoEndpoint: enabled ? 'http://127.0.0.1:1234' : null,
          photoToken: enabled ? 'cache-refresh-token' : null,
        );
        await registration.writeAsString(jsonEncode(device.toJson()));
      }

      await writeRegistration(false);
      await controller.refreshQuickTransfer(refreshDevices: true);
      final originalModified = (await registration.stat()).modified;
      expect(
        controller.quickDevices
            .singleWhere((device) => device.id == targetId)
            .supportsPhotoTransfer,
        isFalse,
      );

      await writeRegistration(true);
      await registration.setLastModified(originalModified);
      await controller.refreshQuickTransfer(refreshDevices: true);
      expect(
        controller.quickDevices
            .singleWhere((device) => device.id == targetId)
            .supportsPhotoTransfer,
        isTrue,
      );
    },
  );

  test(
    'claimed quick records delete once without stale refresh reappearing',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'jet2drop-quick-delete-',
      );
      addTearDown(() => root.delete(recursive: true));
      final repository = Directory('${root.path}${Platform.pathSeparator}repo');
      await repository.create();
      final source = File('${root.path}${Platform.pathSeparator}payload.bin');
      await source.writeAsBytes(List<int>.generate(256 * 1024, (i) => i % 251));
      final controller = await createController(repository);
      addTearDown(controller.dispose);
      final senderId = controller.deviceId;
      const targetId = 'target-device';
      controller.quickDevices = [
        QuickDevice(id: targetId, name: '接收设备', updatedAt: DateTime.now()),
      ];
      final manifest = await controller.publishQuickTransfer(
        source,
        targetDevice: targetId,
      );
      controller.deviceId = targetId;
      controller.quickDevices = [
        QuickDevice(id: senderId, name: '发送设备', updatedAt: DateTime.now()),
      ];
      await controller.refreshQuickTransfer(refreshDevices: true);
      final target = File('${root.path}${Platform.pathSeparator}received.bin');
      await controller.receiveQuickTransfer(manifest, target: target);
      final claimed = controller.quickInbox.singleWhere(
        (item) => item.id == manifest.id,
      );

      await Future.wait([
        controller.deleteQuickTransfer(claimed),
        for (var attempt = 0; attempt < 8; attempt++)
          controller.refreshQuickTransfer(),
      ]);
      await controller.deleteQuickTransfer(claimed);
      await controller.refreshQuickTransfer();

      expect(controller.quickError, isNull);
      expect(
        controller.quickInbox.any((item) => item.id == manifest.id),
        isFalse,
      );
      expect(
        await Directory(
          '${repository.path}${Platform.pathSeparator}__jet2drop_transfer'
          '${Platform.pathSeparator}messages${Platform.pathSeparator}${manifest.id}',
        ).exists(),
        isFalse,
      );
    },
  );

  test('quick recipients contain only other recently seen devices', () async {
    final controller = AppController()..deviceId = 'self';
    addTearDown(controller.dispose);
    controller.quickDevices = [
      QuickDevice(id: 'self', name: '本机', updatedAt: DateTime.now()),
      QuickDevice(id: 'fresh', name: '可用设备', updatedAt: DateTime.now()),
      QuickDevice(
        id: 'stale',
        name: '过期设备',
        updatedAt: DateTime.now().subtract(const Duration(minutes: 3)),
      ),
    ];

    expect(controller.quickRecipients.map((device) => device.id), ['fresh']);
    expect(controller.quickDeviceName('unknown'), '未知设备');
  });

  test(
    'a paused quick send yields to the next file without blocking refresh',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'jet2drop-quick-pause-',
      );
      addTearDown(() => root.delete(recursive: true));
      final repository = Directory('${root.path}${Platform.pathSeparator}repo');
      await repository.create();
      final first = File(
        '${root.path}${Platform.pathSeparator}first-large.bin',
      );
      final firstWriter = await first.open(mode: FileMode.write);
      await firstWriter.truncate(128 * 1024 * 1024);
      await firstWriter.close();
      final second = File('${root.path}${Platform.pathSeparator}second.bin');
      await second.writeAsBytes(List<int>.filled(128 * 1024, 7));
      final controller = await createController(repository);
      addTearDown(controller.dispose);
      controller.quickDevices = [
        QuickDevice(
          id: 'target-device',
          name: '目标设备',
          updatedAt: DateTime.now(),
        ),
      ];

      final firstSend = controller.publishQuickTransfer(
        first,
        targetDevice: 'target-device',
      );
      final firstCancelled = expectLater(
        firstSend,
        throwsA(isA<TransferCancelled>()),
      );
      TransferTask? firstTask;
      for (var attempt = 0; attempt < 500; attempt++) {
        final matches = controller.tasks.where(
          (task) => task.name == 'first-large.bin',
        );
        if (matches.isNotEmpty &&
            matches.first.status == TransferStatus.running) {
          firstTask = matches.first;
          break;
        }
        await Future<void>.delayed(const Duration(milliseconds: 2));
      }
      expect(firstTask, isNotNull);
      controller.pauseTask(firstTask!);
      for (var attempt = 0; attempt < 500; attempt++) {
        if (firstTask.isPaused && !controller.hasRunningTransfers) break;
        await Future<void>.delayed(const Duration(milliseconds: 2));
      }
      expect(firstTask.isPaused, isTrue);

      final secondManifest = await controller
          .publishQuickTransfer(second, targetDevice: 'target-device')
          .timeout(const Duration(seconds: 30));
      await controller.refreshQuickTransfer();
      expect(
        controller.quickInbox.map((item) => item.id),
        contains(secondManifest.id),
      );
      expect(firstTask.isPaused, isTrue);
      expect(controller.hasRunningTransfers, isFalse);

      await controller.cancelTask(firstTask);
      await firstCancelled;
      expect(firstTask.status, TransferStatus.cancelled);
    },
  );
}

class _RealHttpOverrides extends HttpOverrides {}
