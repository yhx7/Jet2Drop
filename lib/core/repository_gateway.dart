import 'dart:io';

import 'models/file_entry.dart';
import 'transfer_control.dart';

typedef ProgressCallback = void Function(int transferred, int total);

abstract interface class RepositoryGateway {
  Future<void> initialize();
  Future<List<FileEntry>> listDirectory(String relativePath);
  Future<void> createDirectory(String relativePath, String name);
  Future<void> deleteEntry(String relativePath, {required bool recursive});
  Future<void> uploadFile({
    required File source,
    required String targetDirectory,
    required String targetName,
    required bool overwrite,
    ProgressCallback? onProgress,
    TransferControl? control,
  });
  Future<void> downloadFile({
    required String remotePath,
    required File target,
    ProgressCallback? onProgress,
    TransferControl? control,
  });
  Future<File> materializeForPreview(String relativePath);
  Future<void> dispose();
}
