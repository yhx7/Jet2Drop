import 'dart:async';
import 'dart:io';

import '../core/models/file_entry.dart';
import '../core/path_utils.dart';
import '../core/repository_gateway.dart';
import '../core/transfer_control.dart';

class LocalRepositoryGateway implements RepositoryGateway {
  LocalRepositoryGateway(this.rootPath);

  final String rootPath;

  Directory get _root => Directory(rootPath);

  @override
  Future<void> initialize() => _root.create(recursive: true);

  FileSystemEntity _entityFor(String relativePath) {
    final safePath = normalizeRelativePath(relativePath);
    return File(
      safePath.isEmpty
          ? rootPath
          : '$rootPath${Platform.pathSeparator}$safePath',
    );
  }

  Directory _directoryFor(String relativePath) {
    final safePath = normalizeRelativePath(relativePath);
    return Directory(
      safePath.isEmpty
          ? rootPath
          : '$rootPath${Platform.pathSeparator}$safePath',
    );
  }

  @override
  Future<List<FileEntry>> listDirectory(String relativePath) async {
    final directory = _directoryFor(relativePath);
    if (!await directory.exists()) return const [];
    final entries = <FileEntry>[];
    await for (final entity in directory.list(followLinks: false)) {
      // Read the basename from the filesystem path. URI decoding here would
      // decode a literal '%' in a valid Windows filename a second time.
      final name = entity.path.split(Platform.pathSeparator).last;
      if (name == '.jet2drop-history' ||
          name == '__jet2drop_transfer' ||
          name.startsWith('.jet2drop-')) {
        continue;
      }
      final stat = await entity.stat();
      final type = stat.type == FileSystemEntityType.directory
          ? FileEntryType.directory
          : FileEntryType.file;
      entries.add(
        FileEntry(
          path: joinRelativePath(relativePath, name),
          name: name,
          type: type,
          size: type == FileEntryType.file ? stat.size : 0,
          modifiedAt: stat.modified,
        ),
      );
    }
    entries.sort((left, right) {
      if (left.type != right.type) {
        return left.isDirectory ? -1 : 1;
      }
      return left.name.toLowerCase().compareTo(right.name.toLowerCase());
    });
    return entries;
  }

  @override
  Future<void> createDirectory(String relativePath, String name) async {
    final safeName = normalizeRelativePath(name);
    if (safeName.contains('/')) {
      throw ArgumentError('Folder name must be one segment.');
    }
    await _directoryFor(joinRelativePath(relativePath, safeName)).create();
  }

  @override
  Future<void> deleteEntry(
    String relativePath, {
    required bool recursive,
  }) async {
    final safePath = normalizeRelativePath(relativePath);
    if (safePath.isEmpty) {
      throw ArgumentError('The repository root cannot be deleted.');
    }
    final path = '$rootPath${Platform.pathSeparator}$safePath';
    final type = await FileSystemEntity.type(path, followLinks: false);
    if (type == FileSystemEntityType.notFound) {
      throw FileSystemException('File not found.', path);
    }
    if (type == FileSystemEntityType.directory) {
      await Directory(path).delete(recursive: recursive);
      return;
    }
    await File(path).delete();
  }

  @override
  Future<void> uploadFile({
    required File source,
    required String targetDirectory,
    required String targetName,
    required bool overwrite,
    ProgressCallback? onProgress,
    TransferControl? control,
  }) async {
    final destinationDirectory = _directoryFor(targetDirectory);
    await destinationDirectory.create(recursive: true);
    final cleanName = normalizeRelativePath(targetName);
    if (cleanName.contains('/')) {
      throw ArgumentError('File name must be one segment.');
    }
    final destination = File(
      '${destinationDirectory.path}${Platform.pathSeparator}$cleanName',
    );
    if (await destination.exists() && !overwrite) {
      throw FileSystemException(
        'A file with the same name already exists.',
        destination.path,
      );
    }
    final temp = File(
      '${destination.path}.jet2drop-upload-${uniqueSuffix()}.part',
    );
    final total = await source.length();
    var written = 0;
    final sink = temp.openWrite();
    try {
      await for (final chunk in source.openRead()) {
        await control?.checkpoint();
        sink.add(chunk);
        written += chunk.length;
        onProgress?.call(written, total);
      }
      await sink.flush();
      await sink.close();
      if (await destination.exists()) {
        await destination.delete();
      }
      await temp.rename(destination.path);
    } catch (_) {
      await sink.close();
      if (await temp.exists()) await temp.delete();
      rethrow;
    }
  }

  @override
  Future<void> downloadFile({
    required String remotePath,
    required File target,
    ProgressCallback? onProgress,
    TransferControl? control,
  }) async {
    final source = File(_entityFor(remotePath).path);
    if (!await source.exists()) {
      throw FileSystemException('File not found.', source.path);
    }
    await target.parent.create(recursive: true);
    final temp = File(
      '${target.path}.jet2drop-download-${uniqueSuffix()}.part',
    );
    final total = await source.length();
    var written = 0;
    final sink = temp.openWrite();
    try {
      await for (final chunk in source.openRead()) {
        await control?.checkpoint();
        sink.add(chunk);
        written += chunk.length;
        onProgress?.call(written, total);
      }
      await sink.flush();
      await sink.close();
      if (await target.exists()) {
        await target.delete();
      }
      await temp.rename(target.path);
    } catch (_) {
      await sink.close();
      if (await temp.exists()) await temp.delete();
      rethrow;
    }
  }

  @override
  Future<File> materializeForPreview(String relativePath) async =>
      File(_entityFor(relativePath).path);

  @override
  Future<void> dispose() async {}
}
