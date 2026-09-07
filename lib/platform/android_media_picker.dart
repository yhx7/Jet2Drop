import 'dart:io';

import 'package:flutter/services.dart';

import '../core/path_utils.dart';

class PickedMedia {
  const PickedMedia({
    required this.file,
    required this.name,
    required this.mimeType,
  });

  final File file;
  final String name;
  final String mimeType;
}

class AndroidMediaPicker {
  static const _channel = MethodChannel('jet2drop/media_picker');

  static Future<List<PickedMedia>> pickImagesAndVideos() async {
    final values = await _channel.invokeMethod<List<dynamic>>(
      'pickImagesAndVideos',
    );
    return (values ?? const <dynamic>[])
        .map((value) {
          if (value is String) {
            final file = File(value);
            return PickedMedia(
              file: file,
              name: file.uri.pathSegments.last,
              mimeType: mimeTypeForName(file.uri.pathSegments.last),
            );
          }
          final map = Map<Object?, Object?>.from(value as Map);
          final path = map['path'] as String;
          final file = File(path);
          return PickedMedia(
            file: file,
            name: map['name'] as String? ?? file.uri.pathSegments.last,
            mimeType:
                map['mimeType'] as String? ??
                mimeTypeForName(map['name'] as String? ?? path),
          );
        })
        .toList(growable: false);
  }

  static Future<void> cleanup(List<File> files) async {
    if (!Platform.isAndroid || files.isEmpty) return;
    await _channel.invokeMethod<void>('cleanupPickedMedia', {
      'paths': files.map((file) => file.path).toList(growable: false),
    });
  }
}
