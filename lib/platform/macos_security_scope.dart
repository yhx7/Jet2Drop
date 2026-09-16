import 'dart:io';

import 'package:flutter/services.dart';

/// Keeps the desktop quick-transfer directory usable inside the macOS
/// App Sandbox after the application is restarted.
class MacosSecurityScope {
  MacosSecurityScope._();

  static const _channel = MethodChannel('jet2drop/macos_security_scope');

  /// Restores the persisted security-scoped bookmark and starts accessing it.
  ///
  /// A null result means that there is no usable bookmark and the user must
  /// select the directory again. Other platforms intentionally do nothing.
  static Future<String?> restoreDirectoryAccess() async {
    if (!Platform.isMacOS) return null;
    return _channel.invokeMethod<String>('restoreDirectoryAccess');
  }

  /// Restores the separate bookmark used by the Mac repository mirror.
  static Future<String?> restoreSyncDirectoryAccess() async {
    if (!Platform.isMacOS) return null;
    return _channel.invokeMethod<String>('restoreSyncDirectoryAccess');
  }

  /// Creates and persists an app-scoped bookmark for [path]. The native side
  /// starts the new scope before replacing the previous one.
  static Future<void> persistDirectoryAccess(String path) async {
    if (!Platform.isMacOS) return;
    await _channel.invokeMethod<void>('persistDirectoryAccess', {'path': path});
  }

  static Future<void> persistSyncDirectoryAccess(String path) async {
    if (!Platform.isMacOS) return;
    await _channel.invokeMethod<void>('persistSyncDirectoryAccess', {
      'path': path,
    });
  }
}
