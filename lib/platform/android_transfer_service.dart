import 'dart:io';

import 'package:flutter/services.dart';

class AndroidTransferService {
  static const _channel = MethodChannel('jet2drop/transfer_service');

  static Future<void> start({
    required int current,
    required int total,
    required int tasks,
  }) => _invoke('start', current: current, total: total, tasks: tasks);

  static Future<void> update({
    required int current,
    required int total,
    required int tasks,
  }) => _invoke('update', current: current, total: total, tasks: tasks);

  static Future<void> stop() async {
    if (!Platform.isAndroid) return;
    try {
      await _channel.invokeMethod<void>('stop');
    } on PlatformException {
      // Transfer state remains authoritative in Dart if Android rejects an update.
    }
  }

  static Future<void> _invoke(
    String method, {
    required int current,
    required int total,
    required int tasks,
  }) async {
    if (!Platform.isAndroid) return;
    try {
      await _channel.invokeMethod<void>(method, {
        'current': current,
        'total': total,
        'tasks': tasks,
      });
    } on PlatformException {
      // A notification failure must never fail the file transfer itself.
    }
  }
}
