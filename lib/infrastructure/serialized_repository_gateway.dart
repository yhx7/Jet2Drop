import 'dart:io';

import '../core/models/file_entry.dart';
import '../core/repository_gateway.dart';
import '../core/transfer_control.dart';

/// Serializes requests sent through one stateful repository connection.
class SerializedRepositoryGateway
    implements
        RepositoryGateway,
        AtomicRepositoryGateway,
        RepositorySyncManifestInvalidator,
        RepositoryChangeSource {
  SerializedRepositoryGateway(this._delegate);

  final RepositoryGateway _delegate;
  Future<void> _tail = Future<void>.value();

  /// Forwards the delegate's external change stream, or an empty stream when
  /// the delegate cannot observe changes.
  @override
  Stream<void> get repositoryChanges {
    final delegate = _delegate;
    return delegate is RepositoryChangeSource
        ? (delegate as RepositoryChangeSource).repositoryChanges
        : const Stream<void>.empty();
  }

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
  Future<void> invalidateRepositorySyncManifest() {
    final invalidator = _delegate;
    if (invalidator is RepositorySyncManifestInvalidator) {
      return _run(
        () => (invalidator as RepositorySyncManifestInvalidator)
            .invalidateRepositorySyncManifest(),
      );
    }
    return Future<void>.value();
  }

  @override
  Future<void> moveEntry(
    String sourcePath,
    String targetPath, {
    bool overwrite = false,
  }) {
    final atomic = _delegate;
    if (atomic is AtomicRepositoryGateway) {
      return _run(
        () => (atomic as AtomicRepositoryGateway).moveEntry(
          sourcePath,
          targetPath,
          overwrite: overwrite,
        ),
      );
    }
    throw UnsupportedError(
      'Repository synchronization requires an atomic move capability.',
    );
  }

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
    ChecksumCallback? onChecksum,
    TransferControl? control,
  }) => _run(
    () => _delegate.downloadFile(
      remotePath: remotePath,
      target: target,
      resumeId: resumeId,
      onProgress: onProgress,
      onChecksum: onChecksum,
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
