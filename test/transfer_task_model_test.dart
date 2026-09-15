import 'package:flutter_test/flutter_test.dart';
import 'package:jet2drop/core/models/transfer_task.dart';

void main() {
  test('legacy task construction keeps the existing pause default', () {
    final task = TransferTask(
      id: 'legacy',
      name: 'file.bin',
      direction: TransferDirection.upload,
      totalBytes: 10,
    );

    expect(task.supportsPause, isTrue);
    expect(task.requestedMode, isNull);
    expect(task.route, isNull);
    expect(task.canPause, isTrue);
    expect(task.canResume, isTrue);
    expect(task.canRestartRecovery, isTrue);
    expect(task.canCancel, isTrue);
  });

  test('direct route exposes cancel and retry but no pause or recovery', () {
    final task = TransferTask(
      id: 'direct',
      name: 'file.bin',
      direction: TransferDirection.quickSend,
      totalBytes: 10,
      requestedMode: QuickTransferMode.direct,
      route: QuickTransferRoute.direct,
      capabilities: const TransferTaskCapabilities.direct(),
    );

    expect(task.isDirect, isTrue);
    expect(task.canPause, isFalse);
    expect(task.canResume, isFalse);
    expect(task.canRestartRecovery, isFalse);
    expect(task.canCancel, isTrue);
    expect(task.canRetryFromStart, isTrue);
  });

  test('reliable-relay request can record a direct fallback', () {
    final task = TransferTask(
      id: 'fallback',
      name: 'file.bin',
      direction: TransferDirection.quickSend,
      totalBytes: 10,
      requestedMode: QuickTransferMode.reliableRelay,
      route: QuickTransferRoute.direct,
      capabilities: const TransferTaskCapabilities.direct(),
    );

    expect(task.requestedMode, QuickTransferMode.reliableRelay);
    expect(task.route, QuickTransferRoute.direct);
    expect(task.isDirect, isTrue);
    expect(task.canPause, isFalse);
    expect(task.canResume, isFalse);
    expect(task.canRestartRecovery, isFalse);
  });

  test('direct request cannot be represented as a relay fallback', () {
    final task = TransferTask(
      id: 'direct-only',
      name: 'file.bin',
      direction: TransferDirection.quickSend,
      totalBytes: 10,
      requestedMode: QuickTransferMode.direct,
      route: QuickTransferRoute.direct,
    );

    expect(task.requestedMode, QuickTransferMode.direct);
    expect(task.route, QuickTransferRoute.direct);
    expect(task.isDirect, isTrue);

    expect(
      () => TransferTask(
        id: 'invalid-fallback',
        name: 'file.bin',
        direction: TransferDirection.quickSend,
        totalBytes: 10,
        requestedMode: QuickTransferMode.direct,
        route: QuickTransferRoute.reliableRelay,
      ),
      throwsArgumentError,
    );
  });
}
