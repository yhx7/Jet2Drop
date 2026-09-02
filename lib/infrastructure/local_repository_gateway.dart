import 'dart:async';
import 'dart:io';

import '../core/models/file_entry.dart';
import '../core/checksum.dart';
import '../core/path_utils.dart';
import '../core/repository_gateway.dart';
import '../core/transfer_control.dart';

class LocalRepositoryGateway implements RepositoryGateway {
  LocalRepositoryGateway(this.rootPath);

  final String rootPath;

  Directory get _root => Directory(rootPath);

  @override
  Future<void> initialize() => _root.create(recursive: true);

  @override
  Future<int?> availableBytes(String relativePath) async => null;

  @override
  Future<void> recoverTemporaryFiles(String relativePath) async {
    final directory = _directoryFor(relativePath);
    if (!await directory.exists()) return;
    final cutoff = DateTime.now().subtract(const Duration(days: 7));
    await for (final entity in directory.list(followLinks: false)) {
      if (entity is! File) continue;
      final name = entity.path.split(Platform.pathSeparator).last;
      final backupIndex = name.indexOf('.jet2drop-backup-');
      if (backupIndex >= 0) {
        final original = File(
          '${directory.path}${Platform.pathSeparator}${name.substring(0, backupIndex)}',
        );
        if (!await original.exists()) {
          await entity.rename(original.path);
        } else if ((await entity.stat()).modified.isBefore(cutoff)) {
          await entity.delete();
        }
        continue;
      }
      if ((name.contains('.jet2drop-upload-') ||
              name.contains('.jet2drop-download-')) &&
          name.endsWith('.part') &&
          (await entity.stat()).modified.isBefore(cutoff)) {
        await entity.delete();
      }
    }
  }

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
          name.startsWith('.jet2drop-') ||
          name.contains('.jet2drop-upload-') ||
          name.contains('.jet2drop-download-') ||
          name.contains('.jet2drop-backup-')) {
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
    String? resumeId,
    ProgressCallback? onProgress,
    ChecksumCallback? onChecksum,
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
    final safeResumeId = resumeId == null
        ? uniqueSuffix()
        : resumeId.replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_');
    final temp = File('${destination.path}.jet2drop-upload-$safeResumeId.part');
    final total = await source.length();
    var written = resumeId != null && await temp.exists()
        ? await temp.length()
        : 0;
    if (written > total) {
      await temp.delete();
      written = 0;
    }
    final sink = temp.openWrite(
      mode: written == 0 ? FileMode.write : FileMode.append,
    );
    final checksum = onChecksum == null ? null : Sha256Accumulator();
    try {
      if (checksum != null && written > 0) {
        await for (final chunk in source.openRead(0, written)) {
          checksum.add(chunk);
        }
      }
      onProgress?.call(written, total);
      await for (final chunk in source.openRead(written)) {
        await control?.checkpoint();
        checksum?.add(chunk);
        sink.add(chunk);
        written += chunk.length;
        onProgress?.call(written, total);
      }
      await sink.flush();
      await sink.close();
      if (checksum != null) onChecksum!(checksum.close());
      final backup = File(
        '${destination.path}.jet2drop-backup-${uniqueSuffix()}',
      );
      final hadDestination = await destination.exists();
      if (hadDestination) await destination.rename(backup.path);
      try {
        await temp.rename(destination.path);
      } catch (_) {
        if (hadDestination && await backup.exists()) {
          await backup.rename(destination.path);
        }
        rethrow;
      }
      // Publishing has succeeded. A stale backup is harmless and is cleaned by
      // maintenance; failing to delete it must not turn a successful upload
      // into a failed task or roll the new file back.
      if (hadDestination && await backup.exists()) {
        try {
          await backup.delete();
        } catch (_) {}
      }
    } catch (exception) {
      await sink.close();
      if ((resumeId == null ||
              exception is TransferCancelled ||
              control?.isCancelled == true) &&
          await temp.exists()) {
        await temp.delete();
      }
      rethrow;
    }
  }

  @override
  Future<void> discardUploadPartial({
    required String targetDirectory,
    required String targetName,
    required String resumeId,
  }) async {
    final directory = _directoryFor(targetDirectory);
    final cleanName = normalizeRelativePath(targetName);
    final safeResumeId = resumeId.replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_');
    final partial = File(
      '${directory.path}${Platform.pathSeparator}$cleanName.jet2drop-upload-$safeResumeId.part',
    );
    if (await partial.exists()) await partial.delete();
  }

  @override
  Future<void> downloadFile({
    required String remotePath,
    required File target,
    String? resumeId,
    ProgressCallback? onProgress,
    TransferControl? control,
  }) async {
    final source = File(_entityFor(remotePath).path);
    if (!await source.exists()) {
      throw FileSystemException('File not found.', source.path);
    }
    await target.parent.create(recursive: true);
    final safeResumeId = resumeId == null
        ? uniqueSuffix()
        : resumeId.replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_');
    final temp = File('${target.path}.jet2drop-download-$safeResumeId.part');
    final total = await source.length();
    var written = resumeId != null && await temp.exists()
        ? await temp.length()
        : 0;
    if (written > total) {
      await temp.delete();
      written = 0;
    }
    final sink = temp.openWrite(
      mode: written == 0 ? FileMode.write : FileMode.append,
    );
    try {
      onProgress?.call(written, total);
      await for (final chunk in source.openRead(written)) {
        await control?.checkpoint();
        sink.add(chunk);
        written += chunk.length;
        onProgress?.call(written, total);
      }
      await sink.flush();
      await sink.close();
      final backup = File('${target.path}.jet2drop-backup-${uniqueSuffix()}');
      final hadTarget = await target.exists();
      if (hadTarget) await target.rename(backup.path);
      try {
        await temp.rename(target.path);
      } catch (_) {
        if (hadTarget && await backup.exists()) {
          await backup.rename(target.path);
        }
        rethrow;
      }
      if (hadTarget && await backup.exists()) {
        try {
          await backup.delete();
        } catch (_) {}
      }
    } catch (exception) {
      await sink.close();
      if ((resumeId == null ||
              exception is TransferCancelled ||
              control?.isCancelled == true) &&
          await temp.exists()) {
        await temp.delete();
      }
      rethrow;
    }
  }

  @override
  Future<File> materializeForPreview(
    String relativePath, {
    TransferControl? control,
  }) async {
    await control?.checkpoint();
    return File(_entityFor(relativePath).path);
  }

  @override
  Future<void> dispose() async {}
}
