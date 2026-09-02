import 'dart:io';

import '../core/models/file_entry.dart';
import '../core/repository_gateway.dart';
import '../core/transfer_control.dart';

/// Serializes requests sent through one stateful repository connection.
class SerializedRepositoryGateway implements RepositoryGateway {
  SerializedRepositoryGateway(this._delegate);

  final RepositoryGateway _delegate;
  Future<void> _tail = Future<void>.value();

  Future<T> _run<T>(Future<T> Function() operation) {
    final result = _tail.then((_) => operation());
    _tail = result.then<void>((_) {}, onError: (_, _) {});
    return result;
  }

  @override
  Future<void> initialize() => _run(_delegate.initialize);

  @override
  Future<int?> availableBytes(String relativePath) =>
      _run(() => _delegate.availableBytes(relativePath));

  @override
  Future<void> recoverTemporaryFiles(String relativePath) =>
      _run(() => _delegate.recoverTemporaryFiles(relativePath));

  @override
  Future<List<FileEntry>> listDirectory(String relativePath) =>
      _run(() => _delegate.listDirectory(relativePath));

  @override
  Future<void> createDirectory(String relativePath, String name) =>
      _run(() => _delegate.createDirectory(relativePath, name));

  @override
  Future<void> deleteEntry(String relativePath, {required bool recursive}) =>
      _run(() => _delegate.deleteEntry(relativePath, recursive: recursive));

  @override
  Future<void> uploadFile({
    required File source,
    required String targetDirectory,
    required String targetName,
    required bool overwrite,
    String? resumeId,
    ProgressCallback? onProgress,
    ChecksumCallback? onChecksum,
    TransferControl? control,
  }) => _run(
    () => _delegate.uploadFile(
      source: source,
      targetDirectory: targetDirectory,
      targetName: targetName,
      overwrite: overwrite,
      resumeId: resumeId,
      onProgress: onProgress,
      onChecksum: onChecksum,
      control: control,
    ),
  );

  @override
  Future<void> discardUploadPartial({
    required String targetDirectory,
    required String targetName,
    required String resumeId,
  }) => _run(
    () => _delegate.discardUploadPartial(
      targetDirectory: targetDirectory,
      targetName: targetName,
      resumeId: resumeId,
    ),
  );

  @override
  Future<void> downloadFile({
    required String remotePath,
    required File target,
    String? resumeId,
    ProgressCallback? onProgress,
    TransferControl? control,
  }) => _run(
    () => _delegate.downloadFile(
      remotePath: remotePath,
      target: target,
      resumeId: resumeId,
      onProgress: onProgress,
      control: control,
    ),
  );

  @override
  Future<File> materializeForPreview(
    String relativePath, {
    TransferControl? control,
  }) => _run(
    () => _delegate.materializeForPreview(relativePath, control: control),
  );

  @override
  Future<void> dispose() => _run(_delegate.dispose);
}
