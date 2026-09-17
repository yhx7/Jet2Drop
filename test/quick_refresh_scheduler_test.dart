import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:jet2drop/app_controller.dart';

void main() {
  test('quick refresh cadence switches without creating dual timers', () {
    final timers = <_RecordingTimer>[];
    final controller =
        AppController(
            periodicTimerFactory: (duration, callback) {
              final timer = _RecordingTimer(duration, callback);
              timers.add(timer);
              return timer;
            },
          )
          ..isReady = true
          ..deviceId = 'this-device';
    addTearDown(controller.dispose);

    expect(
      controller.quickRefreshInterval,
      AppController.quickTransferInactiveRefreshInterval,
    );
    controller.setQuickTransferPageActive(true);
    expect(
      controller.quickRefreshInterval,
      AppController.quickTransferActiveRefreshInterval,
    );
    expect(timers, hasLength(1));
    expect(
      timers.single.duration,
      AppController.quickTransferActiveRefreshInterval,
    );
    expect(timers.single.isActive, isTrue);

    // Repeating the same navigation state must not restart or duplicate the
    // controller-owned timer.
    controller.setQuickTransferPageActive(true);
    expect(timers, hasLength(1));
    expect(timers.single.isActive, isTrue);

    controller.setQuickTransferPageActive(false);
    expect(
      controller.quickRefreshInterval,
      AppController.quickTransferInactiveRefreshInterval,
    );
    expect(timers, hasLength(2));
    expect(timers.first.isActive, isFalse);
    expect(
      timers.last.duration,
      AppController.quickTransferInactiveRefreshInterval,
    );
    expect(timers.last.isActive, isTrue);

    controller.setQuickTransferPageActive(false);
    expect(timers, hasLength(2));
    expect(timers.last.isActive, isTrue);
  });
}

class _RecordingTimer implements Timer {
  _RecordingTimer(this.duration, this.callback);

  final Duration duration;
  final void Function(Timer) callback;
  bool _isActive = true;

  @override
  void cancel() => _isActive = false;

  @override
  bool get isActive => _isActive;

  @override
  int get tick => 0;

  void fire() {
    if (_isActive) callback(this);
  }
}
