import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:jet2drop/platform/tailscale_bridge.dart';

void main() {
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
}
