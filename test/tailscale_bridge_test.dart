import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jet2drop/platform/tailscale_bridge.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('recognizes only the Tailscale IPv4 CGNAT range', () {
    expect(
      TailscaleBridge.isTailscaleIpv4Address(InternetAddress('100.64.0.1')),
      isTrue,
    );
    expect(
      TailscaleBridge.isTailscaleIpv4Address(
        InternetAddress('100.127.255.254'),
      ),
      isTrue,
    );
    expect(
      TailscaleBridge.isTailscaleIpv4Address(InternetAddress('100.128.0.1')),
      isFalse,
    );
    expect(
      TailscaleBridge.isTailscaleIpv4Address(InternetAddress('192.168.1.2')),
      isFalse,
    );
  });

  test('macOS opens Tailscale through the native application bridge', () async {
    if (!Platform.isMacOS) return;
    const channel = MethodChannel('jet2drop/tailscale');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
    MethodCall? received;
    messenger.setMockMethodCallHandler(channel, (call) async {
      received = call;
      return true;
    });

    expect(await TailscaleBridge.open(), isTrue);
    expect(received?.method, 'openTailscale');
  });
}
