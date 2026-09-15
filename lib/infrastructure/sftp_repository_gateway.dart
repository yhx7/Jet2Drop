import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart';

import '../core/models/file_entry.dart';
import '../core/checksum.dart';
import '../core/path_utils.dart';
import '../core/repository_gateway.dart';
import '../core/transfer_control.dart';

class SftpConnectionProfile {
  const SftpConnectionProfile({
    required this.host,
    required this.port,
    required this.username,
    required this.password,
    required this.hostKeyFingerprint,
  });

  final String host;
  final int port;
  final String username;
  final String password;
  final String hostKeyFingerprint;
}

class SftpRepositoryGateway implements RepositoryGateway {
  SftpRepositoryGateway(this.profile, this.cacheDirectory);

  final SftpConnectionProfile profile;
  final Directory cacheDirectory;
  SSHClient? _client;
  SftpClient? _sftp;

  static const _operationTimeout = Duration(seconds: 45);
  // SFTP's default 16 KiB reads turn a high-latency relay into thousands of
  // tiny round trips. dartssh2 recommends this 64 KiB/128-request pipeline
  // for high-latency links. The library still yields chunks in file order, so
  // pause/cancel/checksum/atomic-publish semantics remain unchanged.
  static const _downloadChunkSize = 64 * 1024;
  static const _downloadPendingRequests = 128;

  Future<T> _withOperationTimeout<T>(Future<T> operation, String action) =>
      operation.timeout(
        _operationTimeout,
        onTimeout: () => throw TimeoutException(
          '$action timed out after ${_operationTimeout.inSeconds} seconds.',
        ),
      );

  Future<SftpClient> get _connection async {
    if (_sftp != null) return _sftp!;
    await cacheDirectory.create(recursive: true);
    final socket = await SSHSocket.connect(profile.host, profile.port).timeout(
      const Duration(seconds: 12),
      onTimeout: () => throw TimeoutException('SFTP connection timed out.'),
    );
    final client = SSHClient(
      socket,
      username: profile.username,
      onPasswordRequest: () => profile.password,
      onVerifyHostKey: (_, fingerprint) {
        final actual = utf8.decode(fingerprint, allowMalformed: true);
        return actual == profile.hostKeyFingerprint;
      },
    );
    _client = client;
    try {
      _sftp = await client.sftp().timeout(
        const Duration(seconds: 12),
        onTimeout: () => throw TimeoutException('SFTP handshake timed out.'),
      );
      return _sftp!;
    } catch (exception) {
      client.close();
      _client = null;
      rethrow;
    }
  }

  String _remote(String path) {
    final normalized = normalizeRelativePath(path);
    return normalized.isEmpty ? '/' : '/$normalized';
  }

  @override
  Future<void> initialize() async {
    await _connection;
  }

  @override
  Future<int?> availableBytes(String relativePath) async {
    try {
      final stats = await _withOperationTimeout(
        (await _connection).statvfs(_remote(relativePath)),
        'Checking available space',
      );
      return stats.freeBlocksForNonRoot * stats.fundamentalBlockSize;
    } on SftpExtensionUnsupportedError {
      // statvfs is an optional OpenSSH extension.
      return null;
    } on SftpExtensionVersionMismatchError {
      // Treat a server-advertised incompatible extension as unavailable.
      return null;
    }
  }

  @override
  Future<void> recoverTemporaryFiles(String relativePath) async {
    final sftp = await _connection;
    final directory = _remote(relativePath);
    final cutoff = DateTime.now().subtract(const Duration(days: 7));
    final entries = await _withOperationTimeout(
      sftp.listdir(directory),
      'Checking temporary files',
    );
    for (final entry in entries) {
      if (entry.attr.mode?.type == SftpFileType.directory) continue;
      final name = entry.filename;
      final backupIndex = name.indexOf('.jet2drop-backup-');
      final path = directory == '/' ? '/$name' : '$directory/$name';
      if (backupIndex >= 0) {
        final originalName = name.substring(0, backupIndex);
        final original = directory == '/'
            ? '/$originalName'
            : '$directory/$originalName';
        var originalExists = false;
        try {
          await sftp.stat(original);
          originalExists = true;
        } catch (_) {}
        if (!originalExists) {
          await sftp.rename(path, original);
        } else if (_isOlderThan(entry.attr.modifyTime, cutoff)) {
          await sftp.remove(path);
        }
        continue;
      }
      if ((name.contains('.jet2drop-upload-') ||
              name.contains('.jet2drop-download-')) &&
          name.endsWith('.part') &&
          _isOlderThan(entry.attr.modifyTime, cutoff)) {
        await sftp.remove(path);
      }
    }
  }

  bool _isOlderThan(int? secondsSinceEpoch, DateTime cutoff) =>
      secondsSinceEpoch != null &&
      DateTime.fromMillisecondsSinceEpoch(
        secondsSinceEpoch * 1000,
        isUtc: true,
      ).isBefore(cutoff.toUtc());

  @override
  Future<List<FileEntry>> listDirectory(String relativePath) async {
    final sftp = await _connection;
    final names = await _withOperationTimeout(
      sftp.listdir(_remote(relativePath)),
      'Loading folder',
    );
    final entries = names
        .where((item) => item.filename != '.' && item.filename != '..')
        .where((item) => item.filename != '__jet2drop_transfer')
        .where((item) => !item.filename.startsWith('.jet2drop-'))
        .where((item) => !item.filename.contains('.jet2drop-upload-'))
        .where((item) => !item.filename.contains('.jet2drop-download-'))
        .where((item) => !item.filename.contains('.jet2drop-backup-'))
        .map((item) {
          final isDirectory = item.attr.mode?.type == SftpFileType.directory;
          return FileEntry(
            path: joinRelativePath(relativePath, item.filename),
            name: item.filename,
            type: isDirectory ? FileEntryType.directory : FileEntryType.file,
            size: item.attr.size ?? 0,
            modifiedAt: DateTime.fromMillisecondsSinceEpoch(
              (item.attr.modifyTime ?? 0) * 1000,
              isUtc: true,
            ).toLocal(),
          );
        })
        .toList();
    entries.sort((left, right) {
      if (left.type != right.type) return left.isDirectory ? -1 : 1;
      return left.name.toLowerCase().compareTo(right.name.toLowerCase());
    });
    return entries;
  }

  @override
  Future<void> createDirectory(String relativePath, String name) async {
    final cleanName = normalizeRelativePath(name);
    if (cleanName.contains('/')) {
      throw ArgumentError('Folder name must be one segment.');
    }
    await (await _connection).mkdir(
      _remote(joinRelativePath(relativePath, cleanName)),
    );
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
    final sftp = await _connection;
    final remotePath = _remote(safePath);
    final stat = await sftp.stat(remotePath);
    if (stat.mode?.type != SftpFileType.directory) {
      await sftp.remove(remotePath);
      return;
    }
    if (recursive) {
      await _deleteDirectoryRecursively(sftp, remotePath);
    } else {
      await sftp.rmdir(remotePath);
    }
  }

  Future<void> _deleteDirectoryRecursively(SftpClient sftp, String path) async {
    final children = await sftp.listdir(path);
    for (final child in children) {
      if (child.filename == '.' || child.filename == '..') continue;
      final childPath = '$path/${child.filename}';
      if (child.attr.mode?.type == SftpFileType.directory) {
        await _deleteDirectoryRecursively(sftp, childPath);
      } else {
        await sftp.remove(childPath);
      }
    }
    await sftp.rmdir(path);
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
    final cleanName = normalizeRelativePath(targetName);
    if (cleanName.contains('/')) {
      throw ArgumentError('File name must be one segment.');
    }
    final sftp = await _connection;
    final destination = _remote(joinRelativePath(targetDirectory, cleanName));
    final safeResumeId = resumeId == null
        ? uniqueSuffix()
        : resumeId.replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_');
    final temporary = '$destination.jet2drop-upload-$safeResumeId.part';
    final total = await source.length();
    var offset = 0;
    if (resumeId != null) {
      try {
        offset = (await sftp.stat(temporary)).size ?? 0;
      } catch (_) {}
      if (offset > total) {
        try {
          await sftp.remove(temporary);
        } catch (_) {}
        offset = 0;
      }
    }
    final handle = await _withOperationTimeout(
      sftp.open(
        temporary,
        mode: offset == 0
            ? SftpFileOpenMode.create |
                  SftpFileOpenMode.truncate |
                  SftpFileOpenMode.write
            : SftpFileOpenMode.create | SftpFileOpenMode.write,
      ),
      'Preparing upload',
    );
    try {
      final checksum = onChecksum == null ? null : Sha256Accumulator();
      if (checksum != null && offset > 0) {
        await for (final chunk in source.openRead(0, offset)) {
          checksum.add(chunk);
        }
      }
      Timer? inactivityTimer;
      final inactivity = Completer<void>();
      void resetInactivityTimer() {
        inactivityTimer?.cancel();
        inactivityTimer = Timer(_operationTimeout, () {
          if (!inactivity.isCompleted) {
            inactivity.completeError(
              TimeoutException(
                'Uploading file made no progress for ${_operationTimeout.inSeconds} seconds.',
              ),
            );
          }
        });
      }

      final writer = handle.write(
        source.openRead(offset).asyncExpand((chunk) async* {
          await control?.checkpoint();
          checksum?.add(chunk);
          yield chunk is Uint8List ? chunk : Uint8List.fromList(chunk);
        }),
        onProgress: (value) {
          resetInactivityTimer();
          onProgress?.call(offset + value, total);
        },
        offset: offset,
      );
      onProgress?.call(offset, total);
      resetInactivityTimer();
      control?.bind(
        onPause: writer.pause,
        onResume: writer.resume,
        onCancel: writer.abort,
      );
      try {
        await Future.any<void>([writer.done, inactivity.future]);
      } finally {
        inactivityTimer?.cancel();
      }
      await control?.checkpoint();
      await _withOperationTimeout(handle.close(), 'Finalizing upload');
      if (checksum != null) onChecksum!(checksum.close());
      var destinationExists = false;
      try {
        await sftp.stat(destination);
        destinationExists = true;
      } catch (_) {}
      if (destinationExists && !overwrite) {
        throw FileSystemException('A file with the same name already exists.');
      }
      final backup = '$destination.jet2drop-backup-${uniqueSuffix()}';
      if (destinationExists) await sftp.rename(destination, backup);
      try {
        await _withOperationTimeout(
          sftp.rename(temporary, destination),
          'Publishing upload',
        );
      } catch (_) {
        if (destinationExists) {
          try {
            await sftp.rename(backup, destination);
          } catch (_) {}
        }
        rethrow;
      }
      if (destinationExists) {
        try {
          await sftp.remove(backup);
        } catch (_) {
          // The destination is already safely published. Maintenance can
          // remove an orphaned backup later.
        }
      }
    } catch (exception) {
      try {
        await _withOperationTimeout(handle.close(), 'Closing failed upload');
      } catch (_) {}
      if (resumeId == null ||
          exception is TransferCancelled ||
          control?.isCancelled == true) {
        try {
          await _withOperationTimeout(
            sftp.remove(temporary),
            'Cleaning failed upload',
          );
        } catch (_) {}
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
    final cleanName = normalizeRelativePath(targetName);
    final safeResumeId = resumeId.replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_');
    final destination = _remote(joinRelativePath(targetDirectory, cleanName));
    try {
      await (await _connection).remove(
        '$destination.jet2drop-upload-$safeResumeId.part',
      );
    } catch (_) {
      // A completed or never-started task has no partial file to discard.
    }
  }

  @override
  Future<void> downloadFile({
    required String remotePath,
    required File target,
    String? resumeId,
    ProgressCallback? onProgress,
    ChecksumCallback? onChecksum,
    TransferControl? control,
  }) async {
    final sftp = await _connection;
    await target.parent.create(recursive: true);
    final remote = _remote(remotePath);
    final stat = await sftp.stat(remote);
    final total = stat.size ?? 0;
    final safeResumeId = resumeId == null
        ? uniqueSuffix()
        : resumeId.replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_');
    final temporary = File(
      '${target.path}.jet2drop-download-$safeResumeId.part',
    );
    var written = resumeId != null && await temporary.exists()
        ? await temporary.length()
        : 0;
    if (written > total) {
      await temporary.delete();
      written = 0;
    }
    final sink = temporary.openWrite(
      mode: written == 0 ? FileMode.write : FileMode.append,
    );
    SftpFile? handle;
    final checksum = onChecksum == null ? null : Sha256Accumulator();
    try {
      // Keep opening the remote handle inside the cleanup boundary. If the
      // target disappears between stat and open, the local partial sink must
      // still be closed so a retry can safely reuse it.
      final openedHandle = await _withOperationTimeout(
        sftp.open(remote, mode: SftpFileOpenMode.read),
        'Preparing download',
      );
      handle = openedHandle;
      if (checksum != null && written > 0) {
        await for (final chunk in temporary.openRead(0, written)) {
          checksum.add(chunk);
        }
      }
      onProgress?.call(written, total);
      await for (final chunk
          in openedHandle
              .read(
                length: total - written,
                offset: written,
                chunkSize: _downloadChunkSize,
                maxPendingRequests: _downloadPendingRequests,
              )
              .timeout(
                _operationTimeout,
                onTimeout: (sink) => sink.addError(
                  TimeoutException(
                    'Downloading file made no progress for ${_operationTimeout.inSeconds} seconds.',
                  ),
                ),
              )) {
        await control?.checkpoint();
        checksum?.add(chunk);
        sink.add(chunk);
        written += chunk.length;
        onProgress?.call(written, total);
      }
      await sink.flush();
      await sink.close();
      if (checksum != null) onChecksum!(checksum.close());
      await _withOperationTimeout(openedHandle.close(), 'Finalizing download');
      await control?.checkpoint();
      final backup = File('${target.path}.jet2drop-backup-${uniqueSuffix()}');
      final hadTarget = await target.exists();
      if (hadTarget) await target.rename(backup.path);
      try {
        await temporary.rename(target.path);
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
      try {
        await sink.close();
      } catch (_) {}
      try {
        await handle?.close();
      } catch (_) {}
      if ((resumeId == null ||
              exception is TransferCancelled ||
              control?.isCancelled == true) &&
          await temporary.exists()) {
        await temporary.delete();
      }
      rethrow;
    }
  }

  @override
  Future<File> materializeForPreview(
    String relativePath, {
    TransferControl? control,
  }) async {
    final target = File(
      '${cacheDirectory.path}${Platform.pathSeparator}${uniqueSuffix()}',
    );
    await downloadFile(
      remotePath: relativePath,
      target: target,
      control: control,
    );
    return target;
  }

  @override
  Future<void> dispose() async {
    _client?.close();
    _client = null;
    _sftp = null;
  }
}
