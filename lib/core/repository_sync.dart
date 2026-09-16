import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'checksum.dart';
import 'models/file_entry.dart';
import 'path_utils.dart';
import 'repository_gateway.dart';

/// The only user-visible synchronization states.  The explanation for a
/// state is carried by [RepositorySyncSnapshot.message], not by adding more
/// states here.
enum RepositorySyncStatus { synced, changed, syncing, needsAttention }

enum RepositorySyncDirection { pull, push }

enum RepositorySyncConflictType {
  modifiedModified,
  modifiedDeleted,
  deletedModified,
  typeChanged,
}

class RepositorySyncConflict {
  const RepositorySyncConflict({
    required this.path,
    required this.type,
    required this.local,
    required this.remote,
    required this.baseline,
  });

  final String path;
  final RepositorySyncConflictType type;
  final RepositorySyncEntry? local;
  final RepositorySyncEntry? remote;
  final RepositorySyncEntry? baseline;

  String get description => switch (type) {
    RepositorySyncConflictType.modifiedModified => '本地和远端都已修改',
    RepositorySyncConflictType.modifiedDeleted => '本地修改而远端已删除',
    RepositorySyncConflictType.deletedModified => '本地已删除而远端已修改',
    RepositorySyncConflictType.typeChanged => '同一路径的文件/文件夹类型发生变化',
  };

  Map<String, Object?> toJson() => {
    'path': path,
    'type': type.name,
    'local': local?.toJson(),
    'remote': remote?.toJson(),
    'baseline': baseline?.toJson(),
  };
}

/// A compact, serializable description of one repository path.
class RepositorySyncEntry {
  const RepositorySyncEntry({
    required this.path,
    required this.type,
    required this.size,
    required this.modifiedAt,
    this.sha256,
  });

  final String path;
  final FileEntryType type;
  final int size;
  final DateTime modifiedAt;
  final String? sha256;

  bool get isDirectory => type == FileEntryType.directory;

  RepositorySyncEntry copyWith({
    String? path,
    FileEntryType? type,
    int? size,
    DateTime? modifiedAt,
    Object? sha256 = _missing,
  }) => RepositorySyncEntry(
    path: path ?? this.path,
    type: type ?? this.type,
    size: size ?? this.size,
    modifiedAt: modifiedAt ?? this.modifiedAt,
    sha256: identical(sha256, _missing) ? this.sha256 : sha256 as String?,
  );

  Map<String, Object?> toJson() => {
    'p': path,
    't': type == FileEntryType.directory ? 'd' : 'f',
    's': size,
    // Milliseconds are enough for cross-platform repository metadata and keep
    // the manifest substantially smaller than full ISO strings.
    'm': modifiedAt.toUtc().millisecondsSinceEpoch,
    if (sha256 != null) 'h': sha256,
  };

  factory RepositorySyncEntry.fromJson(Map<String, dynamic> json) {
    final path = normalizeRelativePath(json['p'] as String);
    if (path.isEmpty) throw const FormatException('Manifest path is empty.');
    final type = switch (json['t']) {
      'd' => FileEntryType.directory,
      'f' => FileEntryType.file,
      _ => throw const FormatException('Manifest entry type is invalid.'),
    };
    final size = (json['s'] as num?)?.toInt();
    final milliseconds = (json['m'] as num?)?.toInt();
    if (size == null || size < 0 || milliseconds == null) {
      throw const FormatException('Manifest entry metadata is invalid.');
    }
    final hash = json['h'] as String?;
    if (hash != null && !RegExp(r'^[0-9a-fA-F]{64}$').hasMatch(hash)) {
      throw const FormatException('Manifest entry checksum is invalid.');
    }
    return RepositorySyncEntry(
      path: path,
      type: type,
      size: size,
      modifiedAt: DateTime.fromMillisecondsSinceEpoch(
        milliseconds,
        isUtc: true,
      ),
      sha256: hash?.toLowerCase(),
    );
  }

  @override
  bool operator ==(Object other) =>
      other is RepositorySyncEntry &&
      path == other.path &&
      type == other.type &&
      size == other.size &&
      modifiedAt.toUtc().millisecondsSinceEpoch ==
          other.modifiedAt.toUtc().millisecondsSinceEpoch &&
      sha256 == other.sha256;

  @override
  int get hashCode => Object.hash(
    path,
    type,
    size,
    modifiedAt.toUtc().millisecondsSinceEpoch,
    sha256,
  );

  @override
  String toString() =>
      '$path ${type.name} size=$size m=${modifiedAt.toUtc().millisecondsSinceEpoch} h=$sha256';
}

const _missing = Object();

bool _sameSyncEntry(RepositorySyncEntry? left, RepositorySyncEntry? right) {
  if (left == null || right == null) return left == right;
  if (left.type != right.type) return false;
  if (left.isDirectory && right.isDirectory) return true;
  if (left.size != right.size) return false;
  if (left.sha256 != null && right.sha256 != null) {
    return left.sha256 == right.sha256;
  }
  return left.modifiedAt.toUtc().millisecondsSinceEpoch ==
      right.modifiedAt.toUtc().millisecondsSinceEpoch;
}

class RepositorySyncManifest {
  const RepositorySyncManifest({
    required this.revision,
    required this.createdAt,
    required this.entries,
  });

  static const schemaVersion = 1;

  final int revision;
  final DateTime createdAt;
  final Map<String, RepositorySyncEntry> entries;

  RepositorySyncManifest copyWith({
    int? revision,
    DateTime? createdAt,
    Map<String, RepositorySyncEntry>? entries,
  }) => RepositorySyncManifest(
    revision: revision ?? this.revision,
    createdAt: createdAt ?? this.createdAt,
    entries: Map.unmodifiable(entries ?? this.entries),
  );

  Map<String, Object?> toJson() => {
    'v': schemaVersion,
    'r': revision,
    't': createdAt.toUtc().millisecondsSinceEpoch,
    'e': entries.values.toList(growable: false)
      ..sort((left, right) => left.path.compareTo(right.path)),
  };

  String encode() => jsonEncode(toJson());

  factory RepositorySyncManifest.fromJson(Map<String, dynamic> json) {
    if (json['v'] != schemaVersion) {
      throw const FormatException('Unsupported repository manifest version.');
    }
    final revision = (json['r'] as num?)?.toInt();
    final milliseconds = (json['t'] as num?)?.toInt();
    final rawEntries = json['e'];
    if (revision == null ||
        revision < 0 ||
        milliseconds == null ||
        rawEntries is! List) {
      throw const FormatException('Repository manifest is malformed.');
    }
    final entries = <String, RepositorySyncEntry>{};
    for (final raw in rawEntries) {
      if (raw is! Map) {
        throw const FormatException('Manifest entry is malformed.');
      }
      final entry = RepositorySyncEntry.fromJson(
        Map<String, dynamic>.from(raw),
      );
      if (entries.containsKey(entry.path)) {
        throw const FormatException('Manifest contains duplicate paths.');
      }
      entries[entry.path] = entry;
    }
    return RepositorySyncManifest(
      revision: revision,
      createdAt: DateTime.fromMillisecondsSinceEpoch(milliseconds, isUtc: true),
      entries: Map.unmodifiable(entries),
    );
  }

  factory RepositorySyncManifest.decode(String value) =>
      RepositorySyncManifest.fromJson(
        Map<String, dynamic>.from(jsonDecode(value) as Map),
      );
}

/// Small file-backed store used by tests and by integrations that need to
/// inspect a manifest without running a synchronization operation. A damaged
/// file is moved aside and reported as missing so the next successful sync can
/// rebuild it.
class RepositorySyncManifestStore {
  const RepositorySyncManifestStore(this.file);

  final File file;

  Future<RepositorySyncManifest?> read() async {
    if (!await file.exists()) return null;
    try {
      return RepositorySyncManifest.decode(await file.readAsString());
    } catch (_) {
      try {
        await file.rename('${file.path}.corrupt-${uniqueSuffix()}');
      } catch (_) {}
      return null;
    }
  }

  Future<void> write(RepositorySyncManifest manifest) async {
    await file.parent.create(recursive: true);
    final temporary = File('${file.path}.part-${uniqueSuffix()}');
    await temporary.writeAsString(manifest.encode(), flush: true);
    final backup = File('${file.path}.jet2drop-backup-${uniqueSuffix()}');
    final hadFile = await file.exists();
    if (hadFile) await file.rename(backup.path);
    try {
      await temporary.rename(file.path);
    } catch (_) {
      if (hadFile && await backup.exists()) await backup.rename(file.path);
      rethrow;
    }
    if (hadFile && await backup.exists()) {
      try {
        await backup.delete();
      } catch (_) {}
    }
  }
}

class RepositorySyncSnapshot {
  const RepositorySyncSnapshot({
    required this.status,
    required this.message,
    required this.local,
    required this.remote,
    required this.baseline,
    required this.conflicts,
    required this.remoteRevision,
  });

  final RepositorySyncStatus status;
  final String message;
  final Map<String, RepositorySyncEntry> local;
  final Map<String, RepositorySyncEntry> remote;
  final Map<String, RepositorySyncEntry> baseline;
  final List<RepositorySyncConflict> conflicts;
  final int? remoteRevision;

  bool get hasChanges => conflicts.isNotEmpty || _changedPaths.isNotEmpty;

  Set<String> get _changedPaths {
    final paths = <String>{...local.keys, ...remote.keys, ...baseline.keys};
    return paths
        .where(
          (path) =>
              !_sameSyncEntry(local[path], baseline[path]) ||
              !_sameSyncEntry(remote[path], baseline[path]),
        )
        .toSet();
  }
}

class RepositorySyncResult {
  const RepositorySyncResult({
    required this.snapshot,
    required this.changedPaths,
    required this.conflicts,
    required this.applied,
  });

  final RepositorySyncSnapshot snapshot;
  final Set<String> changedPaths;
  final List<RepositorySyncConflict> conflicts;
  final bool applied;
}

class RepositorySyncException implements Exception {
  const RepositorySyncException(this.message, {this.conflicts = const []});

  final String message;
  final List<RepositorySyncConflict> conflicts;

  @override
  String toString() => message;
}

class RepositorySyncVersionException extends RepositorySyncException {
  const RepositorySyncVersionException(super.message);
}

/// A three-way synchronizer for one local mirror and the Windows repository.
///
/// The remote side is deliberately represented by [RepositoryGateway].  The
/// production Mac path uses the existing serialized SFTP gateway; tests can
/// use [LocalRepositoryGateway] or a small in-memory gateway.  No rclone
/// process is involved: files are streamed through the existing gateway and
/// published with its atomic temporary-file primitives.
class RepositorySyncEngine {
  RepositorySyncEngine({
    required this.localRoot,
    required this.remote,
    Directory? metadataRoot,
    String? ownerId,
    DateTime Function()? now,
    this.trustRemoteManifest = true,
    this.lockTimeout = const Duration(minutes: 10),
  }) : metadataRoot =
           metadataRoot ?? Directory(_defaultMetadataPath(localRoot)),
       ownerId = ownerId ?? 'jet2drop-${uniqueSuffix()}',
       _now = now ?? DateTime.now;

  static const remoteMetadataRoot = '__jet2drop_sync';
  static const remoteManifestName = 'manifest.json';
  static const remoteLockName = 'lock.json';
  static const remoteStagingName = 'staging';
  static const localMetadataName = '.jet2drop_sync';
  static const baselineName = 'baseline.json';

  final Directory localRoot;
  final RepositoryGateway remote;
  final Directory metadataRoot;
  final String ownerId;
  final Duration lockTimeout;
  final bool trustRemoteManifest;
  final DateTime Function() _now;

  Future<void>? _operation;
  RepositorySyncSnapshot? _lastSnapshot;

  static String _defaultMetadataPath(Directory root) =>
      '${root.path}${Platform.pathSeparator}$localMetadataName';

  RepositorySyncSnapshot? get lastSnapshot => _lastSnapshot;

  Future<RepositorySyncSnapshot> inspect() => _enqueue(_inspectInternal);

  Future<RepositorySyncResult> pull() =>
      _enqueue(() => _synchronize(RepositorySyncDirection.pull));

  Future<RepositorySyncResult> push() =>
      _enqueue(() => _synchronize(RepositorySyncDirection.push));

  Future<T> _enqueue<T>(Future<T> Function() operation) {
    final previous = _operation ?? Future<void>.value();
    final result = previous.then((_) => operation());
    _operation = result.then<void>((_) {}, onError: (_, _) {});
    return result;
  }

  Future<RepositorySyncSnapshot> _inspectInternal() async {
    await _recoverLocalTransactions();
    final baseline =
        await _readBaseline() ?? const <String, RepositorySyncEntry>{};
    final local = await _scanLocal();
    final remoteState = await _readRemoteState();
    final comparison = await _compare(
      local: local,
      remote: remoteState.entries,
      baseline: baseline,
    );
    final snapshot = _snapshotFromComparison(
      comparison,
      baseline: baseline,
      remoteRevision: remoteState.manifest?.revision,
    );
    _lastSnapshot = snapshot;
    return snapshot;
  }

  Future<RepositorySyncResult> _synchronize(
    RepositorySyncDirection direction,
  ) async {
    await _recoverLocalTransactions();
    final baseline = await _readBaseline();
    final local = await _scanLocal();
    final remoteState = await _readRemoteState();
    var comparison = await _compare(
      local: local,
      remote: remoteState.entries,
      baseline: baseline ?? const <String, RepositorySyncEntry>{},
    );
    final before = _snapshotFromComparison(
      comparison,
      baseline: baseline ?? const <String, RepositorySyncEntry>{},
      remoteRevision: remoteState.manifest?.revision,
    );
    if (comparison.conflicts.isNotEmpty) {
      _lastSnapshot = before;
      return RepositorySyncResult(
        snapshot: before,
        changedPaths: comparison.changedPaths,
        conflicts: comparison.conflicts,
        applied: false,
      );
    }

    final planned = _plan(
      direction,
      local: comparison.local,
      remote: comparison.remote,
      baseline: baseline ?? const <String, RepositorySyncEntry>{},
    );
    if (planned.isEmpty) {
      // A manual operation must not consume the other side's changes. For
      // example, pressing Pull while only the local copy is modified should
      // leave the baseline intact so the user can still push that change.
      if (comparison.changedPaths.isNotEmpty) {
        _lastSnapshot = before;
        return RepositorySyncResult(
          snapshot: before,
          changedPaths: comparison.changedPaths,
          conflicts: const [],
          applied: false,
        );
      }
      final synced = await _finishWithCurrentBaseline(
        local: local,
        remote: remoteState.entries,
        remoteManifest: remoteState.manifest,
      );
      _lastSnapshot = synced;
      return RepositorySyncResult(
        snapshot: synced,
        changedPaths: const {},
        conflicts: const [],
        applied: true,
      );
    }

    // Prepare files without holding the repository lock. A staging directory
    // is invisible to Windows/Android and can be discarded safely if the
    // commit guard later detects a competing change.
    _PreparedPull? preparedPull;
    _PreparedPush? preparedPush;
    try {
      if (direction == RepositorySyncDirection.pull) {
        preparedPull = await _stagePull(planned);
      } else {
        preparedPush = await _stagePush(planned);
      }
    } catch (_) {
      await preparedPull?.dispose();
      await preparedPush?.dispose(remote);
      rethrow;
    }

    // Only the short final commit window is locked. The second scan below is
    // mandatory: it prevents a stale staging upload from replacing a newer
    // Windows/Explorer change.
    late final _SyncLock lock;
    try {
      lock = await _acquireLock();
    } catch (_) {
      await preparedPull?.dispose();
      await preparedPush?.dispose(remote);
      rethrow;
    }
    try {
      await _recoverRemoteTransactions();
      final lockedBaseline = await _readBaseline();
      final lockedLocal = await _scanLocal();
      final lockedRemote = await _readRemoteState();
      final lockedBaselineEntries =
          lockedBaseline ?? const <String, RepositorySyncEntry>{};
      if (!_mapsEquivalent(lockedLocal, local) ||
          !_mapsEquivalent(lockedRemote.entries, remoteState.entries) ||
          lockedRemote.manifest?.revision != remoteState.manifest?.revision) {
        throw const RepositorySyncVersionException('同步准备期间仓库发生变化，请重新检查后再试。');
      }
      comparison = await _compare(
        local: lockedLocal,
        remote: lockedRemote.entries,
        baseline: lockedBaselineEntries,
      );
      if (comparison.conflicts.isNotEmpty) {
        final snapshot = _snapshotFromComparison(
          comparison,
          baseline: lockedBaselineEntries,
          remoteRevision: lockedRemote.manifest?.revision,
        );
        _lastSnapshot = snapshot;
        return RepositorySyncResult(
          snapshot: snapshot,
          changedPaths: comparison.changedPaths,
          conflicts: comparison.conflicts,
          applied: false,
        );
      }
      final lockedPlan = _plan(
        direction,
        local: comparison.local,
        remote: comparison.remote,
        baseline: lockedBaselineEntries,
      );
      if (!_sameActionPlan(planned, lockedPlan)) {
        throw const RepositorySyncVersionException('同步准备期间变更列表发生变化，请重新检查后再试。');
      }

      Map<String, String> settledHashes = const {};
      if (direction == RepositorySyncDirection.pull) {
        await _commitPull(preparedPull!);
        settledHashes = preparedPull.hashes;
      } else {
        settledHashes = await _commitPush(
          preparedPush!,
          remoteManifest: lockedRemote.manifest,
          remoteBefore: lockedRemote.entries,
        );
      }

      final finalLocal = await _scanLocal();
      final finalRemote = await _scanRemote();
      for (final entry in settledHashes.entries) {
        final localEntry = finalLocal[entry.key];
        final remoteEntry = finalRemote[entry.key];
        if (localEntry != null && remoteEntry != null) {
          final localWithHash = localEntry.copyWith(sha256: entry.value);
          final remoteWithHash = remoteEntry.copyWith(sha256: entry.value);
          finalLocal[entry.key] = localWithHash;
          finalRemote[entry.key] = remoteWithHash;
        }
      }
      final finalManifest = RepositorySyncManifest(
        revision: direction == RepositorySyncDirection.push
            ? (lockedRemote.manifest?.revision ?? 0) + 1
            : (lockedRemote.manifest?.revision ?? 0),
        createdAt: _now().toUtc(),
        entries: finalRemote,
      );
      // The baseline is the same snapshot as the successful remote state.
      // Keep it only after all file changes have been atomically published.
      // A successful pull also repairs a stale/missing accelerator manifest
      // after Windows Explorer or another external writer changed formal
      // files. The revision stays unchanged because the pull did not publish
      // a new remote version.
      await _writeBaseline(finalRemote);
      // The local baseline is the safety-critical record for the next
      // three-way comparison. Write it first so a transient metadata upload
      // failure cannot make the committed files look like a fresh conflict
      // on the next retry; the remote manifest remains an accelerator and is
      // repaired by the next successful operation if needed.
      await _writeRemoteManifest(finalManifest);
      final synced = _snapshotFromComparison(
        await _compare(
          local: finalLocal,
          remote: finalRemote,
          baseline: finalRemote,
        ),
        baseline: finalRemote,
        remoteRevision: finalManifest.revision,
      );
      _lastSnapshot = synced;
      return RepositorySyncResult(
        snapshot: synced,
        changedPaths: planned.map((item) => item.path).toSet(),
        conflicts: const [],
        applied: true,
      );
    } finally {
      await _releaseLock(lock);
      await preparedPull?.dispose();
      await preparedPush?.dispose(remote);
    }
  }

  Future<RepositorySyncSnapshot> _finishWithCurrentBaseline({
    required Map<String, RepositorySyncEntry> local,
    required Map<String, RepositorySyncEntry> remote,
    required RepositorySyncManifest? remoteManifest,
  }) async {
    final baseline = remote;
    await _writeBaseline(baseline);
    return _snapshotFromComparison(
      await _compare(local: local, remote: remote, baseline: baseline),
      baseline: baseline,
      remoteRevision: remoteManifest?.revision,
    );
  }

  List<_SyncAction> _plan(
    RepositorySyncDirection direction, {
    required Map<String, RepositorySyncEntry> local,
    required Map<String, RepositorySyncEntry> remote,
    required Map<String, RepositorySyncEntry> baseline,
  }) {
    final actions = <_SyncAction>[];
    final paths = <String>{...local.keys, ...remote.keys, ...baseline.keys};
    for (final path in paths) {
      final l = local[path];
      final r = remote[path];
      final b = baseline[path];
      final localChanged = !_sameSyncEntry(l, b);
      final remoteChanged = !_sameSyncEntry(r, b);
      if (!localChanged && !remoteChanged) continue;
      if (localChanged && remoteChanged) {
        // Equal contents are already reconciled by _compare (which hashes
        // ambiguous candidates), so reaching this branch means a conflict.
        continue;
      }
      if (direction == RepositorySyncDirection.pull && remoteChanged) {
        actions.add(_SyncAction.pull(path: path, source: r, destination: l));
      } else if (direction == RepositorySyncDirection.push && localChanged) {
        actions.add(_SyncAction.push(path: path, source: l, destination: r));
      }
    }
    actions.sort((left, right) {
      // Files first on upload/download; directory creation is handled as a
      // separate pass and deletes are always performed last.
      final leftRank = left.source == null
          ? 2
          : left.source!.isDirectory
          ? 0
          : 1;
      final rightRank = right.source == null
          ? 2
          : right.source!.isDirectory
          ? 0
          : 1;
      final rank = leftRank.compareTo(rightRank);
      return rank == 0 ? left.path.compareTo(right.path) : rank;
    });
    return actions;
  }

  Future<_PreparedPull> _stagePull(List<_SyncAction> actions) async {
    final staging = Directory(
      '${metadataRoot.path}${Platform.pathSeparator}staging${Platform.pathSeparator}${uniqueSuffix()}',
    );
    await staging.create(recursive: true);
    final hashes = <String, String>{};
    try {
      for (final action in actions) {
        final source = action.source;
        if (source == null || source.isDirectory) continue;
        final target = File(_join(staging.path, action.path));
        await target.parent.create(recursive: true);
        String? downloadedHash;
        await remote.downloadFile(
          remotePath: action.path,
          target: target,
          onChecksum: (value) => downloadedHash = value,
        );
        // Production gateways calculate this while streaming the download.
        // Keep a fallback for test/custom gateways that do not implement the
        // optional callback, without making the normal path read the file a
        // second time.
        final hash = downloadedHash ?? await _hashFile(target);
        if (source.sha256 != null && source.sha256 != hash) {
          throw RepositorySyncException('拉取文件校验失败：${action.path}');
        }
        hashes[action.path] = hash;
      }
      return _PreparedPull(staging: staging, actions: actions, hashes: hashes);
    } catch (_) {
      if (await staging.exists()) await staging.delete(recursive: true);
      rethrow;
    }
  }

  Future<void> _commitPull(_PreparedPull prepared) async {
    final transactionId = uniqueSuffix();
    final journal = File(
      '${metadataRoot.path}${Platform.pathSeparator}pull-transaction-$transactionId.json',
    );
    final transaction = _LocalTransaction(
      stagingPath: prepared.staging.path,
      status: 'committing',
      records: [],
    );
    await _writeLocalTransaction(journal, transaction);
    try {
      Future<_LocalTransactionRecord> prepareRecord(
        String path, {
        required String kind,
      }) async {
        final backupPath = kind == 'mkdir'
            ? ''
            : '$path.jet2drop-backup-$transactionId';
        final record = _LocalTransactionRecord(
          path: path,
          backupPath: backupPath,
          kind: kind,
          hadTarget: await _localEntryExists(path),
        );
        transaction.records.add(record);
        // Record the intended operation before touching the formal local
        // copy. This makes a process interruption recoverable as well as a
        // normal I/O exception during the commit.
        await _writeLocalTransaction(journal, transaction);
        if (record.hadTarget && kind != 'mkdir') {
          await _moveLocalEntry(_localPath(path), _localPath(backupPath));
          record.backupMoved = true;
          await _writeLocalTransaction(journal, transaction);
        }
        return record;
      }

      Future<void> persistJournal() =>
          _writeLocalTransaction(journal, transaction);

      // Create directories first, then replace files. Directory/file type
      // changes are rejected during comparison, so an existing directory is
      // never silently removed here.
      for (final action in prepared.actions.where(
        (item) => item.source?.isDirectory == true,
      )) {
        final record = await prepareRecord(action.path, kind: 'mkdir');
        await Directory(_localPath(action.path)).create(recursive: true);
        record.published = true;
        await persistJournal();
      }
      for (final action in prepared.actions.where(
        (item) => item.source != null && !item.source!.isDirectory,
      )) {
        final source = action.source!;
        final record = await prepareRecord(action.path, kind: 'replace');
        final stagedFile = File(_join(prepared.staging.path, action.path));
        final destination = File(_localPath(action.path));
        await destination.parent.create(recursive: true);
        await _moveLocalEntry(stagedFile.path, destination.path);
        record.published = true;
        await persistJournal();
        try {
          await destination.setLastModified(source.modifiedAt);
        } catch (_) {}
      }
      // Deleting last means a failed download/checksum or failed replacement
      // never destroys the user's existing local copy.
      for (final path in _deleteDeepestFirst(
        prepared.actions
            .where((item) => item.source == null)
            .map((item) => item.path),
      )) {
        final record = await prepareRecord(path, kind: 'delete');
        record.published = true;
        await persistJournal();
      }
      transaction.status = 'committed';
      await _writeLocalTransaction(journal, transaction);
      try {
        await _cleanupLocalTransaction(journal, transaction);
      } catch (_) {
        // The formal copy is committed. A leftover committed journal/backups
        // are safe and will be cleaned on the next inspect/sync.
      }
    } catch (_) {
      try {
        await _rollbackLocalTransaction(transaction);
        await _cleanupLocalTransaction(journal, transaction);
      } catch (_) {
        // Keep the journal/backups for the next inspect or sync attempt. The
        // caller still receives the original commit failure.
      }
      rethrow;
    }
  }

  Future<_PreparedPush> _stagePush(List<_SyncAction> actions) async {
    final stagingPath =
        '$remoteMetadataRoot/$remoteStagingName/${uniqueSuffix()}';
    final pushedHashes = <String, String>{};
    final stagedSizes = <String, int>{};
    final stagedParents = <String>{};
    try {
      await _ensureRemoteDirectory(stagingPath);
      for (final action in actions) {
        final source = action.source;
        if (source == null) continue;
        if (source.isDirectory) {
          await _ensureRemoteDirectory(_join(stagingPath, action.path));
          continue;
        }
        await _ensureRemoteDirectory(
          _join(stagingPath, _parentPath(action.path)),
        );
        final file = File(_localPath(action.path));
        final stagedPath = _join(stagingPath, action.path);
        final fileSize = await file.length();
        String? uploadedHash;
        await remote.uploadFile(
          source: file,
          targetDirectory: _parentPath(stagedPath),
          targetName: _baseName(stagedPath),
          overwrite: true,
          onChecksum: (value) => uploadedHash = value,
        );
        if (uploadedHash == null) {
          throw RepositorySyncException('推送文件校验失败：${action.path}');
        }
        pushedHashes[action.path] = uploadedHash!;
        stagedSizes[stagedPath] = fileSize;
        stagedParents.add(_parentPath(stagedPath));
      }
      // Verify remote sizes in one listing per staging directory rather than
      // paying a second round trip for every uploaded file on high-latency
      // SFTP links.
      for (final parent in stagedParents) {
        final stagedEntries = await remote.listDirectory(parent);
        final byPath = {for (final entry in stagedEntries) entry.path: entry};
        for (final staged in stagedSizes.entries) {
          if (_parentPath(staged.key) != parent) continue;
          final entry = byPath[staged.key];
          if (entry == null) {
            throw RepositorySyncException('推送文件未完整发布：${_baseName(staged.key)}');
          }
          if (entry.size != staged.value) {
            throw RepositorySyncException(
              '推送文件大小校验失败：${_baseName(staged.key)}',
            );
          }
        }
      }
      return _PreparedPush(
        stagingPath: stagingPath,
        actions: actions,
        pushedHashes: pushedHashes,
      );
    } catch (_) {
      try {
        await remote.deleteEntry(stagingPath, recursive: true);
      } catch (_) {}
      rethrow;
    }
  }

  Future<void> _recoverLocalTransactions() async {
    if (!await metadataRoot.exists()) return;
    final journals = <File>[];
    await for (final entity in metadataRoot.list(followLinks: false)) {
      if (entity is File &&
          _baseName(entity.path).startsWith('pull-transaction-') &&
          _baseName(entity.path).endsWith('.json')) {
        journals.add(entity);
      }
    }
    for (final journal in journals) {
      final transaction = await _readLocalTransaction(journal);
      if (transaction.status == 'committing') {
        await _rollbackLocalTransaction(transaction);
      }
      await _cleanupLocalTransaction(journal, transaction);
    }
  }

  Future<_LocalTransaction> _readLocalTransaction(File journal) async {
    try {
      return _LocalTransaction.fromJson(
        jsonDecode(await journal.readAsString()) as Map<String, dynamic>,
      );
    } catch (exception) {
      throw RepositorySyncException('本地同步事务日志损坏，无法安全恢复：${journal.path}');
    }
  }

  Future<void> _writeLocalTransaction(
    File journal,
    _LocalTransaction transaction,
  ) async {
    await journal.parent.create(recursive: true);
    final temporary = File('${journal.path}.part-${uniqueSuffix()}');
    await temporary.writeAsString(
      jsonEncode(transaction.toJson()),
      flush: true,
    );
    await _atomicReplaceLocal(temporary, journal);
  }

  Future<void> _cleanupLocalTransaction(
    File journal,
    _LocalTransaction transaction,
  ) async {
    for (final record in transaction.records) {
      if (record.backupPath.isEmpty) continue;
      final backup = _localPath(record.backupPath);
      if (await _localEntryExistsAbsolute(backup)) {
        await _deleteLocalEntry(backup);
      }
    }
    final metadataPath = metadataRoot.absolute.path;
    final stagingPath = Directory(transaction.stagingPath).absolute.path;
    if (stagingPath != metadataPath &&
        stagingPath.startsWith('$metadataPath${Platform.pathSeparator}') &&
        await Directory(stagingPath).exists()) {
      await Directory(stagingPath).delete(recursive: true);
    }
    if (await journal.exists()) await journal.delete();
  }

  Future<void> _rollbackLocalTransaction(_LocalTransaction transaction) async {
    for (final record in transaction.records.reversed) {
      final target = _localPath(record.path);
      final backup = record.backupPath.isEmpty
          ? null
          : _localPath(record.backupPath);
      if (record.kind == 'mkdir') {
        if (record.published && await _localEntryExistsAbsolute(target)) {
          try {
            await Directory(target).delete();
          } on FileSystemException {
            // A non-empty directory indicates an unexpected external change;
            // leave it and let the journal remain for user attention.
            rethrow;
          }
        }
        continue;
      }
      final backupExists =
          backup != null && await _localEntryExistsAbsolute(backup);
      if (record.published && record.kind == 'replace') {
        if (await _localEntryExistsAbsolute(target)) {
          await _deleteLocalEntry(target);
        }
      }
      if (record.hadTarget && backupExists) {
        await _moveLocalEntry(backup, target);
      } else if (!record.hadTarget &&
          record.kind == 'replace' &&
          !await _localEntryExistsAbsolute(
            _join(transaction.stagingPath, record.path),
          ) &&
          await _localEntryExistsAbsolute(target)) {
        // The staged file may have been moved just before a crash and before
        // the journal could mark it published. Restore the pre-transaction
        // absence in that case.
        await _deleteLocalEntry(target);
      }
    }
  }

  Future<bool> _localEntryExists(String path) async =>
      _localEntryExistsAbsolute(_localPath(path));

  Future<bool> _localEntryExistsAbsolute(String path) async =>
      await FileSystemEntity.type(path, followLinks: false) !=
      FileSystemEntityType.notFound;

  Future<void> _moveLocalEntry(String source, String target) async {
    final sourceType = await FileSystemEntity.type(source, followLinks: false);
    if (sourceType == FileSystemEntityType.notFound) {
      throw FileSystemException('File not found.', source);
    }
    await Directory(_parentAbsolute(target)).create(recursive: true);
    if (await _localEntryExistsAbsolute(target)) {
      throw FileSystemException('Target already exists.', target);
    }
    await (sourceType == FileSystemEntityType.directory
            ? Directory(source)
            : File(source))
        .rename(target);
  }

  Future<void> _deleteLocalEntry(String path) async {
    final type = await FileSystemEntity.type(path, followLinks: false);
    if (type == FileSystemEntityType.notFound) return;
    await (type == FileSystemEntityType.directory
            ? Directory(path)
            : File(path))
        .delete(recursive: true);
  }

  static String _parentAbsolute(String path) {
    final separator = path.lastIndexOf(Platform.pathSeparator);
    return separator < 0 ? '.' : path.substring(0, separator);
  }

  Future<Map<String, String>> _commitPush(
    _PreparedPush prepared, {
    required RepositorySyncManifest? remoteManifest,
    required Map<String, RepositorySyncEntry> remoteBefore,
  }) async {
    final revisionBefore = remoteManifest?.revision ?? 0;
    final currentRemote = await _scanRemote();
    final currentManifest = await _readRemoteManifest();
    if ((currentManifest?.revision ?? 0) != revisionBefore ||
        !_mapsEquivalent(currentRemote, remoteBefore)) {
      throw const RepositorySyncVersionException('远端仓库在推送期间发生变化，请重新拉取后再试。');
    }
    final transactionId = _baseName(prepared.stagingPath);
    final journalPath = '$remoteMetadataRoot/transaction-$transactionId.json';
    final backupRoot = _join(prepared.stagingPath, '.backup');
    final records = <_RemoteTransactionRecord>[];
    await _writeRemoteTransaction(
      journalPath,
      _RemoteTransaction(
        stagingPath: prepared.stagingPath,
        status: 'committing',
        records: records,
      ),
    );
    var canDisposeStaging = false;
    try {
      Future<_RemoteTransactionRecord> prepareRecord(
        String path, {
        required bool deletion,
      }) async {
        final backupPath = _join(backupRoot, path);
        final hadTarget = await _remoteEntryExists(path);
        final record = _RemoteTransactionRecord(
          path: path,
          backupPath: backupPath,
          hadTarget: hadTarget,
          deletion: deletion,
        );
        // Persist the record before moving the formal target.  If the
        // process is interrupted between the backup move and the next journal
        // write, recovery can still find the backup path and restore it.
        records.add(record);
        await _writeRemoteTransaction(
          journalPath,
          _RemoteTransaction(
            stagingPath: prepared.stagingPath,
            status: 'committing',
            records: records,
          ),
        );
        if (hadTarget) {
          await _ensureRemoteDirectory(_parentPath(backupPath));
          await _moveRemoteEntry(path, backupPath, overwrite: true);
          record.backupMoved = true;
          await _writeRemoteTransaction(
            journalPath,
            _RemoteTransaction(
              stagingPath: prepared.stagingPath,
              status: 'committing',
              records: records,
            ),
          );
        }
        return record;
      }

      Future<void> persistJournal() => _writeRemoteTransaction(
        journalPath,
        _RemoteTransaction(
          stagingPath: prepared.stagingPath,
          status: 'committing',
          records: records,
        ),
      );

      // Publish staged files by server-side rename. Formal paths remain
      // untouched until every source has been fully uploaded and verified.
      for (final action in prepared.actions.where(
        (item) => item.source != null && !item.source!.isDirectory,
      )) {
        await _ensureRemoteDirectory(_parentPath(action.path));
        final record = await prepareRecord(action.path, deletion: false);
        await _moveRemoteEntry(
          _join(prepared.stagingPath, action.path),
          action.path,
          overwrite: true,
        );
        record.published = true;
        await persistJournal();
      }
      // Deletions are intentionally last so a failed upload never destroys a
      // formal copy. Empty directories are also committed after files.
      for (final action in prepared.actions.where(
        (item) => item.source?.isDirectory == true,
      )) {
        await _ensureRemoteDirectory(_parentPath(action.path));
        final stagedPath = _join(prepared.stagingPath, action.path);
        // Uploading a child file may have created this formal directory
        // already, and moving the staged empty directory over it would hide
        // the files just published. Keep the existing directory in that
        // expected case. A directory that was present before the lock would
        // have been excluded from this one-sided plan.
        final formalDirectoryExists = await _remoteEntryExists(action.path);
        if (formalDirectoryExists) {
          if (remoteBefore.containsKey(action.path)) {
            throw const RepositorySyncVersionException(
              '远端目录在提交期间发生变化，请重新检查后再试。',
            );
          }
          continue;
        }
        final record = await prepareRecord(action.path, deletion: false);
        await _moveRemoteEntry(stagedPath, action.path, overwrite: true);
        record.published = true;
        await persistJournal();
      }
      final deletions = _deleteDeepestFirst(
        prepared.actions
            .where((item) => item.source == null)
            .map((item) => item.path),
      );
      for (final path in deletions) {
        final record = await prepareRecord(path, deletion: true);
        record.published = true;
        await persistJournal();
      }
      await _writeRemoteTransaction(
        journalPath,
        _RemoteTransaction(
          stagingPath: prepared.stagingPath,
          status: 'committed',
          records: records,
        ),
      );
      try {
        await remote.deleteEntry(journalPath, recursive: false);
      } catch (_) {}
      canDisposeStaging = true;
      return prepared.pushedHashes;
    } catch (exception) {
      var rollbackSucceeded = false;
      try {
        await _rollbackRemoteTransaction(
          _RemoteTransaction(
            stagingPath: prepared.stagingPath,
            status: 'committing',
            records: records,
          ),
        );
        // Marking the journal rolled back makes a later recovery pass safe
        // even if deleting the journal itself is temporarily unavailable.
        await _writeRemoteTransaction(
          journalPath,
          _RemoteTransaction(
            stagingPath: prepared.stagingPath,
            status: 'rolledBack',
            records: records,
          ),
        );
        await remote.deleteEntry(journalPath, recursive: false);
        rollbackSucceeded = true;
      } catch (_) {
        // Keep the journal for the next synchronization attempt to recover.
      }
      canDisposeStaging = rollbackSucceeded;
      rethrow;
    } finally {
      if (canDisposeStaging) await prepared.dispose(remote);
    }
  }

  Future<bool> _remoteEntryExists(String path) async {
    try {
      final parent = _parentPath(path);
      final name = _baseName(path);
      return (await remote.listDirectory(
        parent,
      )).any((entry) => entry.name == name);
    } on FileSystemException catch (exception) {
      if (_isMissing(exception)) return false;
      rethrow;
    }
  }

  Future<void> _writeRemoteTransaction(
    String path,
    _RemoteTransaction transaction,
  ) async {
    await _writeRemoteText(path, jsonEncode(transaction.toJson()));
  }

  Future<void> _rollbackRemoteTransaction(
    _RemoteTransaction transaction,
  ) async {
    for (final record in transaction.records.reversed) {
      if (record.published && !record.deletion) {
        try {
          await remote.deleteEntry(record.path, recursive: true);
        } on FileSystemException catch (exception) {
          if (!_isMissing(exception)) rethrow;
        }
      }
      final backupExists =
          record.hadTarget &&
          (record.backupMoved || await _remoteEntryExists(record.backupPath));
      if (backupExists) {
        await _moveRemoteEntry(record.backupPath, record.path, overwrite: true);
      } else if (!record.hadTarget &&
          !record.deletion &&
          !(await _remoteEntryExists(
            _join(transaction.stagingPath, record.path),
          ))) {
        // A replacement with no previous target may have completed just
        // before the journal update.  The staged source is then gone; remove
        // the formal file so recovery leaves the pre-transaction state.
        try {
          await remote.deleteEntry(record.path, recursive: true);
        } on FileSystemException catch (exception) {
          if (!_isMissing(exception)) rethrow;
        }
      }
    }
  }

  bool _mapsEquivalent(
    Map<String, RepositorySyncEntry> left,
    Map<String, RepositorySyncEntry> right,
  ) {
    if (left.length != right.length) return false;
    for (final path in <String>{...left.keys, ...right.keys}) {
      if (!_sameSyncEntry(left[path], right[path])) return false;
    }
    return true;
  }

  bool _sameActionPlan(List<_SyncAction> left, List<_SyncAction> right) {
    if (left.length != right.length) return false;
    for (var index = 0; index < left.length; index++) {
      final a = left[index];
      final b = right[index];
      if (a.path != b.path || a.source?.type != b.source?.type) return false;
      if (a.source?.size != b.source?.size ||
          a.source?.modifiedAt != b.source?.modifiedAt) {
        return false;
      }
    }
    return true;
  }

  Future<_RemoteState> _readRemoteState() async {
    final manifest = await _readRemoteManifest();
    // The Windows repository host invalidates this accelerator whenever a
    // formal file changes, including Explorer changes observed by its
    // filesystem watcher. Missing/corrupt metadata falls back to a scan.
    if (trustRemoteManifest && manifest != null) {
      return _RemoteState(
        entries: Map<String, RepositorySyncEntry>.from(manifest.entries),
        manifest: manifest,
      );
    }
    final entries = await _scanRemote();
    return _RemoteState(entries: entries, manifest: manifest);
  }

  Future<void> _recoverRemoteTransactions() async {
    List<FileEntry> entries;
    try {
      entries = await remote.listDirectory(remoteMetadataRoot);
    } catch (_) {
      return;
    }
    for (final entry in entries) {
      if (entry.isDirectory ||
          !entry.name.startsWith('transaction-') ||
          !entry.name.endsWith('.json')) {
        continue;
      }
      try {
        final raw = await _readRemoteText('$remoteMetadataRoot/${entry.name}');
        final transaction = _RemoteTransaction.fromJson(
          jsonDecode(raw) as Map<String, dynamic>,
        );
        if (transaction.status == 'committing') {
          await _rollbackRemoteTransaction(transaction);
        }
        await remote.deleteEntry(
          '$remoteMetadataRoot/${entry.name}',
          recursive: false,
        );
        try {
          await remote.deleteEntry(transaction.stagingPath, recursive: true);
        } catch (_) {}
      } catch (_) {
        // Do not guess around an unreadable journal: continuing could publish
        // a second transaction on top of an unknown half-commit. Keep the
        // journal in place so the user can inspect/recover it.
        throw RepositorySyncException('远端同步事务日志损坏或无法恢复：${entry.name}');
      }
    }
  }

  Future<RepositorySyncManifest?> _readRemoteManifest() async {
    try {
      final raw = await _readRemoteText(
        '$remoteMetadataRoot/$remoteManifestName',
      );
      return RepositorySyncManifest.decode(raw);
    } catch (_) {
      return null;
    }
  }

  Future<Map<String, RepositorySyncEntry>> _scanRemote() async {
    final result = <String, RepositorySyncEntry>{};
    Future<void> visit(String directory) async {
      List<FileEntry> children;
      try {
        children = await remote.listDirectory(directory);
      } on FileSystemException catch (exception) {
        if (directory == '' && _isMissing(exception)) return;
        rethrow;
      }
      for (final child in children) {
        final path = normalizeRelativePath(child.path);
        if (_isExcluded(path)) continue;
        result[path] = RepositorySyncEntry(
          path: path,
          type: child.type,
          size: child.size,
          modifiedAt: child.modifiedAt,
        );
        if (child.isDirectory) await visit(path);
      }
    }

    await visit('');
    return result;
  }

  Future<Map<String, RepositorySyncEntry>> _scanLocal() async {
    final result = <String, RepositorySyncEntry>{};
    if (!await localRoot.exists()) return result;
    Future<void> visit(Directory directory, String parent) async {
      await for (final entity in directory.list(followLinks: false)) {
        final name = _baseName(entity.path);
        final path = joinRelativePath(parent, name);
        if (_isExcluded(path)) continue;
        final stat = await entity.stat();
        final isDirectory = stat.type == FileSystemEntityType.directory;
        if (stat.type != FileSystemEntityType.file && !isDirectory) continue;
        result[path] = RepositorySyncEntry(
          path: path,
          type: isDirectory ? FileEntryType.directory : FileEntryType.file,
          size: isDirectory ? 0 : stat.size,
          modifiedAt: stat.modified,
        );
        if (isDirectory) await visit(Directory(entity.path), path);
      }
    }

    await visit(localRoot, '');
    return result;
  }

  Future<_Comparison> _compare({
    required Map<String, RepositorySyncEntry> local,
    required Map<String, RepositorySyncEntry> remote,
    required Map<String, RepositorySyncEntry> baseline,
  }) async {
    final localMutable = Map<String, RepositorySyncEntry>.from(local);
    final remoteMutable = Map<String, RepositorySyncEntry>.from(remote);
    final conflicts = <RepositorySyncConflict>[];
    final paths = <String>{...local.keys, ...remote.keys, ...baseline.keys};
    for (final path in paths) {
      var l = localMutable[path];
      var r = remoteMutable[path];
      final b = baseline[path];
      // A successful pull records the content hash because local filesystems
      // often cannot preserve the remote timestamp exactly. Re-hash only
      // those baseline-hashed files whose cheap metadata differs; ordinary
      // unchanged files remain on the size/mtime fast path.
      if (b?.sha256 != null && !b!.isDirectory) {
        if (l != null &&
            l.sha256 == null &&
            l.size == b.size &&
            l.modifiedAt != b.modifiedAt) {
          l = l.copyWith(sha256: await _hashLocal(path));
          localMutable[path] = l;
        }
        if (r != null &&
            r.sha256 == null &&
            r.size == b.size &&
            r.modifiedAt != b.modifiedAt) {
          r = r.copyWith(sha256: await _hashRemote(path));
          remoteMutable[path] = r;
        }
      }
      final localChanged = !_sameSyncEntry(l, b);
      final remoteChanged = !_sameSyncEntry(r, b);
      if (l != null &&
          r != null &&
          l.type != r.type &&
          (localChanged || remoteChanged)) {
        conflicts.add(
          RepositorySyncConflict(
            path: path,
            type: RepositorySyncConflictType.typeChanged,
            local: l,
            remote: r,
            baseline: b,
          ),
        );
        continue;
      }
      if (!localChanged || !remoteChanged) continue;
      if (l == null || r == null) {
        conflicts.add(
          RepositorySyncConflict(
            path: path,
            type: l == null
                ? RepositorySyncConflictType.deletedModified
                : RepositorySyncConflictType.modifiedDeleted,
            local: l,
            remote: r,
            baseline: b,
          ),
        );
        continue;
      }
      if (l.type != r.type) {
        conflicts.add(
          RepositorySyncConflict(
            path: path,
            type: RepositorySyncConflictType.typeChanged,
            local: l,
            remote: r,
            baseline: b,
          ),
        );
        continue;
      }
      final content = await _compareContent(path, l, r);
      if (!content.equal) {
        conflicts.add(
          RepositorySyncConflict(
            path: path,
            type: RepositorySyncConflictType.modifiedModified,
            local: l,
            remote: r,
            baseline: b,
          ),
        );
      } else if (!l.isDirectory &&
          (b?.sha256 == null || content.localHash != b!.sha256)) {
        // Both sides changed from the last baseline, even if their resulting
        // bytes happen to be equal. Treat that as a real concurrent edit
        // rather than silently guessing that either direction should win.
        conflicts.add(
          RepositorySyncConflict(
            path: path,
            type: RepositorySyncConflictType.modifiedModified,
            local: l,
            remote: r,
            baseline: b,
          ),
        );
      } else {
        // Equal contents can have different mtimes after a download. Record a
        // common hash so they compare equal on the next run.
        localMutable[path] = l.copyWith(sha256: content.localHash);
        remoteMutable[path] = r.copyWith(sha256: content.localHash);
      }
    }
    final changed = <String>{...local.keys, ...remote.keys, ...baseline.keys}
        .where(
          (path) =>
              !_sameSyncEntry(localMutable[path], baseline[path]) ||
              !_sameSyncEntry(remoteMutable[path], baseline[path]),
        )
        .toSet();
    return _Comparison(
      local: localMutable,
      remote: remoteMutable,
      changedPaths: changed,
      conflicts: conflicts,
    );
  }

  Future<_ContentComparison> _compareContent(
    String path,
    RepositorySyncEntry local,
    RepositorySyncEntry remoteEntry,
  ) async {
    if (local.isDirectory) {
      return const _ContentComparison(equal: true);
    }
    if (local.size != remoteEntry.size) {
      return const _ContentComparison(equal: false);
    }
    final localHash = local.sha256 ?? await _hashLocal(path);
    final remoteHash = remoteEntry.sha256 ?? await _hashRemote(path);
    return _ContentComparison(
      equal: localHash == remoteHash,
      localHash: localHash,
      remoteHash: remoteHash,
    );
  }

  Future<String> _hashLocal(String path) => _hashFile(File(_localPath(path)));

  Future<String> _hashRemote(String path) async {
    final target = File(
      '${metadataRoot.path}${Platform.pathSeparator}hash-${uniqueSuffix()}.part',
    );
    try {
      await target.parent.create(recursive: true);
      String? streamedHash;
      await remote.downloadFile(
        remotePath: path,
        target: target,
        onChecksum: (value) => streamedHash = value,
      );
      return streamedHash ?? await _hashFile(target);
    } finally {
      if (await target.exists()) await target.delete();
    }
  }

  Future<String> _hashFile(File file) async {
    final accumulator = Sha256Accumulator();
    await for (final chunk in file.openRead()) {
      accumulator.add(chunk);
    }
    return accumulator.close();
  }

  Future<RepositorySyncManifest?> _readBaselineManifest() async {
    final file = File(
      '${metadataRoot.path}${Platform.pathSeparator}$baselineName',
    );
    if (!await file.exists()) return null;
    try {
      return RepositorySyncManifest.decode(await file.readAsString());
    } catch (_) {
      // A damaged baseline is recoverable: keep the file as evidence and
      // start a new three-way comparison from an empty baseline.
      try {
        await file.rename('${file.path}.corrupt-${uniqueSuffix()}');
      } catch (_) {}
      return null;
    }
  }

  Future<Map<String, RepositorySyncEntry>?> _readBaseline() async =>
      (await _readBaselineManifest())?.entries;

  Future<void> _writeBaseline(Map<String, RepositorySyncEntry> entries) async {
    await metadataRoot.create(recursive: true);
    final target = File(
      '${metadataRoot.path}${Platform.pathSeparator}$baselineName',
    );
    final temporary = File('${target.path}.part-${uniqueSuffix()}');
    await temporary.writeAsString(
      RepositorySyncManifest(
        revision: 0,
        createdAt: _now().toUtc(),
        entries: entries,
      ).encode(),
      flush: true,
    );
    await _atomicReplaceLocal(temporary, target);
  }

  Future<void> _writeRemoteManifest(RepositorySyncManifest manifest) async {
    await _writeRemoteText(
      '$remoteMetadataRoot/$remoteManifestName',
      manifest.encode(),
    );
  }

  Future<void> _writeRemoteText(String path, String value) async {
    await _ensureRemoteDirectory(remoteMetadataRoot);
    final source = File(
      '${metadataRoot.path}${Platform.pathSeparator}remote-write-${uniqueSuffix()}.json',
    );
    try {
      await source.parent.create(recursive: true);
      await source.writeAsString(value, flush: true);
      await remote.uploadFile(
        source: source,
        targetDirectory: _parentPath(path),
        targetName: _baseName(path),
        overwrite: true,
      );
    } finally {
      if (await source.exists()) await source.delete();
    }
  }

  Future<String> _readRemoteText(String path) async {
    final target = File(
      '${metadataRoot.path}${Platform.pathSeparator}remote-${uniqueSuffix()}.json',
    );
    try {
      await target.parent.create(recursive: true);
      await remote.downloadFile(remotePath: path, target: target);
      return target.readAsString();
    } finally {
      if (await target.exists()) await target.delete();
    }
  }

  Future<_SyncLock> _acquireLock() async {
    await _ensureRemoteDirectory(remoteMetadataRoot);
    final now = _now().toUtc();
    try {
      final raw = await _readRemoteText('$remoteMetadataRoot/$remoteLockName');
      final lock = _SyncLock.fromJson(jsonDecode(raw) as Map<String, dynamic>);
      final age = now.difference(lock.timestamp);
      if (age < lockTimeout) {
        throw RepositorySyncException('同步正在进行中（${lock.owner}），请稍后重试。');
      }
      try {
        await remote.deleteEntry(
          '$remoteMetadataRoot/$remoteLockName',
          recursive: false,
        );
      } catch (_) {}
    } catch (exception) {
      if (exception is RepositorySyncException) rethrow;
      // Missing/corrupt locks are safe to replace. A corrupt lock is kept out
      // of the critical path because its timestamp cannot be trusted.
      try {
        await remote.deleteEntry(
          '$remoteMetadataRoot/$remoteLockName',
          recursive: false,
        );
      } catch (_) {}
    }
    final lock = _SyncLock(
      owner: ownerId,
      timestamp: now,
      timeout: lockTimeout,
    );
    final source = File(
      '${metadataRoot.path}${Platform.pathSeparator}lock-${uniqueSuffix()}.json',
    );
    await source.parent.create(recursive: true);
    await source.writeAsString(jsonEncode(lock.toJson()), flush: true);
    try {
      await remote.uploadFile(
        source: source,
        targetDirectory: remoteMetadataRoot,
        targetName: remoteLockName,
        overwrite: false,
      );
      return lock;
    } finally {
      if (await source.exists()) await source.delete();
    }
  }

  Future<void> _releaseLock(_SyncLock lock) async {
    try {
      final raw = await _readRemoteText('$remoteMetadataRoot/$remoteLockName');
      final current = _SyncLock.fromJson(
        jsonDecode(raw) as Map<String, dynamic>,
      );
      if (current.owner == lock.owner &&
          current.timestamp.toUtc().millisecondsSinceEpoch ==
              lock.timestamp.toUtc().millisecondsSinceEpoch) {
        await remote.deleteEntry(
          '$remoteMetadataRoot/$remoteLockName',
          recursive: false,
        );
      }
    } catch (_) {}
  }

  Future<void> _ensureRemoteDirectory(String path, {String? root}) async {
    final target = normalizeRelativePath(
      root == null ? path : joinRelativePath(root, path),
    );
    var current = '';
    for (final segment in target.split('/')) {
      if (segment.isEmpty) continue;
      final next = joinRelativePath(current, segment);
      try {
        await remote.createDirectory(current, segment);
      } catch (_) {
        try {
          await remote.listDirectory(next);
        } catch (exception) {
          rethrow;
        }
      }
      current = next;
    }
  }

  Future<void> _moveRemoteEntry(
    String sourcePath,
    String targetPath, {
    required bool overwrite,
  }) {
    final mover = remote;
    if (mover is AtomicRepositoryGateway) {
      return (mover as AtomicRepositoryGateway).moveEntry(
        sourcePath,
        targetPath,
        overwrite: overwrite,
      );
    }
    throw UnsupportedError(
      'Repository synchronization requires an atomic move capability.',
    );
  }

  String _localPath(String relative) => _join(localRoot.path, relative);

  static String _join(String parent, String child) => child.isEmpty
      ? parent
      : '$parent${Platform.pathSeparator}${child.replaceAll('/', Platform.pathSeparator)}';

  static String _baseName(String path) => path.split(RegExp(r'[/\\]')).last;

  static String _parentPath(String path) {
    final normalized = normalizeRelativePath(path);
    final slash = normalized.lastIndexOf('/');
    return slash < 0 ? '' : normalized.substring(0, slash);
  }

  static bool _isExcluded(String path) {
    final parts = normalizeRelativePath(path).split('/');
    return parts.any(
      (part) =>
          part == remoteMetadataRoot ||
          part == '__jet2drop_transfer' ||
          part == localMetadataName ||
          part.startsWith('.jet2drop-') ||
          part.contains('.jet2drop-upload-') ||
          part.contains('.jet2drop-download-') ||
          part.contains('.jet2drop-backup-') ||
          part.endsWith('.part') ||
          part.endsWith('.jet2drop.tmp'),
    );
  }

  RepositorySyncSnapshot _snapshotFromComparison(
    _Comparison comparison, {
    required Map<String, RepositorySyncEntry> baseline,
    required int? remoteRevision,
  }) {
    final hasChanges = comparison.changedPaths.isNotEmpty;
    return RepositorySyncSnapshot(
      status: comparison.conflicts.isNotEmpty
          ? RepositorySyncStatus.needsAttention
          : hasChanges
          ? RepositorySyncStatus.changed
          : RepositorySyncStatus.synced,
      message: comparison.conflicts.isNotEmpty
          ? '存在 ${comparison.conflicts.length} 个冲突，请处理后重试。'
          : hasChanges
          ? '本地或远端有待同步的变更。'
          : '已同步',
      local: comparison.local,
      remote: comparison.remote,
      baseline: baseline,
      conflicts: comparison.conflicts,
      remoteRevision: remoteRevision,
    );
  }

  static List<String> _deleteDeepestFirst(Iterable<String> paths) {
    final result = paths.toSet().toList();
    result.sort((left, right) {
      final depth = right.split('/').length.compareTo(left.split('/').length);
      return depth == 0 ? right.compareTo(left) : depth;
    });
    return result;
  }

  static bool _isMissing(FileSystemException exception) {
    final code = exception.osError?.errorCode;
    if (code == 2 || code == 3) return true;
    final value = exception.toString().toLowerCase();
    return value.contains('not found') ||
        value.contains('no such file') ||
        value.contains('does not exist');
  }

  static Future<void> _atomicReplaceLocal(File source, File target) async {
    final backup = File('${target.path}.jet2drop-backup-${uniqueSuffix()}');
    final hadTarget = await target.exists();
    if (hadTarget) await target.rename(backup.path);
    try {
      await source.rename(target.path);
    } catch (_) {
      if (hadTarget && await backup.exists()) await backup.rename(target.path);
      rethrow;
    }
    if (hadTarget && await backup.exists()) {
      try {
        await backup.delete();
      } catch (_) {}
    }
  }
}

class _Comparison {
  const _Comparison({
    required this.local,
    required this.remote,
    required this.changedPaths,
    required this.conflicts,
  });

  final Map<String, RepositorySyncEntry> local;
  final Map<String, RepositorySyncEntry> remote;
  final Set<String> changedPaths;
  final List<RepositorySyncConflict> conflicts;
}

class _ContentComparison {
  const _ContentComparison({
    required this.equal,
    this.localHash,
    this.remoteHash,
  });

  final bool equal;
  final String? localHash;
  final String? remoteHash;
}

class _RemoteState {
  const _RemoteState({required this.entries, required this.manifest});

  final Map<String, RepositorySyncEntry> entries;
  final RepositorySyncManifest? manifest;
}

class _PreparedPull {
  const _PreparedPull({
    required this.staging,
    required this.actions,
    required this.hashes,
  });

  final Directory staging;
  final List<_SyncAction> actions;
  final Map<String, String> hashes;

  Future<void> dispose() async {
    if (await staging.exists()) await staging.delete(recursive: true);
  }
}

class _PreparedPush {
  const _PreparedPush({
    required this.stagingPath,
    required this.actions,
    required this.pushedHashes,
  });

  final String stagingPath;
  final List<_SyncAction> actions;
  final Map<String, String> pushedHashes;

  Future<void> dispose(RepositoryGateway remote) async {
    try {
      await remote.deleteEntry(stagingPath, recursive: true);
    } catch (_) {}
  }
}

class _LocalTransaction {
  _LocalTransaction({
    required this.stagingPath,
    required this.status,
    required this.records,
  });

  final String stagingPath;
  String status;
  final List<_LocalTransactionRecord> records;

  Map<String, Object?> toJson() => {
    'v': 1,
    'staging': stagingPath,
    'status': status,
    'records': records.map((record) => record.toJson()).toList(growable: false),
  };

  factory _LocalTransaction.fromJson(Map<String, dynamic> json) {
    final staging = json['staging'] as String?;
    final status = json['status'] as String?;
    final values = json['records'];
    if (staging == null ||
        status == null ||
        (status != 'committing' && status != 'committed') ||
        values is! List) {
      throw const FormatException('Local sync transaction is malformed.');
    }
    return _LocalTransaction(
      stagingPath: staging,
      status: status,
      records: [
        for (final value in values)
          _LocalTransactionRecord.fromJson(
            Map<String, dynamic>.from(value as Map),
          ),
      ],
    );
  }
}

class _LocalTransactionRecord {
  _LocalTransactionRecord({
    required this.path,
    required this.backupPath,
    required this.kind,
    required this.hadTarget,
    this.backupMoved = false,
    this.published = false,
  });

  final String path;
  final String backupPath;
  final String kind;
  final bool hadTarget;
  bool backupMoved;
  bool published;

  Map<String, Object?> toJson() => {
    'path': path,
    'backup': backupPath,
    'kind': kind,
    'hadTarget': hadTarget,
    'backupMoved': backupMoved,
    'published': published,
  };

  factory _LocalTransactionRecord.fromJson(Map<String, dynamic> json) {
    final path = json['path'] as String?;
    final backup = json['backup'] as String?;
    final kind = json['kind'] as String?;
    final hadTarget = json['hadTarget'] as bool?;
    if (path == null ||
        backup == null ||
        kind == null ||
        hadTarget == null ||
        (kind != 'mkdir' && kind != 'replace' && kind != 'delete')) {
      throw const FormatException(
        'Local sync transaction record is malformed.',
      );
    }
    return _LocalTransactionRecord(
      path: normalizeRelativePath(path),
      backupPath: backup.isEmpty ? '' : normalizeRelativePath(backup),
      kind: kind,
      hadTarget: hadTarget,
      backupMoved: json['backupMoved'] as bool? ?? false,
      published: json['published'] as bool? ?? false,
    );
  }
}

class _RemoteTransaction {
  _RemoteTransaction({
    required this.stagingPath,
    required this.status,
    required this.records,
  });

  final String stagingPath;
  final String status;
  final List<_RemoteTransactionRecord> records;

  Map<String, Object?> toJson() => {
    'v': 1,
    'staging': stagingPath,
    'status': status,
    'records': records.map((record) => record.toJson()).toList(growable: false),
  };

  factory _RemoteTransaction.fromJson(Map<String, dynamic> json) {
    final staging = json['staging'] as String?;
    final status = json['status'] as String?;
    final values = json['records'];
    if (staging == null ||
        status == null ||
        (status != 'committing' &&
            status != 'committed' &&
            status != 'rolledBack') ||
        values is! List) {
      throw const FormatException('Sync transaction journal is malformed.');
    }
    return _RemoteTransaction(
      stagingPath: normalizeRelativePath(staging),
      status: status,
      records: [
        for (final value in values)
          _RemoteTransactionRecord.fromJson(
            Map<String, dynamic>.from(value as Map),
          ),
      ],
    );
  }
}

class _RemoteTransactionRecord {
  _RemoteTransactionRecord({
    required this.path,
    required this.backupPath,
    required this.hadTarget,
    this.deletion = false,
    this.backupMoved = false,
    this.published = false,
  });

  final String path;
  final String backupPath;
  final bool hadTarget;
  final bool deletion;
  bool backupMoved;
  bool published;

  Map<String, Object?> toJson() => {
    'path': path,
    'backup': backupPath,
    'hadTarget': hadTarget,
    'deletion': deletion,
    'backupMoved': backupMoved,
    'published': published,
  };

  factory _RemoteTransactionRecord.fromJson(Map<String, dynamic> json) {
    final path = json['path'] as String?;
    final backup = json['backup'] as String?;
    final hadTarget = json['hadTarget'] as bool?;
    if (path == null || backup == null || hadTarget == null) {
      throw const FormatException('Sync transaction record is malformed.');
    }
    return _RemoteTransactionRecord(
      path: normalizeRelativePath(path),
      backupPath: normalizeRelativePath(backup),
      hadTarget: hadTarget,
      deletion: json['deletion'] as bool? ?? false,
      backupMoved: json['backupMoved'] as bool? ?? false,
      published: json['published'] as bool? ?? false,
    );
  }
}

class _SyncAction {
  const _SyncAction._({
    required this.path,
    required this.source,
    required this.destination,
    required this.direction,
  });

  factory _SyncAction.pull({
    required String path,
    required RepositorySyncEntry? source,
    required RepositorySyncEntry? destination,
  }) => _SyncAction._(
    path: path,
    source: source,
    destination: destination,
    direction: RepositorySyncDirection.pull,
  );

  factory _SyncAction.push({
    required String path,
    required RepositorySyncEntry? source,
    required RepositorySyncEntry? destination,
  }) => _SyncAction._(
    path: path,
    source: source,
    destination: destination,
    direction: RepositorySyncDirection.push,
  );

  final String path;
  final RepositorySyncEntry? source;
  final RepositorySyncEntry? destination;
  final RepositorySyncDirection direction;
}

class _SyncLock {
  const _SyncLock({required this.owner, required this.timestamp, this.timeout});

  final String owner;
  final DateTime timestamp;
  final Duration? timeout;

  Map<String, Object?> toJson() => {
    'owner': owner,
    'timestamp': timestamp.toUtc().millisecondsSinceEpoch,
    if (timeout != null) 'timeout': timeout!.inMilliseconds,
  };

  factory _SyncLock.fromJson(Map<String, dynamic> json) {
    final owner = json['owner'] as String?;
    final millis = (json['timestamp'] as num?)?.toInt();
    if (owner == null || owner.isEmpty || millis == null) {
      throw const FormatException('Sync lock is malformed.');
    }
    return _SyncLock(
      owner: owner,
      timestamp: DateTime.fromMillisecondsSinceEpoch(millis, isUtc: true),
      timeout: (json['timeout'] as num?) == null
          ? null
          : Duration(milliseconds: (json['timeout'] as num).toInt()),
    );
  }
}
