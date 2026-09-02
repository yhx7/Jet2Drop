import 'dart:io';

import 'package:flutter/services.dart';

class WindowsLifecycleBridge {
  static const _channel = MethodChannel('jet2drop/windows_lifecycle');

  static Future<void> setActiveTransfers(bool active) async {
    if (!Platform.isWindows) return;
    await _channel.invokeMethod<void>('setActiveTransfers', active);
  }
}
