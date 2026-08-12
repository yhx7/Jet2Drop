import 'dart:io';

import 'package:flutter/services.dart';

class AndroidMediaPicker {
  static const _channel = MethodChannel('jet2drop/media_picker');

  static Future<List<File>> pickImagesAndVideos() async {
    final paths = await _channel.invokeListMethod<String>('pickImagesAndVideos');
    return (paths ?? const <String>[]).map(File.new).toList();
  }
}
