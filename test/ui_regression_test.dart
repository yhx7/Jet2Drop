import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jet2drop/app_controller.dart';
import 'package:jet2drop/core/models/quick_device.dart';
import 'package:jet2drop/core/models/transfer_task.dart';
import 'package:jet2drop/main.dart';

void main() {
  testWidgets('disconnected page always keeps retry and settings actions', (
    tester,
  ) async {
    final controller = AppController()
      ..isInitializing = false
      ..isReady = false
      ..error = '连接失败'
      ..needsTailscale = false;
    addTearDown(controller.dispose);

    await tester.pumpWidget(
      MaterialApp(home: RepositoryPage(controller: controller)),
    );

    expect(find.widgetWithText(FilledButton, '重试'), findsOneWidget);
    expect(find.widgetWithText(FilledButton, '连接设置'), findsOneWidget);
  });

  testWidgets('connection settings do not expose an application exit action', (
    tester,
  ) async {
    final controller = AppController()
      ..isInitializing = false
      ..isReady = true;
    addTearDown(controller.dispose);

    await tester.pumpWidget(
      MaterialApp(home: RepositoryPage(controller: controller)),
    );
    await tester.tap(find.byIcon(Icons.settings_outlined));
    await tester.pumpAndSettle();

    expect(find.textContaining('退出'), findsNothing);
  });

  testWidgets('connecting state never flashes the repository page', (
    tester,
  ) async {
    final controller = AppController()
      ..isInitializing = false
      ..isReady = false
      ..isLoading = true
      ..error = null;
    addTearDown(controller.dispose);

    await tester.pumpWidget(
      MaterialApp(home: RepositoryPage(controller: controller)),
    );

    expect(find.text('正在连接仓库'), findsOneWidget);
    expect(find.text('正在连接…'), findsOneWidget);
    expect(find.text('上传'), findsNothing);
    expect(
      tester
          .widget<FilledButton>(find.widgetWithText(FilledButton, '重试'))
          .onPressed,
      isNull,
    );
  });

  testWidgets('ready repository does not show the startup spinner', (
    tester,
  ) async {
    final controller = AppController()
      ..isInitializing = true
      ..isReady = true
      ..isLoading = false;
    addTearDown(controller.dispose);

    await tester.pumpWidget(
      MaterialApp(home: RepositoryPage(controller: controller)),
    );

    expect(find.text('上传'), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsNothing);
  });

  testWidgets('main product pages keep their primary feature entries', (
    tester,
  ) async {
    final controller = AppController()
      ..isInitializing = false
      ..isReady = true
      ..error = null;
    addTearDown(controller.dispose);

    await tester.pumpWidget(
      MaterialApp(home: RepositoryPage(controller: controller)),
    );

    expect(find.text('上传'), findsOneWidget);
    expect(find.text('新建文件夹'), findsOneWidget);
    expect(find.byIcon(Icons.refresh), findsWidgets);
    expect(find.byIcon(Icons.sort), findsOneWidget);

    await tester.tap(find.text('快速传输').last);
    await tester.pump();
    expect(find.text('发送到设备'), findsOneWidget);
    expect(find.text('直连快传'), findsOneWidget);
    expect(find.text('可靠中转'), findsOneWidget);
    await tester.drag(find.byType(ListView), const Offset(0, -420));
    await tester.pump();
    expect(find.text('收件箱'), findsOneWidget);

    await tester.tap(find.text('任务').last);
    await tester.pump();
    expect(find.text('传输任务'), findsOneWidget);
    expect(find.text('清除已完成任务'), findsNothing);
  });

  testWidgets('quick transfer updates in place after connection succeeds', (
    tester,
  ) async {
    final controller = AppController()
      ..isInitializing = false
      ..isReady = false
      ..error = '连接失败';
    addTearDown(controller.dispose);

    await tester.pumpWidget(Jet2DropApp(controller: controller));
    await tester.tap(find.text('快速传输').last);
    await tester.pump();
    expect(find.text('发送到设备'), findsOneWidget);
    expect(find.text('尚未连接到仓库'), findsNothing);

    controller
      ..isReady = true
      ..error = null
      ..notifyListeners();
    await tester.pump();

    expect(find.text('发送到设备'), findsOneWidget);
    await tester.drag(find.byType(ListView), const Offset(0, -420));
    await tester.pump();
    expect(find.text('收件箱'), findsOneWidget);
    expect(find.text('尚未连接到仓库'), findsNothing);
  });

  testWidgets('available device names do not repeat an online label', (
    tester,
  ) async {
    final controller = AppController()
      ..isInitializing = false
      ..isReady = true
      ..deviceId = 'this-device'
      ..quickDevices = [
        QuickDevice(
          id: 'target-device',
          name: '目标设备',
          updatedAt: DateTime.now(),
        ),
      ];
    addTearDown(controller.dispose);

    await tester.pumpWidget(Jet2DropApp(controller: controller));
    await tester.tap(find.text('快速传输').last);
    await tester.pump();

    expect(find.text('目标设备'), findsWidgets);
    expect(find.text('目标设备（在线）'), findsNothing);

    // The controller owns the background cadence, so stop it before the
    // widget-test binding checks for leaked timers.
    controller.dispose();
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('Android recipients expose only reliable relay mode', (
    tester,
  ) async {
    final controller = AppController()
      ..isInitializing = false
      ..isReady = false
      ..deviceId = 'this-device'
      ..quickDevices = [
        QuickDevice(
          id: 'android-device',
          name: 'Android 设备',
          platform: QuickDevicePlatform.android,
          updatedAt: DateTime.now(),
        ),
      ];
    addTearDown(controller.dispose);

    await tester.pumpWidget(Jet2DropApp(controller: controller));
    await tester.tap(find.text('快速传输').last);
    await tester.pump();

    expect(find.text('可靠中转'), findsOneWidget);
    expect(find.text('直连快传'), findsNothing);
    controller.dispose();
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('recipients without direct capability hide direct mode', (
    tester,
  ) async {
    final controller = AppController()
      ..isInitializing = false
      ..isReady = false
      ..deviceId = 'this-device'
      ..quickDevices = [
        QuickDevice(
          id: 'offline-desktop',
          name: '未启用直连的桌面设备',
          platform: QuickDevicePlatform.windows,
          updatedAt: DateTime.now(),
          canReceiveDirect: false,
        ),
      ];
    addTearDown(controller.dispose);

    await tester.pumpWidget(Jet2DropApp(controller: controller));
    await tester.tap(find.text('快速传输').last);
    await tester.pump();

    expect(find.text('可靠中转'), findsOneWidget);
    expect(find.text('直连快传'), findsNothing);
    controller.dispose();
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
    'compact and desktop repository controls keep their intended rows',
    (tester) async {
      final controller = AppController()
        ..isInitializing = false
        ..isReady = true;
      addTearDown(controller.dispose);
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      tester.view.devicePixelRatio = 1;

      tester.view.physicalSize = const Size(420, 820);
      await tester.pumpWidget(
        MaterialApp(home: RepositoryPage(controller: controller)),
      );
      final compactUpload = tester.getCenter(find.text('上传'));
      final compactBack = tester.getCenter(find.byIcon(Icons.arrow_back));
      final compactRefresh = tester.getCenter(find.byIcon(Icons.refresh).first);
      final compactDirection = tester.getCenter(
        find.byIcon(Icons.arrow_upward),
      );
      final compactSort = tester.getCenter(find.byIcon(Icons.sort));
      expect(compactUpload.dy, lessThan(compactBack.dy));
      expect(compactBack.dy, closeTo(compactRefresh.dy, 2));
      expect(compactDirection.dy, closeTo(compactSort.dy, 2));
      expect(compactDirection.dx, greaterThan(compactRefresh.dx));

      tester.view.physicalSize = const Size(1100, 820);
      await tester.pumpAndSettle();
      final back = tester.getCenter(find.byIcon(Icons.arrow_back));
      final refresh = tester.getCenter(find.byIcon(Icons.refresh).first);
      final direction = tester.getCenter(find.byIcon(Icons.arrow_upward));
      final sort = tester.getCenter(find.byIcon(Icons.sort));
      expect(back.dy, closeTo(refresh.dy, 2));
      expect(refresh.dx, lessThan(direction.dx));
      expect(direction.dx, lessThan(sort.dx));
    },
  );

  testWidgets(
    'same-name warning is absent until an upload actually conflicts',
    (tester) async {
      final controller = AppController()
        ..isInitializing = false
        ..isReady = true;
      addTearDown(controller.dispose);

      await tester.pumpWidget(
        MaterialApp(home: RepositoryPage(controller: controller)),
      );

      expect(find.textContaining('同名文件'), findsNothing);
      expect(find.textContaining('已存在'), findsNothing);
    },
  );

  testWidgets('task actions match running, failed and completed states', (
    tester,
  ) async {
    final controller = AppController()
      ..isInitializing = false
      ..isReady = true
      ..tasks.addAll([
        TransferTask(
          id: 'running',
          name: 'running.bin',
          direction: TransferDirection.download,
          totalBytes: 100,
          status: TransferStatus.running,
        ),
        TransferTask(
          id: 'failed',
          name: 'failed.bin',
          direction: TransferDirection.upload,
          totalBytes: 100,
          status: TransferStatus.failed,
          error: '连接中断',
        ),
        TransferTask(
          id: 'completed',
          name: 'completed.bin',
          direction: TransferDirection.quickSend,
          totalBytes: 100,
          transferredBytes: 100,
          status: TransferStatus.completed,
        ),
        TransferTask(
          id: 'direct-failed',
          name: 'direct.bin',
          direction: TransferDirection.quickSend,
          totalBytes: 100,
          status: TransferStatus.failed,
          route: QuickTransferRoute.direct,
          requestedMode: QuickTransferMode.direct,
          error: '直连失败',
          capabilities: const TransferTaskCapabilities.direct(),
        ),
      ]);
    addTearDown(controller.dispose);

    await tester.pumpWidget(
      MaterialApp(home: RepositoryPage(controller: controller)),
    );
    await tester.tap(find.text('任务').last);
    await tester.pump();

    expect(find.text('暂停'), findsOneWidget);
    expect(find.text('取消并清理'), findsOneWidget);
    expect(find.text('失败原因：连接中断'), findsOneWidget);
    expect(find.text('移除任务'), findsNWidgets(2));
    expect(
      tester
          .widget<TextButton>(find.widgetWithText(TextButton, '清除已完成任务'))
          .onPressed,
      isNotNull,
    );
    await tester.drag(find.byType(ListView), const Offset(0, -500));
    await tester.pump();
    expect(find.text('直连快传'), findsOneWidget);
  });

  testWidgets('a cleared quick error disappears without changing pages', (
    tester,
  ) async {
    final controller = AppController()
      ..isInitializing = false
      ..isReady = true
      ..quickError = '临时读取失败';
    addTearDown(controller.dispose);

    await tester.pumpWidget(Jet2DropApp(controller: controller));
    await tester.tap(find.text('快速传输').last);
    await tester.pump();
    expect(find.text('临时读取失败'), findsOneWidget);

    controller
      ..quickError = null
      ..notifyListeners();
    await tester.pump();
    expect(find.text('临时读取失败'), findsNothing);
    await tester.drag(find.byType(ListView), const Offset(0, -420));
    await tester.pump();
    expect(find.text('收件箱'), findsOneWidget);
  });
}
