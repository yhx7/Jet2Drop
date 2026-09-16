import 'dart:io';

import 'models/file_entry.dart';
import 'transfer_control.dart';

typedef ProgressCallback = void Function(int transferred, int total);
typedef ChecksumCallback = void Function(String checksum);

/// Optional capability used by repository synchronization to publish a
/// staged entry with one server-side rename. Keeping this separate from the
/// browsing/transfer interface preserves compatibility with older gateway
/// implementations used by integrations and tests.
abstract interface class AtomicRepositoryGateway {
  Future<void> moveEntry(
    String sourcePath,
    String targetPath, {
    bool overwrite = false,
  });
}

/// Optional capability for a central-repository gateway. Ordinary Jet2Drop
/// mutations can invalidate the sync accelerator without forcing a full scan
/// and re-hash on every upload; the synchronizer still scans formal files.
abstract interface class RepositorySyncManifestInvalidator {
  Future<void> invalidateRepositorySyncManifest();
}

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
    ChecksumCallback? onChecksum,
    TransferControl? control,
  });
  Future<File> materializeForPreview(
    String relativePath, {
    TransferControl? control,
  });
  Future<void> dispose();
}
