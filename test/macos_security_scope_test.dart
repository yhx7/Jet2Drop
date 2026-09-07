import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jet2drop/platform/macos_security_scope.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('security scope bridge is a no-op on non-macOS platforms', () async {
    if (Platform.isMacOS) return;

    var calls = 0;
    const channel = MethodChannel('jet2drop/macos_security_scope');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (_) async {
          calls++;
          return '/should-not-be-used';
        });
    addTearDown(
      () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null),
    );

    expect(await MacosSecurityScope.restoreDirectoryAccess(), isNull);
    await MacosSecurityScope.persistDirectoryAccess(r'C:\unused');
    expect(calls, 0);
  });
}
