import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart';

import '../core/models/file_entry.dart';
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
    } catch (_) {
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
    ProgressCallback? onProgress,
    TransferControl? control,
  }) async {
    final cleanName = normalizeRelativePath(targetName);
    if (cleanName.contains('/')) {
      throw ArgumentError('File name must be one segment.');
    }
    final sftp = await _connection;
    final destination = _remote(joinRelativePath(targetDirectory, cleanName));
    final temporary = '$destination.jet2drop-upload-${uniqueSuffix()}.part';
    final total = await source.length();
    final handle = await _withOperationTimeout(
      sftp.open(
        temporary,
        mode:
            SftpFileOpenMode.create |
            SftpFileOpenMode.truncate |
            SftpFileOpenMode.write,
      ),
      'Preparing upload',
    );
    try {
      final writer = handle.write(
        source.openRead().asyncExpand((chunk) async* {
          await control?.checkpoint();
          yield Uint8List.fromList(chunk);
        }),
        onProgress: (value) {
          onProgress?.call(value, total);
        },
      );
      control?.bind(
        onPause: writer.pause,
        onResume: writer.resume,
        onCancel: writer.abort,
      );
      await _withOperationTimeout(writer.done, 'Uploading file');
      await control?.checkpoint();
      await _withOperationTimeout(handle.close(), 'Finalizing upload');
      await _withOperationTimeout(
        sftp.rename(temporary, destination),
        'Publishing upload',
      );
    } catch (_) {
      try {
        await _withOperationTimeout(handle.close(), 'Closing failed upload');
      } catch (_) {}
      try {
        await _withOperationTimeout(
          sftp.remove(temporary),
          'Cleaning failed upload',
        );
      } catch (_) {}
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
    final sftp = await _connection;
    await target.parent.create(recursive: true);
    final remote = _remote(remotePath);
    final stat = await sftp.stat(remote);
    final total = stat.size ?? 0;
    final temporary = File(
      '${target.path}.jet2drop-download-${uniqueSuffix()}.part',
    );
    final sink = temporary.openWrite();
    final handle = await sftp.open(remote, mode: SftpFileOpenMode.read);
    var written = 0;
    try {
      await for (final chunk in handle.read()) {
        await control?.checkpoint();
        sink.add(chunk);
        written += chunk.length;
        onProgress?.call(written, total);
      }
      await sink.flush();
      await sink.close();
      await handle.close();
      await control?.checkpoint();
      if (await target.exists()) await target.delete();
      await temporary.rename(target.path);
    } catch (_) {
      await sink.close();
      await handle.close();
      if (await temporary.exists()) await temporary.delete();
      rethrow;
    }
  }

  @override
  Future<File> materializeForPreview(String relativePath) async {
    final target = File(
      '${cacheDirectory.path}${Platform.pathSeparator}${uniqueSuffix()}',
    );
    await downloadFile(remotePath: relativePath, target: target);
    return target;
  }

  @override
  Future<void> dispose() async {
    _client?.close();
    _client = null;
    _sftp = null;
  }
}
