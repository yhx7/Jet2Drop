import 'dart:io';

import 'package:flutter/services.dart';

class TailscaleBridge {
  TailscaleBridge._();

  static const _channel = MethodChannel('jet2drop/tailscale');

  static Future<bool> open() async {
    if (Platform.isAndroid) {
      return await _channel.invokeMethod<bool>('openTailscale') ?? false;
    }
    try {
      if (Platform.isMacOS) {
        final result = await Process.run('open', ['-a', 'Tailscale']);
        return result.exitCode == 0;
      }
      if (Platform.isWindows) {
        final candidates = <String>[
          r'C:\Program Files\Tailscale\tailscale-ipn.exe',
          r'C:\Program Files\Tailscale\tailscale.exe',
        ];
        final matches = candidates.where((path) => File(path).existsSync());
        final executable = matches.isEmpty ? null : matches.first;
        if (executable == null) return false;
        await Process.start(executable, const []);
        return true;
      }
    } catch (_) {
      return false;
    }
    return false;
  }
}
