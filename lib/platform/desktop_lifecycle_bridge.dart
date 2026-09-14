import 'dart:io';

import 'package:flutter/services.dart';

class DesktopLifecycleBridge {
  static const _windowsChannel = MethodChannel(
    'jet2drop/windows_lifecycle',
  );
  static const _macosChannel = MethodChannel('jet2drop/macos_lifecycle');

  static MethodChannel? get _channel {
    if (Platform.isWindows) return _windowsChannel;
    if (Platform.isMacOS) return _macosChannel;
    return null;
  }

  static Future<void> setActiveTransfers(bool active) async {
    await _channel?.invokeMethod<void>('setActiveTransfers', active);
  }

  static Future<void> requestExit() async {
    await _channel?.invokeMethod<void>('requestExit');
  }
}
