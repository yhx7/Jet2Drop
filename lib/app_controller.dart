import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'core/models/file_entry.dart';
import 'core/models/transfer_task.dart';
import 'core/models/quick_device.dart';
import 'core/connection_retry.dart';
import 'core/path_utils.dart';
import 'core/repository_gateway.dart';
import 'core/transfer_control.dart';
import 'infrastructure/local_repository_gateway.dart';
import 'infrastructure/serialized_repository_gateway.dart';
import 'infrastructure/sftp_repository_gateway.dart';
import 'core/quick_transfer.dart';
import 'core/photo_transfer.dart';
import 'platform/android_transfer_service.dart';
import 'platform/android_save_file.dart';
import 'platform/macos_security_scope.dart';
import 'platform/windows_lifecycle_bridge.dart';

enum RepositoryMode { local, sftp }

enum RepositoryConnectionStatus {
  disconnected,
  connecting,
  connected,
  retrying,
}

enum FileSortField { name, type, size, modifiedAt }

class AppController extends ChangeNotifier {
  AppController({
    Timer Function(Duration duration, void Function(Timer) callback)?
    periodicTimerFactory,
  }) : _periodicTimerFactory = periodicTimerFactory ?? Timer.periodic;

  static const _modeKey = 'repository_mode';
  static const _rootKey = 'local_root';
  static const _hostKey = 'sftp_host';
  static const _portKey = 'sftp_port';
  static const _usernameKey = 'sftp_username';
  static const _fingerprintKey = 'sftp_fingerprint';
  static const _passwordKey = 'sftp_password';
  static const _sortFieldKey = 'file_sort_field';
  static const _sortAscendingKey = 'file_sort_ascending';
  static const _deviceIdKey = 'quick_device_id';
  static const _deviceNameKey = 'quick_device_name';
  static const _photoTokenKey = 'photo_transfer_token';
  static const _quickSaveDirectoryKey = 'quick_save_directory';
  static const _pendingTransfersKey = 'pending_transfers_v1';
  static const _quickRoot = '__jet2drop_transfer';
  static const _quickMessages = 'messages';
  static const quickTransferActiveRefreshInterval = Duration(seconds: 15);
  static const quickTransferInactiveRefreshInterval = Duration(seconds: 45);

  final FlutterSecureStorage _secureStorage = const FlutterSecureStorage();
  final Timer Function(Duration duration, void Function(Timer) callback)
  _periodicTimerFactory;
  late SharedPreferences _preferences;
  RepositoryGateway? _gateway;
  Future<void>? _connectFuture;

  bool isReady = false;
  bool isInitializing = true;
  bool isLoading = false;
  bool _isRefreshingRepository = false;
  bool _repositoryRefreshPending = false;
  bool isDarkTheme = false;
  bool needsTailscale = false;
  RepositoryConnectionStatus connectionStatus =
      RepositoryConnectionStatus.disconnected;
  FileSortField sortField = FileSortField.name;
  bool sortAscending = true;
  String? quickError;
  String currentPath = '';
  String? error;
  List<FileEntry> entries = const [];
  final List<TransferTask> tasks = [];
  final Map<String, TransferControl> _transferControls = {};
  final Map<String, Future<void> Function(TransferTask)> _retryActions = {};
  final Map<String, Future<void> Function()> _cleanupActions = {};
  final Map<String, Future<void> Function()> _completionCleanupActions = {};
  final Map<String, Map<String, Object?>> _pendingTransferRecords = {};
  Future<void> _pendingWriteTail = Future<void>.value();
  final Map<String, Completer<void>> _taskSettled = {};
  final List<_QueuedQuickTransfer> _quickSendQueue = [];
  final Map<String, _QueuedQuickTransfer> _pausedQuickTransfers = {};
  final Set<String> _resumeAfterYield = {};
  final Set<String> _quickLocallySaved = {};
  final Set<String> _reservedQuickReceivePaths = {};
  bool _isProcessingQuickSendQueue = false;
  bool _foregroundTransferActive = false;
  DateTime? _lastForegroundUpdate;
  DateTime? _lastTransferUiUpdate;
  Timer? _transferUiTimer;
  final QuickTransferService quickTransfer = QuickTransferService();
  final PhotoTransferClient _photoTransferClient = PhotoTransferClient();
  PhotoTransferServer? _photoTransferServer;
  String? defaultQuickSaveDirectory;
  String? photoTransferError;
  int _quickRefreshGeneration = 0;
  int _quickSessionGeneration = 0;
  bool _isRefreshingQuickTransfer = false;
  bool _quickRefreshPending = false;
  bool _quickRefreshDevicesPending = false;
  bool _quickMutationInProgress = false;
  bool _disposed = false;
  Completer<void>? _quickRefreshIdle;
  Future<void> _quickMutationTail = Future<void>.value();
  Future<void>? _quickInitializationFuture;
  Future<void> _quickInitializationTail = Future<void>.value();
  int? _quickInitializationGeneration;
  bool _quickInitializationActive = false;
  Timer? _quickMaintenanceTimer;
  bool _quickMaintenanceInProgress = false;
  bool _quickTransferPageActive = false;
  DateTime? _lastQuickPresenceUpdate;
  DateTime? _lastQuickDeviceRefresh;
  final Map<String, QuickTransferManifest> _quickManifestCache = {};
  final Set<String> _hiddenQuickTransferIds = {};
  final Set<String> _quickReceivingIds = {};
  String deviceId = '';
  String deviceName = '';
  List<QuickDevice> quickDevices = const [];
  List<QuickTransferManifest> quickInbox = const [];

  bool get isQuickTransferPageActive => _quickTransferPageActive;

  Duration get quickRefreshInterval => _quickTransferPageActive
      ? quickTransferActiveRefreshInterval
      : quickTransferInactiveRefreshInterval;

  /// Updates the page that is currently presenting quick-transfer data.
  ///
  /// The controller owns the one maintenance timer so the refresh cadence can
  /// follow navigation without allowing the page and controller to poll at
  /// the same time.
  void setQuickTransferPageActive(bool active) {
    if (_disposed || _quickTransferPageActive == active) return;
    _quickTransferPageActive = active;
    _restartQuickMaintenanceTimer();
    if (active &&
        isReady &&
        deviceId.isNotEmpty &&
        !_quickInitializationActive) {
      // Keep the active message poll cheap. Device registrations are
      // reread only when the caller explicitly requests a device refresh.
      unawaited(refreshQuickTransfer());
    }
  }

  void _restartQuickMaintenanceTimer({bool allowDuringInitialization = false}) {
    _quickMaintenanceTimer?.cancel();
    _quickMaintenanceTimer = null;
    if (_disposed ||
        !isReady ||
        deviceId.isEmpty ||
        (!allowDuringInitialization && _quickInitializationActive)) {
      return;
    }
    final interval = quickRefreshInterval;
    _quickMaintenanceTimer = _periodicTimerFactory(interval, (_) {
      _onQuickMaintenanceTick();
    });
  }

  void _stopQuickMaintenanceTimer() {
    _quickMaintenanceTimer?.cancel();
    _quickMaintenanceTimer = null;
  }

  void _onQuickMaintenanceTick() {
    if (_quickMaintenanceInProgress) return;
    final lastPresence = _lastQuickPresenceUpdate;
    final presenceDue =
        !_quickTransferPageActive ||
        lastPresence == null ||
        DateTime.now().difference(lastPresence) >=
            quickTransferInactiveRefreshInterval;
    if (presenceDue) {
      unawaited(_maintainQuickPresence());
    } else {
      // The 15-second active-page tick only needs message state. Presence
      // maintenance performs the less frequent device refresh every 45
      // seconds, while explicit actions can still force an immediate reread.
      unawaited(refreshQuickTransfer());
    }
  }

  static const int maxTransferFiles = 100;
  static const int maxTransferBytes = 10 * 1024 * 1024 * 1024;

  bool get hasActiveTransfers =>
      _transferControls.isNotEmpty ||
      _quickSendQueue.isNotEmpty ||
      _pausedQuickTransfers.isNotEmpty ||
      tasks.any((task) => task.isPaused) ||
      _isProcessingQuickSendQueue;

  bool get hasRunningTransfers =>
      _transferControls.isNotEmpty ||
      _quickSendQueue.isNotEmpty ||
      _isProcessingQuickSendQueue;

  List<FileEntry> get sortedEntries {
    final result = entries.toList(growable: false);
    result.sort((left, right) {
      if (left.type != right.type) return left.isDirectory ? -1 : 1;
      final comparison = switch (sortField) {
        FileSortField.name => left.name.toLowerCase().compareTo(
          right.name.toLowerCase(),
        ),
        FileSortField.type => fileExtension(
          left.name,
        ).compareTo(fileExtension(right.name)),
        FileSortField.size => left.size.compareTo(right.size),
        FileSortField.modifiedAt => left.modifiedAt.compareTo(right.modifiedAt),
      };
      final resolved = comparison == 0
          ? left.name.toLowerCase().compareTo(right.name.toLowerCase())
          : comparison;
      return sortAscending ? resolved : -resolved;
    });
    return result;
  }

  List<QuickDevice> get quickRecipients => quickDevices
      .where(
        (device) =>
            device.id != deviceId &&
            DateTime.now().difference(device.updatedAt) <
                const Duration(minutes: 2),
      )
      .toList(growable: false);

  bool canClaimQuickTransfer(QuickTransferManifest manifest) =>
      !manifest.isClaimed && manifest.targetDevice == deviceId;

  bool isQuickTransferReceiving(String transferId) =>
      _quickReceivingIds.contains(transferId);

  bool canRetryTask(TransferTask task) => _retryActions.containsKey(task.id);

  String quickDeviceName(String id) {
    if (id == deviceId) return deviceName;
    return quickDevices
            .where((device) => device.id == id)
            .map((device) => device.name)
            .firstOrNull ??
        '未知设备';
  }

  RepositoryMode mode = Platform.isWindows
      ? RepositoryMode.local
      : RepositoryMode.sftp;
  String localRoot = r'E:\Repository';
  SftpConnectionProfile? sftpProfile;

  Future<void> initialize() async {
    isInitializing = true;
    notifyListeners();
    try {
      _preferences = await SharedPreferences.getInstance();
      isDarkTheme = _preferences.getBool('dark_theme') ?? false;
      sortField = FileSortField.values.byName(
        _preferences.getString(_sortFieldKey) ?? FileSortField.name.name,
      );
      sortAscending = _preferences.getBool(_sortAscendingKey) ?? true;
      localRoot = _preferences.getString(_rootKey) ?? r'E:\Repository';
      await _loadDefaultQuickSaveDirectory();
      mode = RepositoryMode.values.byName(
        _preferences.getString(_modeKey) ??
            (Platform.isWindows
                ? RepositoryMode.local.name
                : RepositoryMode.sftp.name),
      );
      if (mode == RepositoryMode.sftp) await _loadSftpProfile();
      await connect();
      if (isReady) unawaited(_restorePendingTransfersSafely());
    } catch (exception) {
      error = describeError(exception);
      isReady = false;
    } finally {
      isInitializing = false;
      notifyListeners();
    }
  }

  Future<void> _restorePendingTransfersSafely() async {
    try {
      await _restorePendingTransfers();
    } catch (exception) {
      // Recovery is intentionally independent from the repository session.
      // A malformed or temporarily inaccessible history record must not turn
      // an already connected repository into a failed startup.
      if (!_disposed) {
        quickError = describeError(exception);
        notifyListeners();
      }
    }
  }

  Future<void> _loadDefaultQuickSaveDirectory() async {
    final saved = _preferences.getString(_quickSaveDirectoryKey);
    if (Platform.isMacOS) {
      final restored = await MacosSecurityScope.restoreDirectoryAccess();
      if (restored == null || restored.trim().isEmpty) {
        defaultQuickSaveDirectory = null;
        await _preferences.remove(_quickSaveDirectoryKey);
        return;
      }
      final clean = restored.trim();
      defaultQuickSaveDirectory = clean;
      if (saved != clean) {
        await _preferences.setString(_quickSaveDirectoryKey, clean);
      }
      return;
    }
    if (saved != null && saved.trim().isNotEmpty) {
      // Do not silently replace a path that the user explicitly selected.
      defaultQuickSaveDirectory = saved.trim();
    } else {
      defaultQuickSaveDirectory = null;
    }
  }

  Future<void> setDefaultQuickSaveDirectory(String path) async {
    final clean = path.trim();
    if (clean.isEmpty) throw ArgumentError('默认保存目录不能为空。');
    final directory = Directory(clean);
    FileStat stat;
    try {
      stat = await directory.stat();
    } on FileSystemException {
      throw StateError('默认保存目录不存在或无法访问。');
    }
    if (stat.type != FileSystemEntityType.directory) {
      throw StateError('默认保存位置必须是文件夹。');
    }
    await _verifyQuickSaveDirectoryWritable(directory);
    if (Platform.isMacOS) {
      // Persist only after validation so a failed selection never replaces
      // the previously working bookmark.
      await MacosSecurityScope.persistDirectoryAccess(clean);
    }
    defaultQuickSaveDirectory = clean;
    await _preferences.setString(_quickSaveDirectoryKey, clean);
    notifyListeners();
    // The save directory controls whether this desktop advertises the direct
    // photo capability.  Publish the changed registration immediately when a
    // connection is already active; reconnecting is not required for peers
    // to observe a newly enabled (or restarted) receiver.
    if (isReady && deviceId.isNotEmpty) {
      try {
        await _startPhotoTransferServer();
        await _publishDeviceRegistration();
        await refreshQuickTransfer(refreshDevices: true);
      } catch (exception) {
        quickError = describeError(exception);
        notifyListeners();
      }
    }
  }

  Future<void> _verifyQuickSaveDirectoryWritable(Directory directory) async {
    final probe = File(
      '${directory.path}${Platform.pathSeparator}.jet2drop-write-${uniqueSuffix()}.tmp',
    );
    try {
      await probe.writeAsBytes(const <int>[0], flush: true);
      await probe.delete();
    } on FileSystemException {
      try {
        if (await probe.exists()) await probe.delete();
      } catch (_) {}
      throw StateError('默认保存目录不可写。');
    }
  }

  Future<Directory> _requireDefaultQuickSaveDirectory() async {
    final path = defaultQuickSaveDirectory;
    if (path == null || path.trim().isEmpty) {
      throw StateError('请先在设置中选择快传接收默认保存目录。');
    }
    final directory = Directory(path);
    try {
      final stat = await directory.stat();
      if (stat.type != FileSystemEntityType.directory) {
        throw StateError('快传接收默认保存位置不是文件夹。');
      }
      await _verifyQuickSaveDirectoryWritable(directory);
    } on FileSystemException {
      throw StateError('快传接收默认保存目录不存在或无法访问。');
    }
    return directory;
  }

  Future<File> defaultQuickReceiveTarget(String name) async {
    final directory = await _requireDefaultQuickSaveDirectory();
    final safeName = sanitizeTransferFileName(name);
    final existing = <String>{};
    await for (final entity in directory.list(followLinks: false)) {
      existing.add(entity.uri.pathSegments.last.toLowerCase());
    }
    final dot = safeName.lastIndexOf('.');
    final stem = dot > 0 ? safeName.substring(0, dot) : safeName;
    final extension = dot > 0 ? safeName.substring(dot) : '';
    for (var index = 1; ; index++) {
      final candidateName = index == 1 ? safeName : '$stem ($index)$extension';
      final candidate = File(
        '${directory.path}${Platform.pathSeparator}$candidateName',
      );
      final key = candidate.path.toLowerCase();
      if (existing.contains(candidateName.toLowerCase()) ||
          _reservedQuickReceivePaths.contains(key)) {
        continue;
      }
      _reservedQuickReceivePaths.add(key);
      return candidate;
    }
  }

  Future<void> _restorePendingTransfers() async {
    final raw = _preferences.getString(_pendingTransfersKey);
    if (raw == null || raw.isEmpty) return;
    late final List<dynamic> values;
    try {
      values = jsonDecode(raw) as List<dynamic>;
    } catch (_) {
      await _preferences.remove(_pendingTransfersKey);
      return;
    }
    var recordsChanged = false;
    for (final value in values) {
      String? recordId;
      try {
        final record = Map<String, Object?>.from(value as Map);
        final id = record['id'] as String;
        recordId = id;
        final kind = record['kind'] as String;
        _pendingTransferRecords[id] = record;
        if (kind == 'download') {
          final target = File(record['targetPath'] as String);
          final targetUri = record['androidTargetUri'] as String?;
          final entry = FileEntry(
            path: record['remotePath'] as String,
            name: record['name'] as String,
            type: FileEntryType.file,
            size: (record['totalBytes'] as num).toInt(),
            modifiedAt: DateTime.parse(record['modifiedAt'] as String),
          );
          final task = TransferTask(
            id: id,
            name: entry.name,
            direction: TransferDirection.download,
            totalBytes: entry.size,
            status: TransferStatus.failed,
            error: '上次下载尚未完成，可以继续重试。',
          );
          tasks.add(task);
          Future<void> finalizer(File file) async {
            if (targetUri == null) return;
            final saved = await AndroidSaveFile.saveToDocumentTarget(
              source: file,
              targetUri: targetUri,
            );
            if (!saved) throw StateError('Final save failed.');
            if (await file.exists()) await file.delete();
          }

          _retryActions[id] = (retryTask) => _runDownloadTask(
            retryTask,
            entry: entry,
            target: target,
            finalize: targetUri == null ? null : finalizer,
          );
          _cleanupActions[id] = () async {
            final partial = File('${target.path}.jet2drop-download-$id.part');
            if (await partial.exists()) await partial.delete();
            if (record['deleteTargetOnCancel'] == true &&
                await target.exists()) {
              await target.delete();
            }
          };
          continue;
        }
        if (kind == 'quickReceive') {
          final manifest = QuickTransferManifest.fromJson(
            Map<String, dynamic>.from(record['manifest'] as Map),
          );
          final target = File(record['targetPath'] as String);
          final targetUri = record['androidTargetUri'] as String?;
          final saveAsMedia = record['saveAsMedia'] as bool? ?? false;
          final mimeType =
              record['mimeType'] as String? ?? 'application/octet-stream';
          final task = TransferTask(
            id: id,
            name: manifest.name,
            direction: TransferDirection.quickReceive,
            totalBytes: manifest.size,
            status: TransferStatus.failed,
            error: record['locallySaved'] == true
                ? '文件已经保存，领取状态尚未同步，可点击重试。'
                : '上次领取尚未完成，可以继续重试。',
          );
          tasks.add(task);
          if (record['locallySaved'] == true) _quickLocallySaved.add(id);
          if (!Platform.isAndroid && record['locallySaved'] != true) {
            _reservedQuickReceivePaths.add(target.path.toLowerCase());
          }
          final saver = Platform.isAndroid
              ? (File file) => _saveAndroidQuickTarget(
                  file,
                  manifest: manifest,
                  targetUri: targetUri,
                  saveAsMedia: saveAsMedia,
                  mimeType: mimeType,
                )
              : null;
          _retryActions[id] = (retryTask) => _runQuickReceiveTask(
            retryTask,
            manifest: manifest,
            target: target,
            finalize: true,
            saveTarget: saver,
          );
          _cleanupActions[id] = () async {
            final support = await getApplicationSupportDirectory();
            final staging = Directory(
              '${support.path}${Platform.pathSeparator}quick-transfer-receive${Platform.pathSeparator}${manifest.id}',
            );
            if (await staging.exists()) await staging.delete(recursive: true);
            _reservedQuickReceivePaths.remove(target.path.toLowerCase());
            if (!_quickLocallySaved.contains(id) && await target.exists()) {
              await target.delete();
            }
          };
          continue;
        }
        final source = File(record['sourcePath'] as String);
        final task = TransferTask(
          id: id,
          name: record['name'] as String,
          direction: kind == 'quick'
              ? TransferDirection.quickSend
              : TransferDirection.upload,
          totalBytes: (record['totalBytes'] as num).toInt(),
          status: TransferStatus.failed,
          error: await source.exists() ? '上次传输未完成，可以继续重试。' : '原文件已不存在，无法继续传输。',
        );
        tasks.add(task);
        if (!await source.exists()) continue;
        if (kind == 'quick') {
          final targetDevice = record['targetDevice'] as String;
          _retryActions[id] = (retryTask) async {
            final queued = _QueuedQuickTransfer(
              source: source,
              targetDevice: targetDevice,
              task: retryTask,
              name: task.name,
            );
            _quickSendQueue.add(queued);
            _syncForegroundTransfer(force: true);
            notifyListeners();
            unawaited(_processQuickSendQueue());
            await queued.completer.future;
          };
          _cleanupActions[id] = () async {
            try {
              await _gateway!.deleteEntry(
                '$_quickRoot/$_quickMessages/$id',
                recursive: true,
              );
            } catch (_) {}
            if (record['ownedSource'] == true && await source.exists()) {
              await source.delete();
            }
          };
          if (record['ownedSource'] == true) {
            _completionCleanupActions[id] = () async {
              if (await source.exists()) await source.delete();
            };
          }
        } else {
          final targetDirectory = record['targetDirectory'] as String;
          final overwrite = record['overwrite'] as bool? ?? true;
          _retryActions[id] = (retryTask) => _runUploadTask(
            retryTask,
            source: source,
            targetDirectory: targetDirectory,
            overwrite: overwrite,
          );
          _cleanupActions[id] = () async {
            await _gateway!.discardUploadPartial(
              targetDirectory: targetDirectory,
              targetName: task.name,
              resumeId: id,
            );
            if (record['ownedSource'] == true && await source.exists()) {
              await source.delete();
            }
          };
          if (record['ownedSource'] == true) {
            _completionCleanupActions[id] = () async {
              if (await source.exists()) await source.delete();
            };
          }
        }
      } catch (_) {
        recordsChanged = true;
        if (recordId != null) {
          _pendingTransferRecords.remove(recordId);
          tasks.removeWhere((task) => task.id == recordId);
          _retryActions.remove(recordId);
          _cleanupActions.remove(recordId);
          _completionCleanupActions.remove(recordId);
          _quickLocallySaved.remove(recordId);
        }
      }
    }
    if (recordsChanged) await _persistPendingTransfers();
    notifyListeners();
  }

  Future<void> _rememberPending(Map<String, Object?> record) async {
    _pendingTransferRecords[record['id']! as String] = record;
    await _persistPendingTransfers();
  }

  Future<void> _forgetPending(String id) async {
    if (_pendingTransferRecords.remove(id) != null) {
      await _persistPendingTransfers();
    }
  }

  Future<void> _persistPendingTransfers() {
    final snapshot = jsonEncode(
      _pendingTransferRecords.values.toList(growable: false),
    );
    final write = _pendingWriteTail.then((_) async {
      await _preferences.setString(_pendingTransfersKey, snapshot);
    });
    _pendingWriteTail = write.catchError((_) {});
    return write;
  }

  Future<_DurableSource> _prepareDurableSource(File source, String id) async {
    if (!Platform.isAndroid) return _DurableSource(source, owned: false);
    final support = await getApplicationSupportDirectory();
    final directory = Directory(
      '${support.path}${Platform.pathSeparator}pending-transfer-sources',
    );
    await directory.create(recursive: true);
    final target = File(
      '${directory.path}${Platform.pathSeparator}$id-${sanitizeTransferFileName(source.uri.pathSegments.last)}',
    );
    await source.copy(target.path);
    return _DurableSource(target, owned: true);
  }

  Future<void> _loadSftpProfile() async {
    final host = _preferences.getString(_hostKey);
    final username = _preferences.getString(_usernameKey);
    final fingerprint = _preferences.getString(_fingerprintKey);
    final password = await _secureStorage.read(key: _passwordKey);
    if (host == null ||
        username == null ||
        fingerprint == null ||
        password == null) {
      return;
    }
    sftpProfile = SftpConnectionProfile(
      host: host,
      port: _preferences.getInt(_portKey) ?? 2022,
      username: username,
      password: password,
      hostKeyFingerprint: fingerprint,
    );
  }

  Future<void> configureLocalRoot(String path) async {
    if (hasActiveTransfers) {
      throw StateError('Wait for active transfers before changing connection.');
    }
    final clean = path.trim();
    if (clean.isEmpty) throw ArgumentError('Repository path is required.');
    final candidate = LocalRepositoryGateway(clean);
    await _activateCandidate(
      candidate,
      onCommit: () async {
        localRoot = clean;
        mode = RepositoryMode.local;
        await _preferences.setString(_rootKey, clean);
        await _preferences.setString(_modeKey, mode.name);
      },
    );
  }

  Future<void> configureSftp(SftpConnectionProfile profile) async {
    if (hasActiveTransfers) {
      throw StateError('Wait for active transfers before changing connection.');
    }
    final support = await getApplicationSupportDirectory();
    final candidate = SerializedRepositoryGateway(
      SftpRepositoryGateway(
        profile,
        Directory('${support.path}${Platform.pathSeparator}preview-cache'),
      ),
    );
    await _activateCandidate(
      candidate,
      onCommit: () async {
        sftpProfile = profile;
        mode = RepositoryMode.sftp;
        await _preferences.setString(_hostKey, profile.host);
        await _preferences.setInt(_portKey, profile.port);
        await _preferences.setString(_usernameKey, profile.username);
        await _preferences.setString(
          _fingerprintKey,
          profile.hostKeyFingerprint,
        );
        await _preferences.setString(_modeKey, mode.name);
        await _secureStorage.write(key: _passwordKey, value: profile.password);
      },
    );
  }

  Future<void> _activateCandidate(
    RepositoryGateway candidate, {
    required Future<void> Function() onCommit,
  }) async {
    isLoading = true;
    connectionStatus = RepositoryConnectionStatus.connecting;
    notifyListeners();
    try {
      await candidate.initialize().timeout(const Duration(seconds: 15));
      final candidateEntries = await candidate
          .listDirectory('')
          .timeout(const Duration(seconds: 15));
      await onCommit();
      final previous = _gateway;
      _gateway = candidate;
      _invalidateQuickState();
      currentPath = '';
      entries = candidateEntries;
      isReady = true;
      needsTailscale = false;
      error = null;
      connectionStatus = RepositoryConnectionStatus.connected;
      // Repository availability is the primary lifecycle.  Publish it before
      // any quick-transfer work so the first screen can render immediately.
      isLoading = false;
      notifyListeners();
      await previous?.dispose();
      await _stopPhotoTransferServer();
      unawaited(_initializeQuickTransferSafely());
    } catch (_) {
      await candidate.dispose();
      rethrow;
    } finally {
      if (isLoading) {
        isLoading = false;
        notifyListeners();
      }
    }
  }

  Future<void> connect() {
    if (hasActiveTransfers) return Future<void>.value();
    final existing = _connectFuture;
    if (existing != null) return existing;
    final operation = _connectInternal();
    _connectFuture = operation;
    unawaited(
      operation.then<void>(
        (_) {
          if (identical(_connectFuture, operation)) _connectFuture = null;
        },
        onError: (Object _, StackTrace _) {
          if (identical(_connectFuture, operation)) _connectFuture = null;
        },
      ),
    );
    return operation;
  }

  Future<void> _connectInternal() async {
    isLoading = true;
    connectionStatus = isReady
        ? RepositoryConnectionStatus.retrying
        : RepositoryConnectionStatus.connecting;
    error = null;
    notifyListeners();
    try {
      await _stopPhotoTransferServer();
      await _gateway?.dispose();
      if (mode == RepositoryMode.local) {
        _gateway = LocalRepositoryGateway(localRoot);
      } else {
        final profile = sftpProfile;
        if (profile == null) {
          throw StateError('请在连接设置中填写 SFTPGo 的主机、账号、密码和主机密钥指纹。');
        }
        final support = await getApplicationSupportDirectory();
        _gateway = SerializedRepositoryGateway(
          SftpRepositoryGateway(
            profile,
            Directory('${support.path}${Platform.pathSeparator}preview-cache'),
          ),
        );
      }
      _invalidateQuickState();
      await _gateway!.initialize().timeout(const Duration(seconds: 15));
      currentPath = '';
      entries = await _retryOperation(() => _gateway!.listDirectory(''));
      unawaited(_recoverTemporaryFiles(''));
      isReady = true;
      needsTailscale = false;
      connectionStatus = RepositoryConnectionStatus.connected;
      isLoading = false;
      // The repository is usable now.  Do not hold the primary startup or
      // reconnect spinner open while quick-transfer metadata is prepared.
      notifyListeners();
      unawaited(_initializeQuickTransferSafely());
    } catch (exception) {
      error = describeError(exception);
      needsTailscale = _isTailscaleConnectivityError(exception);
      entries = const [];
      isReady = false;
      connectionStatus = RepositoryConnectionStatus.disconnected;
    } finally {
      if (isLoading) {
        isLoading = false;
        notifyListeners();
      }
    }
  }

  Future<void> _initializeQuickTransferSafely() {
    final existing = _quickInitializationFuture;
    if (existing != null &&
        _quickInitializationGeneration == _quickSessionGeneration) {
      return existing;
    }
    final generation = _quickSessionGeneration;
    final result = _quickInitializationTail.then(
      (_) => _initializeQuickTransferSafelyInternal(generation),
    );
    _quickInitializationFuture = result;
    _quickInitializationGeneration = generation;
    _quickInitializationTail = result.catchError((_) {});
    unawaited(
      result.then<void>(
        (_) {
          if (identical(_quickInitializationFuture, result)) {
            _quickInitializationFuture = null;
          }
        },
        onError: (Object _, StackTrace _) {
          if (identical(_quickInitializationFuture, result)) {
            _quickInitializationFuture = null;
          }
        },
      ),
    );
    return result;
  }

  Future<void> _initializeQuickTransferSafelyInternal(int generation) async {
    _quickInitializationActive = true;
    try {
      await _initializeQuickTransfer(generation);
      if (generation != _quickSessionGeneration || !isReady) return;
      quickError = null;
      _restartQuickMaintenanceTimer(allowDuringInitialization: true);
      notifyListeners();
    } catch (exception) {
      if (generation != _quickSessionGeneration || !isReady) return;
      await _stopPhotoTransferServer();
      quickError = describeError(exception);
      notifyListeners();
    } finally {
      _quickInitializationActive = false;
    }
  }

  Future<void> _maintainQuickPresence() async {
    if (!isReady ||
        deviceId.isEmpty ||
        hasRunningTransfers ||
        _quickInitializationActive ||
        _quickMaintenanceInProgress) {
      return;
    }
    _quickMaintenanceInProgress = true;
    final generation = _quickSessionGeneration;
    try {
      await _startPhotoTransferServer();
      await _publishDeviceRegistration();
      await refreshQuickTransfer(refreshDevices: true);
    } catch (exception) {
      if (generation != _quickSessionGeneration) return;
      quickError = describeError(exception);
      notifyListeners();
    } finally {
      _quickMaintenanceInProgress = false;
    }
  }

  Future<void> _startPhotoTransferServer() async {
    if (!Platform.isWindows && !Platform.isMacOS) {
      photoTransferError = null;
      return;
    }
    if (_photoTransferServer?.isRunning == true) return;
    await _stopPhotoTransferServer();
    if (defaultQuickSaveDirectory == null) {
      photoTransferError = '请先设置快传接收默认保存目录。';
      return;
    }
    var token = _preferences.getString(_photoTokenKey);
    if (token == null || token.length < 64) {
      token = _newPhotoToken();
      await _preferences.setString(_photoTokenKey, token);
    }
    final server = PhotoTransferServer(
      token: token,
      saveDirectoryProvider: () async => defaultQuickSaveDirectory,
    );
    try {
      if (await server.start()) {
        _photoTransferServer = server;
        photoTransferError = null;
      } else {
        photoTransferError = '未检测到 Tailscale 地址，照片直传暂不可用。';
      }
    } on SocketException {
      photoTransferError = '照片直传服务启动失败，请确认 Tailscale 正常运行。';
    }
  }

  Future<void> _stopPhotoTransferServer() async {
    final server = _photoTransferServer;
    _photoTransferServer = null;
    if (server != null) await server.stop();
  }

  String _newPhotoToken() => List<String>.generate(
    32,
    (_) => Random.secure().nextInt(0x100).toRadixString(16).padLeft(2, '0'),
  ).join();

  Future<void> onAppResumed() async {
    if (hasActiveTransfers || isLoading) return;
    if (!isReady) {
      await connect();
      return;
    }
    await refresh();
    unawaited(_maintainQuickPresence());
  }

  Future<void> refresh() async {
    final gateway = _gateway;
    if (gateway == null || _isRefreshingRepository) return;
    if (hasRunningTransfers) {
      _repositoryRefreshPending = true;
      return;
    }
    _repositoryRefreshPending = false;
    _isRefreshingRepository = true;
    isLoading = true;
    notifyListeners();
    try {
      entries = await _retryOperation(() => gateway.listDirectory(currentPath));
      unawaited(_recoverTemporaryFiles(currentPath));
      error = null;
      isReady = true;
      needsTailscale = false;
      connectionStatus = RepositoryConnectionStatus.connected;
    } catch (exception) {
      error = describeError(exception);
      needsTailscale = _isTailscaleConnectivityError(exception);
      isReady = false;
      connectionStatus = RepositoryConnectionStatus.disconnected;
    } finally {
      _isRefreshingRepository = false;
      isLoading = false;
      notifyListeners();
    }
  }

  bool _isTailscaleConnectivityError(Object exception) {
    if (mode != RepositoryMode.sftp) return false;
    final message = exception.toString().toLowerCase();
    return message.contains('failed host lookup') ||
        message.contains('no address associated with hostname') ||
        message.contains('getaddrinfo') ||
        message.contains('connection timed out') ||
        message.contains('connection refused') ||
        message.contains('network is unreachable');
  }

  bool _isMissingFileError(Object exception) {
    if (exception is FileSystemException) {
      final code = exception.osError?.errorCode;
      if (code == 2 || code == 3) return true;
    }
    final normalized = exception.toString().toLowerCase();
    return normalized.contains('no such file') ||
        normalized.contains('file not found') ||
        normalized.contains('path not found') ||
        normalized.contains('does not exist');
  }

  Future<_QuickPayloadInspection> _inspectMissingQuickPayload(
    String messagePath,
  ) async {
    final gateway = _gateway;
    if (gateway == null) {
      return (state: _QuickPayloadState.unknown, claimedManifest: null);
    }
    try {
      if (mode == RepositoryMode.local) {
        final safePath = normalizeRelativePath(messagePath);
        final package = Directory(
          '$localRoot${Platform.pathSeparator}${safePath.replaceAll('/', Platform.pathSeparator)}',
        );
        if (!await package.exists()) {
          return (state: _QuickPayloadState.removed, claimedManifest: null);
        }
      }
      final entries = await _retryOperation(
        () => gateway.listDirectory(messagePath),
      );
      if (!entries.any((entry) => entry.name == 'receipt.json')) {
        return (state: _QuickPayloadState.missing, claimedManifest: null);
      }
      try {
        final receipt = await _readQuickText('$messagePath/receipt.json');
        final claimed = QuickTransferManifest.fromJson(
          jsonDecode(receipt) as Map<String, dynamic>,
        );
        return claimed.isClaimed
            ? (state: _QuickPayloadState.claimed, claimedManifest: claimed)
            : (state: _QuickPayloadState.missing, claimedManifest: null);
      } catch (exception) {
        return _isMissingFileError(exception)
            ? (state: _QuickPayloadState.missing, claimedManifest: null)
            : (state: _QuickPayloadState.unknown, claimedManifest: null);
      }
    } catch (exception) {
      // A missing package means another participant already removed the
      // record. Connection/permission errors are deliberately left unknown
      // so a real missing payload remains an actionable failure.
      return _isMissingFileError(exception)
          ? (state: _QuickPayloadState.removed, claimedManifest: null)
          : (state: _QuickPayloadState.unknown, claimedManifest: null);
    }
  }

  void _hideQuickTransfer(String transferId) {
    _hiddenQuickTransferIds.add(transferId);
    _quickManifestCache.remove(
      '$_quickRoot/$_quickMessages/$transferId/manifest.json',
    );
    _removeQuickInboxItem(transferId);
  }

  String? _quickTransferIdFromManifestPath(String path) {
    const suffix = '/manifest.json';
    if (!path.endsWith(suffix)) return null;
    final packagePath = path.substring(0, path.length - suffix.length);
    final separator = packagePath.lastIndexOf('/');
    if (separator < 0 || separator == packagePath.length - 1) return null;
    return packagePath.substring(separator + 1);
  }

  void _removeQuickInboxItem(String transferId) {
    final filtered = quickInbox
        .where((item) => item.id != transferId)
        .toList(growable: false);
    if (filtered.length == quickInbox.length) return;
    quickInbox = filtered;
    notifyListeners();
  }

  void _replaceQuickInboxItem(QuickTransferManifest replacement) {
    var replaced = false;
    final updated = quickInbox
        .map((item) {
          if (item.id != replacement.id) return item;
          replaced = true;
          return replacement;
        })
        .toList(growable: false);
    if (!replaced) return;
    quickInbox = updated;
    _quickManifestCache[
      '$_quickRoot/$_quickMessages/${replacement.id}/manifest.json'
    ] = replacement;
    notifyListeners();
  }

  /// Converts implementation exceptions into safe, actionable user messages.
  /// Raw exception details are deliberately never presented in the UI.
  String describeError(Object exception) {
    final message = exception.toString();
    final normalized = message.toLowerCase();

    if (normalized.contains('failed host lookup') ||
        normalized.contains('no address associated with hostname') ||
        normalized.contains('getaddrinfo')) {
      return '无法解析服务器地址。请确认手机已连接 Tailscale、使用同一 Tailnet，并检查主机名是否填写正确。';
    }
    if (normalized.contains('connection refused')) {
      return '服务器拒绝连接。请确认接收电脑已开机，Jet2Drop SFTP 服务正在运行且端口 2022 未被防火墙阻止。';
    }
    if (normalized.contains('connection timed out') ||
        normalized.contains('sftp connection timed out') ||
        normalized.contains('sftp handshake timed out')) {
      return '连接服务器超时。请确认接收电脑未休眠、两台设备均已连接 Tailscale，然后重试。';
    }
    if (normalized.contains('timed out')) {
      return '传输在等待服务器响应时超时。请确认接收电脑未休眠、Tailscale 连接正常后重试；未完成的临时文件已自动清理。';
    }
    if (normalized.contains('authentication') ||
        normalized.contains('permission denied') ||
        normalized.contains('auth fail')) {
      return '身份验证失败。请检查 SFTP 用户名和密码是否正确。';
    }
    if (normalized.contains('host key') ||
        normalized.contains('fingerprint') ||
        normalized.contains('verification')) {
      return '服务器主机密钥指纹不匹配。为保护连接，Jet2Drop 已拒绝继续连接；请在 Windows 本机核验指纹后再更新设置。';
    }
    if (normalized.contains('file name') ||
        normalized.contains('folder name') ||
        normalized.contains('invalid name')) {
      return '名称无效，请勿包含 /、\\ 等路径字符。';
    }
    if (normalized.contains('path traversal') ||
        normalized.contains('root deletion')) {
      return '该操作不允许。';
    }
    if (normalized.contains('file exists') ||
        normalized.contains('already exists')) {
      return '同名文件已存在，请选择覆盖或保留两份。';
    }
    if (normalized.contains('no such file') ||
        normalized.contains('not found')) {
      return '文件不存在或已被移动，请刷新后重试。';
    }
    if (normalized.contains('checksum') ||
        normalized.contains('hash') ||
        normalized.contains('transfer package')) {
      return '文件校验失败，未保存，请重新传输。';
    }
    if (normalized.contains('at most 100 files')) {
      return '一次最多选择 100 个文件，请分批传输。';
    }
    if (normalized.contains('cannot exceed 10 gb')) {
      return '本次选择超过 10 GB，请分批传输。';
    }
    if (normalized.contains('enough free space')) {
      return '目标设备空间不足，请清理空间后重试。';
    }
    if (normalized.contains('active transfers')) {
      return '有任务正在传输，请完成或取消后再更改连接。';
    }
    if (normalized.contains('默认保存')) {
      return message.replaceFirst(RegExp(r'^Bad state:\s*'), '');
    }
    if (normalized.startsWith('bad state: download failed:')) {
      return message.substring('Bad state: Download failed:'.length).trim();
    }
    if (exception is SocketException) {
      return '网络连接失败，请检查网络和 Tailscale 连接状态。';
    }
    return '操作失败。请稍后重试；若持续发生，请检查连接设置和网络状态。';
  }

  Future<void> _initializeQuickTransfer(int generation) async {
    await _loadQuickIdentity();
    if (generation != _quickSessionGeneration) return;
    await _startPhotoTransferServer();
    if (generation != _quickSessionGeneration) return;
    await _ensureQuickDirectories(generation: generation);
    if (generation != _quickSessionGeneration) return;
    await _publishDeviceRegistration();
    if (generation != _quickSessionGeneration) return;
    await refreshQuickTransfer(refreshDevices: true);
  }

  void _invalidateQuickState() {
    _quickSessionGeneration++;
    _stopQuickMaintenanceTimer();
    _lastQuickPresenceUpdate = null;
    _lastQuickDeviceRefresh = null;
    _quickManifestCache.clear();
    quickDevices = const [];
    quickInbox = const [];
  }

  Future<void> _loadQuickIdentity() async {
    deviceId = _preferences.getString(_deviceIdKey) ?? '';
    if (deviceId.isEmpty) {
      deviceId = List<String>.generate(
        4,
        (_) => Random.secure()
            .nextInt(0x100000000)
            .toRadixString(16)
            .padLeft(8, '0'),
      ).join('-');
      await _preferences.setString(_deviceIdKey, deviceId);
    }
    deviceName = _preferences.getString(_deviceNameKey) ?? _defaultDeviceName;
    await _preferences.setString(_deviceNameKey, deviceName);
  }

  String get _defaultDeviceName {
    if (Platform.isWindows) return 'Windows 主机';
    if (Platform.isMacOS) return 'Mac';
    if (Platform.isAndroid) return 'Android 设备';
    return 'Jet2Drop 设备';
  }

  Future<void> setQuickDeviceName(String value) async {
    final clean = value.trim();
    if (clean.isEmpty) return;
    deviceName = clean;
    await _preferences.setString(_deviceNameKey, clean);
    await _publishDeviceRegistration();
    await refreshQuickTransfer(refreshDevices: true);
  }

  Future<void> _ensureQuickDirectories({int? generation}) async {
    final gateway = _gateway;
    if (gateway == null) throw StateError('Repository is not connected.');
    await _ensureDirectory('', _quickRoot, gateway: gateway);
    if (generation != null && generation != _quickSessionGeneration) return;
    await _ensureDirectory(_quickRoot, 'devices', gateway: gateway);
    if (generation != null && generation != _quickSessionGeneration) return;
    await _ensureDirectory(_quickRoot, _quickMessages, gateway: gateway);
  }

  Future<void> _ensureDirectory(
    String parent,
    String name, {
    RepositoryGateway? gateway,
  }) async {
    final targetGateway = gateway ?? _gateway;
    if (targetGateway == null) {
      throw StateError('Repository is not connected.');
    }
    try {
      await targetGateway.createDirectory(parent, name);
    } catch (exception, stackTrace) {
      final expected = joinRelativePath(parent, name);
      try {
        // Listing the directory itself validates it even when its name is
        // deliberately hidden from the parent repository view.
        await targetGateway.listDirectory(expected);
        return;
      } catch (_) {}
      Error.throwWithStackTrace(exception, stackTrace);
    }
  }

  Future<File> _writeQuickJson(String name, Map<String, Object> json) async {
    final support = await getApplicationSupportDirectory();
    final file = File('${support.path}${Platform.pathSeparator}$name');
    await file.parent.create(recursive: true);
    await file.writeAsString(jsonEncode(json), flush: true);
    return file;
  }

  Future<void> _publishDeviceRegistration() async {
    final photoServer = _photoTransferServer;
    final registration = QuickDevice(
      id: deviceId,
      name: deviceName,
      updatedAt: DateTime.now(),
      photoEndpoint: photoServer?.endpoint,
      photoToken: photoServer?.isRunning == true ? photoServer!.token : null,
    );
    final source = await _writeQuickJson(
      'quick-device-$deviceId.json',
      registration.toJson(),
    );
    try {
      await _retryOperation(
        () => _gateway!.uploadFile(
          source: source,
          targetDirectory: '$_quickRoot/devices',
          targetName: '$deviceId.json',
          overwrite: true,
        ),
      );
      _lastQuickPresenceUpdate = DateTime.now();
    } finally {
      if (await source.exists()) await source.delete();
    }
  }

  Future<String> _readQuickText(String remotePath) async {
    if (mode == RepositoryMode.local) {
      final safePath = normalizeRelativePath(remotePath);
      return File(
        '$localRoot${Platform.pathSeparator}${safePath.replaceAll('/', Platform.pathSeparator)}',
      ).readAsString();
    }
    final support = await getApplicationSupportDirectory();
    final file = File(
      '${support.path}${Platform.pathSeparator}quick-transfer-read-${uniqueSuffix()}.json',
    );
    try {
      await _retryOperation(
        () => _gateway!.downloadFile(remotePath: remotePath, target: file),
      );
      return await file.readAsString();
    } finally {
      if (await file.exists()) await file.delete();
    }
  }

  Future<void> refreshQuickTransfer({bool refreshDevices = false}) async {
    final gateway = _gateway;
    if (gateway == null || deviceId.isEmpty) {
      return;
    }
    if (_quickMutationInProgress) {
      _quickRefreshPending = true;
      _quickRefreshDevicesPending =
          _quickRefreshDevicesPending || refreshDevices;
      return;
    }
    if (hasRunningTransfers) {
      _quickRefreshPending = true;
      _quickRefreshDevicesPending =
          _quickRefreshDevicesPending || refreshDevices;
      return;
    }
    final idle = _quickRefreshIdle ??= Completer<void>();
    if (_isRefreshingQuickTransfer) {
      _quickRefreshPending = true;
      _quickRefreshDevicesPending =
          _quickRefreshDevicesPending || refreshDevices;
      return idle.future;
    }
    final forceDeviceRefresh = refreshDevices || _quickRefreshDevicesPending;
    _quickRefreshDevicesPending = false;
    _quickRefreshPending = false;
    _isRefreshingQuickTransfer = true;
    final generation = ++_quickRefreshGeneration;
    try {
      var registered = quickDevices;
      final shouldRefreshDevices =
          forceDeviceRefresh ||
          _lastQuickDeviceRefresh == null ||
          DateTime.now().difference(_lastQuickDeviceRefresh!) >=
              const Duration(minutes: 1);
      if (shouldRefreshDevices) {
        final discovered = <QuickDevice>[];
        try {
          for (final entry in await _retryOperation(
            () => gateway.listDirectory('$_quickRoot/devices'),
          )) {
            if (entry.isDirectory || !entry.name.endsWith('.json')) continue;
            try {
              final device = QuickDevice.fromJson(
                jsonDecode(await _readQuickText(entry.path))
                    as Map<String, dynamic>,
              );
              final age = DateTime.now().difference(device.updatedAt);
              if (age < const Duration(hours: 24)) discovered.add(device);
              if (age > const Duration(days: 7)) {
                unawaited(
                  gateway
                      .deleteEntry(entry.path, recursive: false)
                      .catchError((_) {}),
                );
              }
            } catch (_) {}
          }
        } catch (_) {
          // Device names are optional metadata. Continue loading messages.
        }
        discovered.sort(
          (left, right) =>
              left.name.toLowerCase().compareTo(right.name.toLowerCase()),
        );
        registered = discovered;
        _lastQuickDeviceRefresh = DateTime.now();
      }
      final inbox = <QuickTransferManifest>[];
      try {
        final manifestPaths = <String>[];
        if (mode == RepositoryMode.local) {
          final messages = Directory(
            '$localRoot${Platform.pathSeparator}$_quickRoot${Platform.pathSeparator}$_quickMessages',
          );
          if (await messages.exists()) {
            await for (final entity in messages.list(followLinks: false)) {
              if (entity is Directory) {
                final packageName = entity.path
                    .split(Platform.pathSeparator)
                    .last;
                manifestPaths.add(
                  '$_quickRoot/$_quickMessages/$packageName/manifest.json',
                );
              }
            }
          }
        } else {
          for (final package in await _retryOperation(
            () => gateway.listDirectory('$_quickRoot/$_quickMessages'),
          )) {
            if (package.isDirectory) {
              manifestPaths.add('${package.path}/manifest.json');
            }
          }
        }
        for (final manifestPath in manifestPaths) {
          try {
            // Local repository reads do not pay a network round trip, so
            // always observe the current manifest there. SFTP keeps the
            // cache because the package directory listing is the authoritative
            // change signal and each manifest read costs another relay RTT.
            final cached = mode == RepositoryMode.sftp
                ? _quickManifestCache[manifestPath]
                : null;
            var value =
                cached ??
                QuickTransferManifest.fromJson(
                  jsonDecode(
                        await _readQuickText(
                          manifestPath,
                        ).timeout(const Duration(seconds: 10)),
                      )
                      as Map<String, dynamic>,
                );
            _quickManifestCache[manifestPath] = value;
            if (!value.isClaimed) {
              final receiptPath = manifestPath.replaceFirst(
                '/manifest.json',
                '/receipt.json',
              );
              try {
                final receipt = await _readQuickText(
                  receiptPath,
                ).timeout(const Duration(seconds: 5));
                value = QuickTransferManifest.fromJson(
                  jsonDecode(receipt) as Map<String, dynamic>,
                );
                _quickManifestCache[manifestPath] = value;
              } catch (_) {
                // A receipt is optional until the target device saves the
                // file.
              }
            }
            if (value.expiresAt.isBefore(DateTime.now().toUtc())) {
              await _retryOperation(
                () => gateway.deleteEntry(
                  manifestPath.substring(
                    0,
                    manifestPath.length - '/manifest.json'.length,
                  ),
                  recursive: true,
                ),
              );
              _quickManifestCache.remove(manifestPath);
            } else if (!_hiddenQuickTransferIds.contains(value.id) &&
                (value.senderDevice == deviceId ||
                    value.targetDevice == deviceId)) {
              inbox.add(value);
            }
          } catch (exception, stackTrace) {
            if (_isMissingFileError(exception)) {
              // A package directory can outlive its manifest while another
              // participant is publishing or deleting it. Drop only this
              // stale cache/list item; a real connection error remains
              // visible through the normal quick-transfer error path.
              _quickManifestCache.remove(manifestPath);
              final transferId = _quickTransferIdFromManifestPath(manifestPath);
              if (transferId != null) _removeQuickInboxItem(transferId);
              continue;
            }
            Error.throwWithStackTrace(exception, stackTrace);
          }
        }
        _quickManifestCache.removeWhere(
          (path, _) => !manifestPaths.contains(path),
        );
      } catch (exception, stackTrace) {
        await _resetConnection();
        Error.throwWithStackTrace(exception, stackTrace);
      }
      inbox.sort((left, right) => right.createdAt.compareTo(left.createdAt));
      if (generation == _quickRefreshGeneration &&
          identical(gateway, _gateway)) {
        quickDevices = registered;
        quickInbox = inbox;
        quickError = null;
        notifyListeners();
      } else {
        _quickRefreshPending = true;
      }
    } catch (exception) {
      if (generation == _quickRefreshGeneration &&
          identical(gateway, _gateway) &&
          !hasRunningTransfers) {
        quickError = describeError(exception);
        notifyListeners();
      } else {
        _quickRefreshPending = true;
      }
    } finally {
      _isRefreshingQuickTransfer = false;
      if (_quickRefreshPending &&
          !hasRunningTransfers &&
          !_quickMutationInProgress) {
        final nextForceDeviceRefresh =
            forceDeviceRefresh || _quickRefreshDevicesPending;
        _quickRefreshDevicesPending = false;
        unawaited(refreshQuickTransfer(refreshDevices: nextForceDeviceRefresh));
      } else if (!idle.isCompleted) {
        idle.complete();
        if (identical(_quickRefreshIdle, idle)) _quickRefreshIdle = null;
      }
    }
    await idle.future;
  }

  Future<void> open(FileEntry entry) async {
    if (!entry.isDirectory) return;
    currentPath = entry.path;
    await refresh();
  }

  Future<void> goUp() async {
    if (currentPath.isEmpty) return;
    final parts = currentPath.split('/');
    parts.removeLast();
    currentPath = parts.join('/');
    await refresh();
  }

  Future<void> createDirectory(String name) async {
    final safeName = sanitizeTransferFileName(name);
    if (entries.any(
      (entry) => entry.name.toLowerCase() == safeName.toLowerCase(),
    )) {
      throw FileSystemException('同名文件或文件夹已存在。', safeName);
    }
    await _retryOperation(
      () => _gateway!.createDirectory(currentPath, safeName),
    );
    await refresh();
  }

  Future<void> deleteEntry(FileEntry entry) async {
    await _retryOperation(
      () => _gateway!.deleteEntry(entry.path, recursive: entry.isDirectory),
    );
    await refresh();
  }

  Future<void> uploadFiles(
    List<File> files, {
    required bool overwrite,
    bool keepBoth = false,
  }) async {
    await validateTransferSelection(files);
    final reservedNames = entries
        .map((entry) => entry.name.toLowerCase())
        .toSet();
    final selectedNames = <String>{};
    final settledTasks = <Future<void>>[];
    for (final file in files) {
      final sourceName = sanitizeTransferFileName(file.uri.pathSegments.last);
      final duplicateInBatch = !selectedNames.add(sourceName.toLowerCase());
      final targetName = keepBoth || duplicateInBatch
          ? _availableName(sourceName, reservedNames)
          : sourceName;
      reservedNames.add(targetName.toLowerCase());
      final targetDirectory = currentPath;
      final taskId = uniqueSuffix();
      final durableSource = await _prepareDurableSource(file, taskId);
      final task = TransferTask(
        id: taskId,
        name: targetName,
        direction: TransferDirection.upload,
        totalBytes: await durableSource.file.length(),
        status: TransferStatus.running,
      );
      tasks.insert(0, task);
      final settled = Completer<void>();
      _taskSettled[task.id] = settled;
      settledTasks.add(settled.future);
      _retryActions[task.id] = (retryTask) => _runUploadTask(
        retryTask,
        source: durableSource.file,
        targetDirectory: targetDirectory,
        overwrite: overwrite,
      );
      _cleanupActions[task.id] = () => _gateway!
          .discardUploadPartial(
            targetDirectory: targetDirectory,
            targetName: targetName,
            resumeId: task.id,
          )
          .whenComplete(() => durableSource.deleteIfOwned());
      _completionCleanupActions[task.id] = durableSource.deleteIfOwned;
      await _rememberPending({
        'kind': 'upload',
        'id': task.id,
        'sourcePath': durableSource.file.path,
        'ownedSource': durableSource.owned,
        'name': targetName,
        'totalBytes': task.totalBytes,
        'targetDirectory': targetDirectory,
        'overwrite': overwrite,
      });
      await _retryActions[task.id]!(task);
      if (task.cancelRequested) break;
    }
    await Future.wait(settledTasks);
    await refresh();
  }

  Future<void> _runUploadTask(
    TransferTask task, {
    required File source,
    required String targetDirectory,
    required bool overwrite,
  }) async {
    final control = TransferControl();
    _transferControls[task.id] = control;
    _syncForegroundTransfer(force: true);
    task
      ..status = TransferStatus.running
      ..error = null
      ..cancelRequested = false
      ..isPaused = false;
    notifyListeners();
    var resumeAfterYield = false;
    try {
      if (!await source.exists()) {
        throw FileSystemException('Selected file is unavailable.', source.path);
      }
      await _ensureRemoteSpace(await source.length(), targetDirectory);
      await _retryOperation(
        () => _gateway!.uploadFile(
          source: source,
          targetDirectory: targetDirectory,
          targetName: task.name,
          overwrite: overwrite,
          resumeId: task.id,
          onProgress: (current, _) {
            task.transferredBytes = current;
            _notifyTransferProgress();
          },
          control: control,
        ),
      );
      task
        ..transferredBytes = task.totalBytes
        ..status = TransferStatus.completed;
      _cleanupActions.remove(task.id);
      await _runCompletionCleanup(task.id);
      await _forgetPending(task.id);
    } catch (exception) {
      if (control.isDeferred && !task.cancelRequested) {
        task.error = null;
        if (_resumeAfterYield.remove(task.id)) {
          task
            ..isPaused = false
            ..status = TransferStatus.queued;
          resumeAfterYield = true;
        }
      } else if (!task.cancelRequested) {
        task.status = TransferStatus.failed;
        task.error = describeError(exception);
      }
    } finally {
      if (identical(_transferControls[task.id], control)) {
        _transferControls.remove(task.id);
      }
      _syncForegroundTransfer(force: true);
      notifyListeners();
      if (resumeAfterYield) {
        final action = _retryActions[task.id];
        if (action != null) unawaited(action(task));
      }
      if (task.status == TransferStatus.completed ||
          task.status == TransferStatus.failed ||
          task.status == TransferStatus.cancelled) {
        final settled = _taskSettled.remove(task.id);
        if (settled != null && !settled.isCompleted) settled.complete();
      }
    }
  }

  String _availableName(String name, Set<String> names) {
    if (!names.contains(name.toLowerCase())) return name;
    final dot = name.lastIndexOf('.');
    final stem = dot > 0 ? name.substring(0, dot) : name;
    final extension = dot > 0 ? name.substring(dot) : '';
    for (var index = 2; ; index++) {
      final candidate = '$stem ($index)$extension';
      if (!names.contains(candidate.toLowerCase())) return candidate;
    }
  }

  Future<void> downloadFile(
    FileEntry entry,
    File target, {
    void Function(TransferTask task)? onTaskCreated,
    Future<void> Function(File file)? finalize,
    bool deleteTargetOnCancel = false,
    String? androidTargetUri,
  }) async {
    final task = TransferTask(
      id: uniqueSuffix(),
      name: entry.name,
      direction: TransferDirection.download,
      totalBytes: entry.size,
      status: TransferStatus.running,
    );
    tasks.insert(0, task);
    onTaskCreated?.call(task);
    final finalizer =
        finalize ??
        (androidTargetUri == null
            ? null
            : (File file) async {
                final saved = await AndroidSaveFile.saveToDocumentTarget(
                  source: file,
                  targetUri: androidTargetUri,
                );
                if (!saved) throw StateError('Final save failed.');
                if (await file.exists()) await file.delete();
              });
    _cleanupActions[task.id] = () async {
      final partial = File('${target.path}.jet2drop-download-${task.id}.part');
      if (await partial.exists()) await partial.delete();
      if (deleteTargetOnCancel && await target.exists()) await target.delete();
    };
    _retryActions[task.id] = (retryTask) => _runDownloadTask(
      retryTask,
      entry: entry,
      target: target,
      finalize: finalizer,
    );
    await _rememberPending({
      'kind': 'download',
      'id': task.id,
      'name': task.name,
      'totalBytes': task.totalBytes,
      'remotePath': entry.path,
      'modifiedAt': entry.modifiedAt.toUtc().toIso8601String(),
      'targetPath': target.path,
      'androidTargetUri': ?androidTargetUri,
      'deleteTargetOnCancel': deleteTargetOnCancel,
    });
    await _retryActions[task.id]!(task);
    if (task.status == TransferStatus.failed) {
      throw StateError(task.error ?? 'Download failed.');
    }
  }

  Future<void> _runDownloadTask(
    TransferTask task, {
    required FileEntry entry,
    required File target,
    Future<void> Function(File file)? finalize,
  }) async {
    final control = TransferControl();
    _transferControls[task.id] = control;
    _syncForegroundTransfer(force: true);
    task
      ..status = TransferStatus.running
      ..error = null
      ..cancelRequested = false
      ..isPaused = false;
    notifyListeners();
    try {
      final alreadyDownloaded =
          await target.exists() && await target.length() == entry.size;
      if (!alreadyDownloaded) {
        await _retryOperation(
          () => _gateway!.downloadFile(
            remotePath: entry.path,
            target: target,
            resumeId: task.id,
            onProgress: (current, _) {
              task.transferredBytes = current;
              _notifyTransferProgress();
            },
            control: control,
          ),
        );
      }
      task
        ..transferredBytes = task.totalBytes
        ..status = TransferStatus.finalizing;
      notifyListeners();
      if (finalize != null) await finalize(target);
      task.status = TransferStatus.completed;
      _cleanupActions.remove(task.id);
      await _forgetPending(task.id);
    } catch (exception) {
      if (!task.cancelRequested) {
        task.status = TransferStatus.failed;
        task.error = describeError(exception);
      }
    }
    _transferControls.remove(task.id);
    _syncForegroundTransfer(force: true);
    notifyListeners();
  }

  Future<void> retryTask(TransferTask task) async {
    if (task.status != TransferStatus.failed) return;
    final action = _retryActions[task.id];
    if (action == null) return;
    task.transferredBytes = 0;
    await action(task);
    if (task.status == TransferStatus.completed) {
      await refresh();
    }
  }

  void pauseTask(TransferTask task) {
    if (task.status != TransferStatus.running ||
        task.isPaused ||
        !task.supportsPause) {
      return;
    }
    task.isPaused = true;
    final control = _transferControls[task.id];
    if (task.direction == TransferDirection.upload ||
        task.direction == TransferDirection.quickSend) {
      unawaited(control?.defer());
    } else {
      control?.pause();
    }
    notifyListeners();
  }

  void resumeTask(TransferTask task) {
    if (task.status != TransferStatus.running || !task.isPaused) {
      return;
    }
    if (task.direction == TransferDirection.quickSend) {
      task.isPaused = false;
      final queued = _pausedQuickTransfers.remove(task.id);
      if (queued != null) {
        task.status = TransferStatus.queued;
        _quickSendQueue.add(queued);
        unawaited(_processQuickSendQueue());
      } else {
        _resumeAfterYield.add(task.id);
      }
    } else if (task.direction == TransferDirection.upload) {
      task.isPaused = false;
      if (_transferControls.containsKey(task.id)) {
        _resumeAfterYield.add(task.id);
      } else {
        task.status = TransferStatus.queued;
        final action = _retryActions[task.id];
        if (action != null) unawaited(action(task));
      }
    } else {
      _transferControls[task.id]?.resume();
      task.isPaused = false;
    }
    notifyListeners();
  }

  Future<void> cancelTask(TransferTask task) async {
    final pausedQuick = _pausedQuickTransfers.remove(task.id);
    if (pausedQuick != null) {
      task
        ..cancelRequested = true
        ..status = TransferStatus.cancelled
        ..isPaused = false
        ..error = null;
      if (!pausedQuick.completer.isCompleted) {
        pausedQuick.completer.completeError(const TransferCancelled());
      }
      await _runTaskCleanup(task.id);
      await _forgetPending(task.id);
      notifyListeners();
      return;
    }
    if (task.status == TransferStatus.queued) {
      task.cancelRequested = true;
      task.status = TransferStatus.cancelled;
      final index = _quickSendQueue.indexWhere(
        (queued) => queued.task.id == task.id,
      );
      if (index >= 0) {
        final queued = _quickSendQueue.removeAt(index);
        if (!queued.completer.isCompleted) {
          queued.completer.completeError(const TransferCancelled());
        }
      }
      await _runTaskCleanup(task.id);
      await _forgetPending(task.id);
      notifyListeners();
      return;
    }
    if (task.status != TransferStatus.running) {
      return;
    }
    task.cancelRequested = true;
    task.status = TransferStatus.cancelled;
    task.isPaused = false;
    task.error = null;
    notifyListeners();
    await _transferControls[task.id]?.cancel();
    await _runTaskCleanup(task.id);
    await _forgetPending(task.id);
    final settled = _taskSettled.remove(task.id);
    if (settled != null && !settled.isCompleted) settled.complete();
  }

  Future<void> _runTaskCleanup(String taskId) async {
    _completionCleanupActions.remove(taskId);
    final cleanup = _cleanupActions.remove(taskId);
    if (cleanup == null) return;
    try {
      await cleanup();
    } catch (_) {
      // Cleanup is best-effort and is retried by repository maintenance.
    }
  }

  Future<void> _runCompletionCleanup(String taskId) async {
    final cleanup = _completionCleanupActions.remove(taskId);
    if (cleanup != null) await cleanup();
  }

  void removeTask(TransferTask task) {
    if (task.status == TransferStatus.running ||
        task.status == TransferStatus.finalizing ||
        task.status == TransferStatus.queued) {
      return;
    }
    tasks.remove(task);
    _retryActions.remove(task.id);
    unawaited(_runTaskCleanup(task.id));
    _completionCleanupActions.remove(task.id);
    unawaited(_forgetPending(task.id));
    _taskSettled.remove(task.id);
    notifyListeners();
  }

  Future<void> clearFinishedTasks() async {
    final finished = tasks
        .where(
          (task) =>
              task.status == TransferStatus.completed ||
              task.status == TransferStatus.cancelled,
        )
        .toList(growable: false);
    for (final task in finished) {
      tasks.remove(task);
      _retryActions.remove(task.id);
      await _runTaskCleanup(task.id);
      await _forgetPending(task.id);
      _taskSettled.remove(task.id);
    }
    notifyListeners();
  }

  Future<File> previewFile(FileEntry entry, {TransferControl? control}) =>
      _retryOperation(
        () => _gateway!.materializeForPreview(entry.path, control: control),
      );

  Future<void> releasePreview(File file) async {
    if (mode == RepositoryMode.sftp && await file.exists()) {
      await file.delete();
    }
  }

  Future<QuickTransferManifest> publishQuickTransfer(
    File source, {
    required String targetDevice,
    String? originalName,
    String? mimeType,
    bool isPhoto = false,
  }) async {
    final target = targetDevice.trim();
    if (target.isEmpty || target == deviceId) {
      throw ArgumentError('Cannot send a quick transfer to this device.');
    }
    final name = sanitizeTransferFileName(
      originalName ?? source.uri.pathSegments.last,
    );
    QuickDevice? recipient = quickRecipients
        .where((item) => item.id == target)
        .firstOrNull;
    if (isPhoto && (recipient == null || !recipient.supportsPhotoTransfer)) {
      // Device registrations are deliberately cached for ordinary inbox
      // refreshes, but a photo send must confirm the receiver's current
      // capability before creating a running task.  This covers a desktop
      // that has just selected its save directory and republished its token.
      await refreshQuickTransfer(refreshDevices: true);
      recipient = quickRecipients
          .where((item) => item.id == target)
          .firstOrNull;
    }
    if (recipient == null) {
      throw ArgumentError(
        'The target device is unavailable or belongs to this device.',
      );
    }
    await validateTransferSelection([source]);
    if (isPhoto) {
      final selectedMime = normalizeMimeType(mimeType);
      if (!isSupportedPhotoTransfer(name: name, mimeType: selectedMime)) {
        throw StateError('照片必须同时具有受支持的图片扩展名和 MIME 类型。');
      }
      if (!recipient.supportsPhotoTransfer) {
        throw const PhotoTransferException('目标设备尚未启用照片直传，请先设置默认保存目录并保持目标应用打开。');
      }
      return _publishPhotoTransfer(
        source,
        targetDevice: target,
        name: name,
        mimeType: selectedMime,
        recipient: recipient,
      );
    }
    final taskId = uniqueSuffix();
    final durableSource = await _prepareDurableSource(source, taskId);
    final task = TransferTask(
      id: taskId,
      name: name,
      direction: TransferDirection.quickSend,
      totalBytes: await durableSource.file.length(),
      status: TransferStatus.queued,
    );
    tasks.insert(0, task);
    final queued = _QueuedQuickTransfer(
      source: durableSource.file,
      targetDevice: target,
      task: task,
      name: name,
    );
    _quickSendQueue.add(queued);
    _syncForegroundTransfer(force: true);
    _cleanupActions[task.id] = () async {
      try {
        await _gateway!.deleteEntry(
          '$_quickRoot/$_quickMessages/${task.id}',
          recursive: true,
        );
      } catch (_) {}
      await durableSource.deleteIfOwned();
    };
    _completionCleanupActions[task.id] = durableSource.deleteIfOwned;
    await _rememberPending({
      'kind': 'quick',
      'id': task.id,
      'sourcePath': durableSource.file.path,
      'ownedSource': durableSource.owned,
      'name': task.name,
      'totalBytes': task.totalBytes,
      'targetDevice': target,
    });
    _retryActions[task.id] = (retryTask) async {
      final retry = _QueuedQuickTransfer(
        source: durableSource.file,
        targetDevice: target,
        task: retryTask,
        name: task.name,
      );
      _quickSendQueue.add(retry);
      notifyListeners();
      unawaited(_processQuickSendQueue());
      await retry.completer.future;
    };
    notifyListeners();

    unawaited(_processQuickSendQueue());
    return queued.completer.future;
  }

  Future<QuickTransferManifest> _publishPhotoTransfer(
    File source, {
    required String targetDevice,
    required String name,
    required String mimeType,
    required QuickDevice recipient,
  }) async {
    if (!recipient.supportsPhotoTransfer) {
      throw const PhotoTransferException('目标设备尚未启用照片直传，请先设置默认保存目录并保持目标应用打开。');
    }
    final taskId = uniqueSuffix();
    final task = TransferTask(
      id: taskId,
      name: name,
      direction: TransferDirection.quickSend,
      totalBytes: await source.length(),
      status: TransferStatus.running,
      supportsPause: false,
    );
    tasks.insert(0, task);
    final control = TransferControl();
    _transferControls[task.id] = control;
    _syncForegroundTransfer(force: true);
    notifyListeners();
    try {
      final receipt = await _photoTransferClient.send(
        endpoint: recipient.photoEndpoint!,
        token: recipient.photoToken!,
        source: source,
        fileName: name,
        mimeType: mimeType,
        control: control,
        onProgress: (current, _) {
          task.transferredBytes = current;
          _notifyTransferProgress();
        },
      );
      task
        ..transferredBytes = receipt.size
        ..status = TransferStatus.completed;
      return quickTransfer.describe(
        source,
        name: receipt.name,
        size: receipt.size,
        checksum: receipt.sha256,
        senderDevice: deviceId,
        targetDevice: targetDevice,
        transferId: task.id,
      );
    } on TransferCancelled {
      task
        ..status = TransferStatus.cancelled
        ..cancelRequested = true
        ..isPaused = false;
      rethrow;
    } catch (exception) {
      if (control.isCancelled || task.cancelRequested) {
        task
          ..status = TransferStatus.cancelled
          ..isPaused = false;
        throw const TransferCancelled();
      }
      task
        ..status = TransferStatus.failed
        ..error = exception is PhotoTransferException
            ? exception.message
            : describeError(exception);
      rethrow;
    } finally {
      _transferControls.remove(task.id);
      _syncForegroundTransfer(force: true);
      if (task.status == TransferStatus.completed && isReady) {
        unawaited(refreshQuickTransfer());
      }
      notifyListeners();
    }
  }

  Future<void> _processQuickSendQueue() async {
    if (_isProcessingQuickSendQueue) return;
    _isProcessingQuickSendQueue = true;
    try {
      while (_quickSendQueue.isNotEmpty) {
        final queued = _quickSendQueue.removeAt(0);
        final task = queued.task;
        if (task.cancelRequested || task.status == TransferStatus.cancelled) {
          if (!queued.completer.isCompleted) {
            queued.completer.completeError(const TransferCancelled());
          }
          continue;
        }

        final control = TransferControl();
        _transferControls[task.id] = control;
        _syncForegroundTransfer(force: true);
        task.status = TransferStatus.running;
        task.error = null;
        notifyListeners();

        try {
          final manifest = await _executeQuickTransfer(
            queued.source,
            targetDevice: queued.targetDevice,
            name: queued.name,
            task: task,
            control: control,
          );
          task.transferredBytes = task.totalBytes;
          task.status = TransferStatus.completed;
          _cleanupActions.remove(task.id);
          await _runCompletionCleanup(task.id);
          await _forgetPending(task.id);
          if (!queued.completer.isCompleted) {
            queued.completer.complete(manifest);
          }
        } catch (exception, stackTrace) {
          if (control.isDeferred && !task.cancelRequested) {
            task.error = null;
            final resumeImmediately = _resumeAfterYield.remove(task.id);
            if (resumeImmediately) {
              task
                ..isPaused = false
                ..status = TransferStatus.queued;
              _quickSendQueue.add(queued);
            } else {
              task
                ..isPaused = true
                ..status = TransferStatus.running;
              _pausedQuickTransfers[task.id] = queued;
            }
          } else if (!task.cancelRequested) {
            task.status = TransferStatus.failed;
            task.error = describeError(exception);
            if (!queued.completer.isCompleted) {
              queued.completer.completeError(exception, stackTrace);
            }
          } else if (!queued.completer.isCompleted) {
            queued.completer.completeError(exception, stackTrace);
          }
        } finally {
          _transferControls.remove(task.id);
          _syncForegroundTransfer(force: true);
          notifyListeners();
        }
      }
    } finally {
      _isProcessingQuickSendQueue = false;
      if (_quickSendQueue.isNotEmpty) {
        unawaited(_processQuickSendQueue());
      } else if (isReady) {
        unawaited(refreshQuickTransfer());
      }
    }
  }

  Future<QuickTransferManifest> _executeQuickTransfer(
    File source, {
    required String targetDevice,
    required String name,
    required TransferTask task,
    required TransferControl control,
  }) async {
    Directory? staging;
    try {
      await _ensureRemoteSpace(task.totalBytes, _quickRoot);
      final support = await getApplicationSupportDirectory();
      staging = Directory(
        '${support.path}${Platform.pathSeparator}quick-transfer-staging${Platform.pathSeparator}${uniqueSuffix()}',
      );
      await staging.create(recursive: true);
      final remotePackage = '$_quickRoot/$_quickMessages/${task.id}';
      await _ensureDirectory('$_quickRoot/$_quickMessages', task.id);
      String? checksum;
      await _retryOperation(
        () => _gateway!.uploadFile(
          source: source,
          targetDirectory: remotePackage,
          targetName: 'payload.bin',
          overwrite: true,
          resumeId: task.id,
          control: control,
          onChecksum: (value) => checksum = value,
          onProgress: (current, total) {
            task.transferredBytes = total == 0
                ? 0
                : (task.totalBytes * 98 ~/ 100) * current ~/ total;
            _notifyTransferProgress();
          },
        ),
      );
      final manifest = quickTransfer.describe(
        source,
        name: name,
        size: task.totalBytes,
        checksum: checksum ?? (throw StateError('Upload checksum is missing.')),
        senderDevice: deviceId,
        targetDevice: targetDevice,
        transferId: task.id,
      );
      final manifestFile = File(
        '${staging.path}${Platform.pathSeparator}${manifest.id}.json',
      );
      await manifestFile.writeAsString(
        jsonEncode(manifest.toJson()),
        flush: true,
      );
      await control.checkpoint();
      task.status = TransferStatus.finalizing;
      notifyListeners();
      await _retryOperation(
        () => _gateway!.uploadFile(
          source: manifestFile,
          targetDirectory: remotePackage,
          targetName: 'manifest.json',
          overwrite: true,
          control: control,
        ),
      );
      return manifest;
    } finally {
      if (staging != null && await staging.exists()) {
        await staging.delete(recursive: true);
      }
    }
  }

  Future<bool> receiveQuickTransfer(
    QuickTransferManifest manifest, {
    required File target,
    bool finalize = true,
    void Function(TransferTask task)? onTaskCreated,
    Future<void> Function(File file)? saveTarget,
    String? androidTargetUri,
    bool saveAsMedia = false,
    String mimeType = 'application/octet-stream',
  }) async {
    if (!_quickReceivingIds.add(manifest.id)) {
      throw StateError('该文件正在领取，请稍候。');
    }
    notifyListeners();
    try {
      return await _receiveQuickTransfer(
        manifest,
        target: target,
        finalize: finalize,
        onTaskCreated: onTaskCreated,
        saveTarget: saveTarget,
        androidTargetUri: androidTargetUri,
        saveAsMedia: saveAsMedia,
        mimeType: mimeType,
      );
    } finally {
      _quickReceivingIds.remove(manifest.id);
      notifyListeners();
    }
  }

  Future<bool> _receiveQuickTransfer(
    QuickTransferManifest manifest, {
    required File target,
    bool finalize = true,
    void Function(TransferTask task)? onTaskCreated,
    Future<void> Function(File file)? saveTarget,
    String? androidTargetUri,
    bool saveAsMedia = false,
    String mimeType = 'application/octet-stream',
  }) async {
    if (!canClaimQuickTransfer(manifest)) {
      throw StateError(
        'This transfer can only be claimed by its target device.',
      );
    }
    final task = TransferTask(
      id: uniqueSuffix(),
      name: manifest.name,
      direction: TransferDirection.quickReceive,
      totalBytes: manifest.size,
      status: TransferStatus.running,
    );
    tasks.insert(0, task);
    onTaskCreated?.call(task);
    final targetSaver =
        saveTarget ??
        (Platform.isAndroid
            ? (File file) => _saveAndroidQuickTarget(
                file,
                manifest: manifest,
                targetUri: androidTargetUri,
                saveAsMedia: saveAsMedia,
                mimeType: mimeType,
              )
            : null);
    _retryActions[task.id] = (retryTask) => _runQuickReceiveTask(
      retryTask,
      manifest: manifest,
      target: target,
      finalize: finalize,
      saveTarget: targetSaver,
    );
    _cleanupActions[task.id] = () async {
      final support = await getApplicationSupportDirectory();
      final staging = Directory(
        '${support.path}${Platform.pathSeparator}quick-transfer-receive${Platform.pathSeparator}${manifest.id}',
      );
      if (await staging.exists()) await staging.delete(recursive: true);
      _reservedQuickReceivePaths.remove(target.path.toLowerCase());
      if (!_quickLocallySaved.contains(task.id) && await target.exists()) {
        await target.delete();
      }
    };
    try {
      await _rememberPending({
        'kind': 'quickReceive',
        'id': task.id,
        'name': task.name,
        'totalBytes': task.totalBytes,
        'manifest': manifest.toJson(),
        'targetPath': target.path,
        'androidTargetUri': ?androidTargetUri,
        'saveAsMedia': saveAsMedia,
        'mimeType': mimeType,
        'locallySaved': false,
      });
    } catch (_) {
      _reservedQuickReceivePaths.remove(target.path.toLowerCase());
      tasks.remove(task);
      _retryActions.remove(task.id);
      _cleanupActions.remove(task.id);
      rethrow;
    }
    await _retryActions[task.id]!(task);
    if (task.status == TransferStatus.failed) {
      throw StateError(task.error ?? 'Quick transfer failed.');
    }
    return task.status == TransferStatus.completed;
  }

  Future<void> _saveAndroidQuickTarget(
    File file, {
    required QuickTransferManifest manifest,
    required String? targetUri,
    required bool saveAsMedia,
    required String mimeType,
  }) async {
    final saved = saveAsMedia
        ? await AndroidSaveFile.saveMedia(
            source: file,
            suggestedName: manifest.name,
            mimeType: mimeType,
          )
        : await AndroidSaveFile.saveToDocumentTarget(
            source: file,
            targetUri: targetUri!,
          );
    if (!saved) throw StateError('Final save failed.');
    if (await file.exists()) await file.delete();
  }

  Future<void> _runQuickReceiveTask(
    TransferTask task, {
    required QuickTransferManifest manifest,
    required File target,
    required bool finalize,
    Future<void> Function(File file)? saveTarget,
  }) async {
    final control = TransferControl();
    _transferControls[task.id] = control;
    _syncForegroundTransfer(force: true);
    task
      ..status = TransferStatus.running
      ..error = null
      ..cancelRequested = false
      ..isPaused = false;
    notifyListeners();
    Directory? staging;
    var completed = false;
    var remotePayloadMissing = false;
    try {
      if (!_quickLocallySaved.contains(task.id)) {
        var alreadyDownloaded =
            await target.exists() && await target.length() == manifest.size;
        if (alreadyDownloaded) {
          alreadyDownloaded =
              await quickTransfer.checksum(target) == manifest.sha256;
        }
        if (!alreadyDownloaded) {
          final support = await getApplicationSupportDirectory();
          staging = Directory(
            '${support.path}${Platform.pathSeparator}quick-transfer-receive${Platform.pathSeparator}${manifest.id}',
          );
          await staging.create(recursive: true);
          final payload = File(
            '${staging.path}${Platform.pathSeparator}${manifest.id}.bin',
          );
          String? downloadedChecksum;
          _cleanupActions[task.id] = () async {
            if (await staging!.exists()) await staging.delete(recursive: true);
            _reservedQuickReceivePaths.remove(target.path.toLowerCase());
            if (!_quickLocallySaved.contains(task.id) &&
                await target.exists()) {
              await target.delete();
            }
          };
          final remotePackage = '$_quickRoot/$_quickMessages/${manifest.id}';
          try {
            await _retryOperation(
              () => _gateway!.downloadFile(
                remotePath: '$remotePackage/payload.bin',
                target: payload,
                resumeId: manifest.id,
                onChecksum: (value) => downloadedChecksum = value,
                control: control,
                onProgress: (current, _) {
                  task.transferredBytes = current;
                  _notifyTransferProgress();
                },
              ),
            );
          } catch (exception) {
            remotePayloadMissing = _isMissingFileError(exception);
            rethrow;
          }
          await control.checkpoint();
          task.status = TransferStatus.finalizing;
          notifyListeners();
          await quickTransfer.verifyAndPublish(
            manifest,
            payload,
            target,
            verifiedChecksum: downloadedChecksum,
            verifiedSize: downloadedChecksum == null ? null : manifest.size,
            onProgress: (current, _) {
              task.transferredBytes = current;
              _notifyTransferProgress();
            },
          );
        }
        task.status = TransferStatus.finalizing;
        notifyListeners();
        if (saveTarget != null) await saveTarget(target);
        _quickLocallySaved.add(task.id);
        _reservedQuickReceivePaths.remove(target.path.toLowerCase());
        final record = _pendingTransferRecords[task.id];
        if (record != null) {
          record['locallySaved'] = true;
          await _persistPendingTransfers();
        }
      }
      if (finalize) await markQuickTransferClaimed(manifest);
      _quickLocallySaved.remove(task.id);
      task.transferredBytes = task.totalBytes;
      task.status = TransferStatus.completed;
      completed = true;
      _cleanupActions.remove(task.id);
      await _forgetPending(task.id);
    } catch (exception) {
      if (remotePayloadMissing && !task.cancelRequested) {
        final messagePath = '$_quickRoot/$_quickMessages/${manifest.id}';
        final inspection = await _inspectMissingQuickPayload(messagePath);
        if (inspection.state == _QuickPayloadState.removed) {
          // The package can remain visible briefly after another participant
          // removed it. This is a terminal stale record, not a failed
          // transfer. Converge this device's list and task state immediately;
          // do not turn the expected race into a red error.
          _hideQuickTransfer(manifest.id);
          task
            ..status = TransferStatus.cancelled
            ..cancelRequested = true
            ..error = null;
          _reservedQuickReceivePaths.remove(target.path.toLowerCase());
          _cleanupActions.remove(task.id);
          _retryActions.remove(task.id);
          await _forgetPending(task.id);
          return;
        }
        if (inspection.state == _QuickPayloadState.claimed &&
            inspection.claimedManifest != null) {
          // A claimed receipt is durable history. Keep the row visible and
          // replace its stale unclaimed snapshot so the UI shows who claimed
          // it, without reporting a successful save on this device.
          _replaceQuickInboxItem(inspection.claimedManifest!);
          task
            ..status = TransferStatus.cancelled
            ..cancelRequested = true
            ..error = null;
          _reservedQuickReceivePaths.remove(target.path.toLowerCase());
          _cleanupActions.remove(task.id);
          _retryActions.remove(task.id);
          await _forgetPending(task.id);
          return;
        }
      }
      if (!task.cancelRequested) {
        task.status = TransferStatus.failed;
        task.error = _quickLocallySaved.contains(task.id)
            ? '文件已经保存，领取状态尚未同步，可点击重试。'
            : describeError(exception);
      }
      rethrow;
    } finally {
      _transferControls.remove(task.id);
      _syncForegroundTransfer(force: true);
      if ((completed || task.cancelRequested) &&
          staging != null &&
          await staging.exists()) {
        await staging.delete(recursive: true);
      }
      if (task.status == TransferStatus.completed) {
        await refreshQuickTransfer();
      }
      notifyListeners();
    }
  }

  Future<void> markQuickTransferClaimed(QuickTransferManifest manifest) async {
    if (manifest.isClaimed) return;
    final claimed = manifest.copyWith(
      claimedAt: DateTime.now().toUtc(),
      claimedBy: deviceId,
    );
    final source = await _writeQuickJson(
      'quick-claimed-${manifest.id}.json',
      claimed.toJson(),
    );
    try {
      final messagePath = '$_quickRoot/$_quickMessages/${manifest.id}';
      await _retryOperation(
        () => _gateway!.uploadFile(
          source: source,
          targetDirectory: messagePath,
          targetName: 'receipt.json',
          overwrite: true,
        ),
      );
      quickInbox = quickInbox
          .map((item) => item.id == manifest.id ? claimed : item)
          .toList(growable: false);
      notifyListeners();
      try {
        await _retryOperation(
          () => _gateway!.deleteEntry(
            '$messagePath/payload.bin',
            recursive: false,
          ),
        );
      } catch (_) {
        // The receipt is already durable. Cleanup can be retried later.
      }
    } finally {
      if (await source.exists()) await source.delete();
    }
  }

  Future<void> deleteQuickTransfer(QuickTransferManifest manifest) {
    if (manifest.senderDevice != deviceId &&
        manifest.targetDevice != deviceId) {
      return Future<void>.error(
        StateError('This device is not a participant in the transfer.'),
      );
    }

    // Remove the row synchronously after confirmation. Dismissible cannot
    // finish its animation while the UI waits for a slow SFTP delete. Keep a
    // snapshot of only this item so a failed remote operation can restore it
    // without resurrecting other rows that may have been deleted meanwhile.
    final previous = quickInbox.where((item) => item.id == manifest.id);
    final previousItem = previous.firstOrNull;
    if (previousItem != null) {
      _hiddenQuickTransferIds.add(manifest.id);
      _quickRefreshGeneration++;
      quickInbox = quickInbox
          .where((item) => item.id != manifest.id)
          .toList(growable: false);
      notifyListeners();
    }
    final result = _quickMutationTail.then(
      (_) => _deleteQuickTransferNow(manifest, previousItem: previousItem),
    );
    _quickMutationTail = result.then<void>((_) {}, onError: (_, _) {});
    return result;
  }

  Future<void> _deleteQuickTransferNow(
    QuickTransferManifest manifest, {
    QuickTransferManifest? previousItem,
  }) async {
    if (manifest.senderDevice != deviceId &&
        manifest.targetDevice != deviceId) {
      throw StateError('This device is not a participant in the transfer.');
    }
    _quickMutationInProgress = true;
    var deleted = false;
    try {
      final refreshIdle = _quickRefreshIdle;
      if (_isRefreshingQuickTransfer && refreshIdle != null) {
        _quickRefreshGeneration++;
        await refreshIdle.future;
      }
      final messagePath = '$_quickRoot/$_quickMessages/${manifest.id}';
      try {
        try {
          await _retryOperation(
            () => _gateway!.deleteEntry(messagePath, recursive: true),
          );
        } catch (exception, stackTrace) {
          var stillExists = true;
          try {
            final packages = await _retryOperation(
              () => _gateway!.listDirectory('$_quickRoot/$_quickMessages'),
            );
            stillExists = packages.any(
              (entry) => entry.isDirectory && entry.name == manifest.id,
            );
          } catch (_) {
            Error.throwWithStackTrace(exception, stackTrace);
          }
          if (stillExists) Error.throwWithStackTrace(exception, stackTrace);
        }
        _quickManifestCache.remove('$messagePath/manifest.json');
      } catch (_) {
        _hiddenQuickTransferIds.remove(manifest.id);
        if (previousItem != null &&
            !quickInbox.any((item) => item.id == previousItem.id)) {
          final restored = [...quickInbox, previousItem]
            ..sort((left, right) => right.createdAt.compareTo(left.createdAt));
          quickInbox = restored;
          notifyListeners();
        }
        rethrow;
      }
      _hiddenQuickTransferIds.remove(manifest.id);
      deleted = true;
      quickError = null;
      notifyListeners();
    } finally {
      _quickMutationInProgress = false;
      if (deleted && isReady && !hasRunningTransfers) {
        await refreshQuickTransfer();
      } else if (_quickRefreshPending && !hasRunningTransfers) {
        unawaited(refreshQuickTransfer());
      }
    }
  }

  Future<void> _resetConnection() async {
    if (mode == RepositoryMode.sftp) await _gateway?.dispose();
  }

  Future<T> _retryOperation<T>(Future<T> Function() operation) async {
    try {
      final result = await ConnectionRetry(
        resetConnection: _resetConnection,
        beforeRetry: (_) {
          if (_quickInitializationActive || _isRefreshingQuickTransfer) return;
          connectionStatus = RepositoryConnectionStatus.retrying;
          notifyListeners();
        },
      ).run(operation);
      if (isReady) connectionStatus = RepositoryConnectionStatus.connected;
      return result;
    } catch (exception) {
      if (!isReady &&
          (_isTailscaleConnectivityError(exception) ||
              exception is SocketException ||
              exception is TimeoutException)) {
        connectionStatus = RepositoryConnectionStatus.disconnected;
        notifyListeners();
      }
      rethrow;
    }
  }

  Future<void> toggleTheme() async {
    isDarkTheme = !isDarkTheme;
    await _preferences.setBool('dark_theme', isDarkTheme);
    notifyListeners();
  }

  Future<void> setSort(FileSortField field, {bool? ascending}) async {
    sortField = field;
    if (ascending != null) sortAscending = ascending;
    await _preferences.setString(_sortFieldKey, sortField.name);
    await _preferences.setBool(_sortAscendingKey, sortAscending);
    notifyListeners();
  }

  Future<int> validateTransferSelection(List<File> files) async {
    if (files.isEmpty) return 0;
    if (files.length > maxTransferFiles) {
      throw StateError(
        'A transfer can contain at most $maxTransferFiles files.',
      );
    }
    var total = 0;
    for (final file in files) {
      if (!await file.exists()) {
        throw FileSystemException('Selected file is unavailable.', file.path);
      }
      total += await file.length();
      if (total > maxTransferBytes) {
        throw StateError('A transfer cannot exceed 10 GB.');
      }
    }
    return total;
  }

  Future<void> _ensureRemoteSpace(int requiredBytes, String path) async {
    final available = await _retryOperation(
      () => _gateway!.availableBytes(path),
    );
    const reserve = 16 * 1024 * 1024;
    if (available != null && available < requiredBytes + reserve) {
      throw StateError('The destination does not have enough free space.');
    }
  }

  Future<void> _recoverTemporaryFiles(String path) async {
    try {
      await _gateway?.recoverTemporaryFiles(path);
    } catch (_) {
      // Recovery is maintenance and must not make a healthy folder unusable.
    }
  }

  void _syncForegroundTransfer({bool force = false}) {
    if (hasRunningTransfers && _isRefreshingQuickTransfer) {
      _quickRefreshGeneration++;
      _quickRefreshPending = true;
    }
    if (!hasRunningTransfers) {
      if (_repositoryRefreshPending) unawaited(refresh());
      if (_quickRefreshPending) unawaited(refreshQuickTransfer());
    }
    if (Platform.isWindows) {
      unawaited(WindowsLifecycleBridge.setActiveTransfers(hasActiveTransfers));
    }
    if (!Platform.isAndroid) return;
    final now = DateTime.now();
    if (!force &&
        _lastForegroundUpdate != null &&
        now.difference(_lastForegroundUpdate!) <
            const Duration(milliseconds: 500)) {
      return;
    }
    _lastForegroundUpdate = now;
    final active = tasks
        .where((task) => _transferControls.containsKey(task.id))
        .toList(growable: false);
    if (active.isEmpty) {
      if (_foregroundTransferActive) {
        _foregroundTransferActive = false;
        unawaited(AndroidTransferService.stop());
      }
      return;
    }
    final total = active.fold<int>(0, (sum, task) => sum + task.totalBytes);
    final current = active.fold<int>(
      0,
      (sum, task) => sum + task.transferredBytes.clamp(0, task.totalBytes),
    );
    final progress = total <= 0 ? 0 : (current * 1000 ~/ total).clamp(0, 1000);
    if (_foregroundTransferActive) {
      unawaited(
        AndroidTransferService.update(
          current: progress,
          total: 1000,
          tasks: active.length,
        ),
      );
    } else {
      _foregroundTransferActive = true;
      unawaited(
        AndroidTransferService.start(
          current: progress,
          total: 1000,
          tasks: active.length,
        ),
      );
    }
  }

  void _notifyTransferProgress() {
    _syncForegroundTransfer();
    final now = DateTime.now();
    final elapsed = _lastTransferUiUpdate == null
        ? const Duration(seconds: 1)
        : now.difference(_lastTransferUiUpdate!);
    if (elapsed >= const Duration(milliseconds: 100)) {
      _lastTransferUiUpdate = now;
      _transferUiTimer?.cancel();
      _transferUiTimer = null;
      notifyListeners();
      return;
    }
    _transferUiTimer ??= Timer(const Duration(milliseconds: 100) - elapsed, () {
      _transferUiTimer = null;
      _lastTransferUiUpdate = DateTime.now();
      notifyListeners();
    });
  }

  @override
  void notifyListeners() {
    if (!_disposed) super.notifyListeners();
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _quickSessionGeneration++;
    _quickRefreshGeneration++;
    _quickMaintenanceTimer?.cancel();
    _transferUiTimer?.cancel();
    unawaited(_stopPhotoTransferServer());
    unawaited(_photoTransferClient.dispose());
    _gateway?.dispose();
    super.dispose();
  }
}

class _QueuedQuickTransfer {
  _QueuedQuickTransfer({
    required this.source,
    required this.targetDevice,
    required this.task,
    required this.name,
  });

  final File source;
  final String targetDevice;
  final TransferTask task;
  final String name;
  final Completer<QuickTransferManifest> completer =
      Completer<QuickTransferManifest>();
}

class _DurableSource {
  const _DurableSource(this.file, {required this.owned});

  final File file;
  final bool owned;

  Future<void> deleteIfOwned() async {
    if (owned && await file.exists()) await file.delete();
  }
}

typedef _QuickPayloadInspection = ({
  _QuickPayloadState state,
  QuickTransferManifest? claimedManifest,
});

enum _QuickPayloadState { missing, removed, claimed, unknown }
