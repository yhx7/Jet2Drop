import 'dart:convert';

import 'package:crypto/crypto.dart';

class _DigestSink implements Sink<Digest> {
  Digest? value;

  @override
  void add(Digest event) => value = event;

  @override
  void close() {}
}

class Sha256Accumulator {
  Sha256Accumulator() {
    _conversion = sha256.startChunkedConversion(_digest);
  }

  final _DigestSink _digest = _DigestSink();
  late final ByteConversionSink _conversion;
  bool _closed = false;

  void add(List<int> bytes) {
    if (_closed) throw StateError('Checksum has already been finalized.');
    _conversion.add(bytes);
  }

  String close() {
    if (!_closed) {
      _closed = true;
      _conversion.close();
    }
    return _digest.value!.toString();
  }
}
