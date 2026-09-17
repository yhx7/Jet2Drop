import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Creates a uniquely named temporary directory that is removed when the
/// current test finishes.
///
/// Prefer this over `Directory.systemTemp.createTemp` so the clean-up is
/// retried: a test can end while background work it started is still cleaning
/// up its own temporary files (cancelled and failed transfers do exactly
/// that), and Windows refuses to delete a directory tree while any file inside
/// it is briefly open.
Future<Directory> createTempDirectory(String prefix) async {
  final directory = await Directory.systemTemp.createTemp(prefix);
  addTearDown(() => deleteTempDirectory(directory));
  return directory;
}

/// Deletes [directory] recursively, retrying briefly while it is in use.
///
/// The retries are bounded: a directory that is still locked after them throws
/// the original error instead of hiding a real failure.
Future<void> deleteTempDirectory(Directory directory) async {
  const attempts = 20;
  for (var attempt = 0; attempt < attempts; attempt++) {
    try {
      if (await directory.exists()) await directory.delete(recursive: true);
      return;
    } on FileSystemException {
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
  }
  if (await directory.exists()) await directory.delete(recursive: true);
}
