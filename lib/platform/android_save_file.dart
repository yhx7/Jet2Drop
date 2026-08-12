import 'dart:io';

import 'package:flutter/services.dart';

class AndroidSaveFile {
  static const _channel = MethodChannel('jet2drop/save_document');

  static Future<bool> save({
    required File source,
    required String suggestedName,
    required String mimeType,
  }) async {
    final result = await _channel.invokeMethod<bool>('saveDocument', {
      'sourcePath': source.path,
      'suggestedName': suggestedName,
      'mimeType': mimeType,
    });
    return result ?? false;
  }

  static Future<String?> chooseDocumentTarget({
    required String suggestedName,
    required String mimeType,
  }) => _channel.invokeMethod<String>('chooseDocumentTarget', {
    'suggestedName': suggestedName,
    'mimeType': mimeType,
  });

  static Future<bool> saveToDocumentTarget({
    required File source,
    required String targetUri,
  }) async {
    final result = await _channel.invokeMethod<bool>('saveToDocumentTarget', {
      'sourcePath': source.path,
      'targetUri': targetUri,
    });
    return result ?? false;
  }

  static Future<bool> saveMedia({
    required File source,
    required String suggestedName,
    required String mimeType,
  }) async {
    final result = await _channel.invokeMethod<bool>('saveMedia', {
      'sourcePath': source.path,
      'suggestedName': suggestedName,
      'mimeType': mimeType,
    });
    return result ?? false;
  }
}
