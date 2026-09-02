import 'dart:io';

import 'models/file_entry.dart';
import 'transfer_control.dart';

typedef ProgressCallback = void Function(int transferred, int total);
typedef ChecksumCallback = void Function(String checksum);

abstract interface class RepositoryGateway {
  Future<void> initialize();
  Future<int?> availableBytes(String relativePath);
  Future<void> recoverTemporaryFiles(String relativePath);
  Future<List<FileEntry>> listDirectory(String relativePath);
  Future<void> createDirectory(String relativePath, String name);
  Future<void> deleteEntry(String relativePath, {required bool recursive});
  Future<void> uploadFile({
    required File source,
    required String targetDirectory,
    required String targetName,
    required bool overwrite,
    String? resumeId,
    ProgressCallback? onProgress,
    ChecksumCallback? onChecksum,
    TransferControl? control,
  });
  Future<void> discardUploadPartial({
    required String targetDirectory,
    required String targetName,
    required String resumeId,
  });
  Future<void> downloadFile({
    required String remotePath,
    required File target,
    String? resumeId,
    ProgressCallback? onProgress,
    TransferControl? control,
  });
  Future<File> materializeForPreview(
    String relativePath, {
    TransferControl? control,
  });
  Future<void> dispose();
}
