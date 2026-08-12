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
    ProgressCallback? onProgress,
    TransferControl? control,
  }) => _run(
    () => _delegate.uploadFile(
      source: source,
      targetDirectory: targetDirectory,
      targetName: targetName,
      overwrite: overwrite,
      onProgress: onProgress,
      control: control,
    ),
  );

  @override
  Future<void> downloadFile({
    required String remotePath,
    required File target,
    ProgressCallback? onProgress,
    TransferControl? control,
  }) => _run(
    () => _delegate.downloadFile(
      remotePath: remotePath,
      target: target,
      onProgress: onProgress,
      control: control,
    ),
  );

  @override
  Future<File> materializeForPreview(String relativePath) =>
      _run(() => _delegate.materializeForPreview(relativePath));

  @override
  Future<void> dispose() => _run(_delegate.dispose);
}
