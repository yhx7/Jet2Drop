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
import 'core/path_utils.dart';
import 'core/repository_gateway.dart';
import 'core/transfer_control.dart';
import 'infrastructure/local_repository_gateway.dart';
import 'infrastructure/serialized_repository_gateway.dart';
import 'infrastructure/sftp_repository_gateway.dart';
import 'core/quick_transfer.dart';

enum RepositoryMode { local, sftp }

class AppController extends ChangeNotifier {
  static const _modeKey = 'repository_mode';
  static const _rootKey = 'local_root';
  static const _hostKey = 'sftp_host';
  static const _portKey = 'sftp_port';
  static const _usernameKey = 'sftp_username';
  static const _fingerprintKey = 'sftp_fingerprint';
  static const _passwordKey = 'sftp_password';
  static const _deviceIdKey = 'quick_device_id';
  static const _deviceNameKey = 'quick_device_name';
  static const _quickRoot = '__jet2drop_transfer';
  static const _quickMessages = 'messages';

  final FlutterSecureStorage _secureStorage = const FlutterSecureStorage();
  late SharedPreferences _preferences;
  RepositoryGateway? _gateway;

  bool isReady = false;
  bool isInitializing = true;
  bool isLoading = false;
  bool _isRefreshingRepository = false;
  bool isDarkTheme = false;
  bool needsTailscale = false;
  String? quickError;
  String currentPath = '';
  String? error;
  List<FileEntry> entries = const [];
  final List<TransferTask> tasks = [];
  final Map<String, TransferControl> _transferControls = {};
  final QuickTransferService quickTransfer = QuickTransferService();
  int _quickRefreshGeneration = 0;
  bool _isRefreshingQuickTransfer = false;
  Timer? _quickMaintenanceTimer;
  DateTime? _lastQuickDeviceRefresh;
  String deviceId = '';
  String deviceName = '';
  List<QuickDevice> quickDevices = const [];
  List<QuickTransferManifest> quickInbox = const [];

  List<QuickDevice> get quickRecipients => quickDevices
      .where((device) => device.id != deviceId)
      .toList(growable: false);

  bool canClaimQuickTransfer(QuickTransferManifest manifest) =>
      !manifest.isClaimed && manifest.targetDevice == deviceId;

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
      localRoot = _preferences.getString(_rootKey) ?? r'E:\Repository';
      mode = RepositoryMode.values.byName(
        _preferences.getString(_modeKey) ??
            (Platform.isWindows
                ? RepositoryMode.local.name
                : RepositoryMode.sftp.name),
      );
      await _loadSftpProfile();
      await connect();
    } catch (exception) {
      error = describeError(exception);
      isReady = false;
    } finally {
      isInitializing = false;
      notifyListeners();
    }
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
    localRoot = path;
    mode = RepositoryMode.local;
    await _preferences.setString(_rootKey, path);
    await _preferences.setString(_modeKey, mode.name);
    await connect();
  }

  Future<void> configureSftp(SftpConnectionProfile profile) async {
    sftpProfile = profile;
    mode = RepositoryMode.sftp;
    await _preferences.setString(_hostKey, profile.host);
    await _preferences.setInt(_portKey, profile.port);
    await _preferences.setString(_usernameKey, profile.username);
    await _preferences.setString(_fingerprintKey, profile.hostKeyFingerprint);
    await _preferences.setString(_modeKey, mode.name);
    await _secureStorage.write(key: _passwordKey, value: profile.password);
    await connect();
  }

  Future<void> connect() async {
    isLoading = true;
    error = null;
    notifyListeners();
    try {
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
      await _gateway!.initialize().timeout(const Duration(seconds: 15));
      currentPath = '';
      await refresh();
      isReady = true;
      needsTailscale = false;
      unawaited(_initializeQuickTransferSafely());
    } catch (exception) {
      error = describeError(exception);
      needsTailscale = _isTailscaleConnectivityError(exception);
      entries = const [];
      isReady = false;
    } finally {
      isLoading = false;
      notifyListeners();
    }
  }

  Future<void> _initializeQuickTransferSafely() async {
    try {
      await _initializeQuickTransfer();
      quickError = null;
      _quickMaintenanceTimer ??= Timer.periodic(
        const Duration(minutes: 15),
        (_) => unawaited(refreshQuickTransfer(refreshDevices: true)),
      );
    } catch (exception) {
      quickError = describeError(exception);
      notifyListeners();
    }
  }

  Future<void> refresh() async {
    final gateway = _gateway;
    if (gateway == null || _isRefreshingRepository) return;
    if (_transferControls.isNotEmpty) return;
    _isRefreshingRepository = true;
    isLoading = true;
    notifyListeners();
    try {
      entries = await _retryOperation(() => gateway.listDirectory(currentPath));
      error = null;
    } catch (exception) {
      error = describeError(exception);
      needsTailscale = _isTailscaleConnectivityError(exception);
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
      return '服务器拒绝连接。请确认 Windows 已开机，Jet2Drop SFTP 服务正在运行且端口 2022 未被防火墙阻止。';
    }
    if (normalized.contains('connection timed out') ||
        normalized.contains('sftp connection timed out') ||
        normalized.contains('sftp handshake timed out')) {
      return '连接服务器超时。请确认 Windows 未休眠、两台设备均已连接 Tailscale，然后重试。';
    }
    if (normalized.contains('timed out')) {
      return '传输在等待服务器响应时超时。请确认 Windows 未休眠、Tailscale 连接正常后重试；未完成的临时文件已自动清理。';
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
    if (exception is SocketException) {
      return '网络连接失败，请检查网络和 Tailscale 连接状态。';
    }
    return '操作失败。请稍后重试；若持续发生，请检查连接设置和网络状态。';
  }

  Future<void> _initializeQuickTransfer() async {
    await _loadQuickIdentity();
    await _ensureQuickDirectories();
    await _publishDeviceRegistration();
    await refreshQuickTransfer();
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
    await refreshQuickTransfer();
  }

  Future<void> _ensureQuickDirectories() async {
    final gateway = _gateway;
    if (gateway == null) throw StateError('Repository is not connected.');
    await _ensureDirectory('', _quickRoot);
    await _ensureDirectory(_quickRoot, 'devices');
    await _ensureDirectory(_quickRoot, _quickMessages);
  }

  Future<void> _ensureDirectory(String parent, String name) async {
    try {
      await _gateway!.createDirectory(parent, name);
    } catch (_) {
      // The directory normally already exists; the next read validates it.
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
    final registration = QuickDevice(
      id: deviceId,
      name: deviceName,
      updatedAt: DateTime.now(),
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
    if (gateway == null ||
        deviceId.isEmpty ||
        _isRefreshingQuickTransfer ||
        _transferControls.isNotEmpty) {
      return;
    }
    _isRefreshingQuickTransfer = true;
    final generation = ++_quickRefreshGeneration;
    try {
      var registered = quickDevices;
      final shouldRefreshDevices =
          refreshDevices ||
          _lastQuickDeviceRefresh == null ||
          DateTime.now().difference(_lastQuickDeviceRefresh!) >=
              const Duration(minutes: 1);
      if (shouldRefreshDevices) {
        final discovered = <QuickDevice>[];
        try {
          for (final entry in await gateway.listDirectory(
            '$_quickRoot/devices',
          )) {
            if (entry.isDirectory || !entry.name.endsWith('.json')) continue;
            try {
              discovered.add(
                QuickDevice.fromJson(
                  jsonDecode(await _readQuickText(entry.path))
                      as Map<String, dynamic>,
                ),
              );
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
            final content = await _readQuickText(
              manifestPath,
            ).timeout(const Duration(seconds: 10));
            var value = QuickTransferManifest.fromJson(
              jsonDecode(content) as Map<String, dynamic>,
            );
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
            } catch (_) {
              // A receipt is optional until the target device saves the file.
            }
            if (value.expiresAt.isBefore(DateTime.now().toUtc())) {
              await gateway.deleteEntry(
                manifestPath.substring(
                  0,
                  manifestPath.length - '/manifest.json'.length,
                ),
                recursive: true,
              );
            } else if (value.senderDevice == deviceId ||
                value.targetDevice == deviceId) {
              inbox.add(value);
            }
          } catch (_) {
            // An incomplete package is not published until its manifest exists.
          }
        }
      } catch (_) {
        // The message folder is created on demand by any connected device.
        await _resetConnection();
      }
      inbox.sort((left, right) => right.createdAt.compareTo(left.createdAt));
      if (generation != _quickRefreshGeneration) return;
      quickDevices = registered;
      quickInbox = inbox;
      notifyListeners();
    } catch (exception) {
      quickError = describeError(exception);
      notifyListeners();
    } finally {
      _isRefreshingQuickTransfer = false;
    }
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
    await _runSimple(
      () => _retryOperation(() => _gateway!.createDirectory(currentPath, name)),
    );
    await refresh();
  }

  Future<void> deleteEntry(FileEntry entry) async {
    await _runSimple(
      () => _retryOperation(
        () => _gateway!.deleteEntry(entry.path, recursive: entry.isDirectory),
      ),
    );
    await refresh();
  }

  Future<void> uploadFiles(
    List<File> files, {
    required bool overwrite,
    bool keepBoth = false,
  }) async {
    for (final file in files) {
      final sourceName = file.uri.pathSegments.last;
      final targetName = keepBoth ? _availableName(sourceName) : sourceName;
      final task = TransferTask(
        id: uniqueSuffix(),
        name: targetName,
        direction: TransferDirection.upload,
        totalBytes: await file.length(),
        status: TransferStatus.running,
      );
      tasks.insert(0, task);
      final control = TransferControl();
      _transferControls[task.id] = control;
      notifyListeners();
      try {
        await _retryOperation(
          () => _gateway!.uploadFile(
            source: file,
            targetDirectory: currentPath,
            targetName: task.name,
            overwrite: overwrite,
            onProgress: (current, _) {
              task.transferredBytes = current;
              notifyListeners();
            },
            control: control,
          ),
        );
        task.status = TransferStatus.completed;
      } catch (exception) {
        if (!task.cancelRequested) {
          task.status = TransferStatus.failed;
          task.error = describeError(exception);
        }
      }
      _transferControls.remove(task.id);
      notifyListeners();
      if (task.cancelRequested) break;
    }
    await refresh();
  }

  String _availableName(String name) {
    final names = entries.map((entry) => entry.name.toLowerCase()).toSet();
    if (!names.contains(name.toLowerCase())) return name;
    final dot = name.lastIndexOf('.');
    final stem = dot > 0 ? name.substring(0, dot) : name;
    final extension = dot > 0 ? name.substring(dot) : '';
    for (var index = 2; ; index++) {
      final candidate = '$stem ($index)$extension';
      if (!names.contains(candidate.toLowerCase())) return candidate;
    }
  }

  Future<void> downloadFile(FileEntry entry, File target) async {
    final task = TransferTask(
      id: uniqueSuffix(),
      name: entry.name,
      direction: TransferDirection.download,
      totalBytes: entry.size,
      status: TransferStatus.running,
    );
    tasks.insert(0, task);
    final control = TransferControl();
    _transferControls[task.id] = control;
    notifyListeners();
    try {
      await _retryOperation(
        () => _gateway!.downloadFile(
          remotePath: entry.path,
          target: target,
          onProgress: (current, _) {
            task.transferredBytes = current;
            notifyListeners();
          },
          control: control,
        ),
      );
      task.status = TransferStatus.completed;
    } catch (exception) {
      if (!task.cancelRequested) {
        task.status = TransferStatus.failed;
        task.error = describeError(exception);
      }
    }
    _transferControls.remove(task.id);
    notifyListeners();
  }

  void pauseTask(TransferTask task) {
    if (task.status != TransferStatus.running || task.isPaused) return;
    _transferControls[task.id]?.pause();
    task.isPaused = true;
    notifyListeners();
  }

  void resumeTask(TransferTask task) {
    if (task.status != TransferStatus.running || !task.isPaused) return;
    _transferControls[task.id]?.resume();
    task.isPaused = false;
    notifyListeners();
  }

  Future<void> cancelTask(TransferTask task) async {
    if (task.status != TransferStatus.running) return;
    task.cancelRequested = true;
    task.status = TransferStatus.cancelled;
    task.isPaused = false;
    task.error = null;
    notifyListeners();
    await _transferControls[task.id]?.cancel();
  }

  void removeTask(TransferTask task) {
    if (task.status == TransferStatus.running) return;
    tasks.remove(task);
    notifyListeners();
  }

  Future<File> previewFile(FileEntry entry) =>
      _retryOperation(() => _gateway!.materializeForPreview(entry.path));

  Future<void> releasePreview(File file) async {
    if (mode == RepositoryMode.sftp && await file.exists()) {
      await file.delete();
    }
  }

  Future<QuickTransferManifest> publishQuickTransfer(
    File source, {
    required String targetDevice,
  }) async {
    final target = targetDevice.trim();
    if (target.isEmpty || target == deviceId) {
      throw ArgumentError('Cannot send a quick transfer to this device.');
    }
    if (!quickRecipients.any((item) => item.id == target)) {
      throw ArgumentError(
        'The target device is unavailable or belongs to this device.',
      );
    }
    final task = TransferTask(
      id: uniqueSuffix(),
      name: source.uri.pathSegments.last,
      direction: TransferDirection.quickDrop,
      totalBytes: await source.length(),
      status: TransferStatus.running,
    );
    tasks.insert(0, task);
    final control = TransferControl();
    _transferControls[task.id] = control;
    notifyListeners();
    Directory? staging;
    try {
      await _resetConnection();
      final support = await getApplicationSupportDirectory();
      staging = Directory(
        '${support.path}${Platform.pathSeparator}quick-transfer-staging${Platform.pathSeparator}${uniqueSuffix()}',
      );
      final manifest = await quickTransfer.publish(
        source,
        staging,
        senderDevice: deviceId,
        targetDevice: target,
        onProgress: (current, total) {
          // Local staging is preparation, not network transfer. Keep it in a
          // small initial range so the visible progress reflects upload work.
          task.transferredBytes = total == 0
              ? 0
              : (task.totalBytes * current ~/ total ~/ 20);
          notifyListeners();
        },
      );
      final remotePackage = '$_quickRoot/$_quickMessages/${manifest.id}';
      await _ensureDirectory('$_quickRoot/$_quickMessages', manifest.id);
      final payload = File(
        '${staging.path}${Platform.pathSeparator}${manifest.id}.bin',
      );
      final manifestFile = File(
        '${staging.path}${Platform.pathSeparator}${manifest.id}.json',
      );
      await _retryOperation(
        () => _gateway!.uploadFile(
          source: payload,
          targetDirectory: remotePackage,
          targetName: 'payload.bin',
          overwrite: true,
          control: control,
          onProgress: (current, total) {
            task.transferredBytes = total == 0
                ? task.totalBytes ~/ 20
                : task.totalBytes ~/ 20 +
                      ((task.totalBytes * 19 ~/ 20) * current ~/ total);
            notifyListeners();
          },
        ),
      );
      await control.checkpoint();
      await _retryOperation(
        () => _gateway!.uploadFile(
          source: manifestFile,
          targetDirectory: remotePackage,
          targetName: 'manifest.json',
          overwrite: true,
          control: control,
        ),
      );
      task.transferredBytes = task.totalBytes;
      task.status = TransferStatus.completed;
      notifyListeners();
      return manifest;
    } catch (exception) {
      if (!task.cancelRequested) {
        task.status = TransferStatus.failed;
        task.error = describeError(exception);
      }
      notifyListeners();
      rethrow;
    } finally {
      _transferControls.remove(task.id);
      if (staging != null && await staging.exists()) {
        await staging.delete(recursive: true);
      }
      if (task.status == TransferStatus.completed) {
        await refreshQuickTransfer();
      }
    }
  }

  Future<void> receiveQuickTransfer(
    QuickTransferManifest manifest, {
    required File target,
    bool finalize = true,
  }) async {
    if (!canClaimQuickTransfer(manifest)) {
      throw StateError(
        'This transfer can only be claimed by its target device.',
      );
    }
    final task = TransferTask(
      id: uniqueSuffix(),
      name: manifest.name,
      direction: TransferDirection.quickDrop,
      totalBytes: manifest.size,
      status: TransferStatus.running,
    );
    tasks.insert(0, task);
    final control = TransferControl();
    _transferControls[task.id] = control;
    Directory? staging;
    try {
      await _resetConnection();
      final support = await getApplicationSupportDirectory();
      staging = Directory(
        '${support.path}${Platform.pathSeparator}quick-transfer-receive${Platform.pathSeparator}${manifest.id}',
      );
      await staging.create(recursive: true);
      final payload = File(
        '${staging.path}${Platform.pathSeparator}${manifest.id}.bin',
      );
      final remotePackage = '$_quickRoot/$_quickMessages/${manifest.id}';
      await _retryOperation(
        () => _gateway!.downloadFile(
          remotePath: '$remotePackage/payload.bin',
          target: payload,
          control: control,
          onProgress: (current, _) {
            task.transferredBytes = current;
            notifyListeners();
          },
        ),
      );
      await control.checkpoint();
      await quickTransfer.receive(manifest, staging, target);
      if (finalize) await markQuickTransferClaimed(manifest);
      task.transferredBytes = task.totalBytes;
      task.status = TransferStatus.completed;
    } catch (exception) {
      if (!task.cancelRequested) {
        task.status = TransferStatus.failed;
        task.error = describeError(exception);
      }
      rethrow;
    } finally {
      _transferControls.remove(task.id);
      if (staging != null && await staging.exists()) {
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
      await _resetConnection();
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
    await refreshQuickTransfer();
  }

  Future<void> deleteQuickTransfer(QuickTransferManifest manifest) async {
    if (manifest.senderDevice != deviceId &&
        manifest.targetDevice != deviceId) {
      throw StateError('This device is not a participant in the transfer.');
    }
    final previous = quickInbox;
    quickInbox = previous
        .where((item) => item.id != manifest.id)
        .toList(growable: false);
    notifyListeners();
    try {
      await _resetConnection();
      await _retryOperation(
        () => _gateway!.deleteEntry(
          '$_quickRoot/$_quickMessages/${manifest.id}',
          recursive: true,
        ),
      );
      await refreshQuickTransfer();
    } catch (_) {
      quickInbox = previous;
      notifyListeners();
      rethrow;
    }
  }

  Future<void> _resetConnection() async {
    if (mode == RepositoryMode.sftp) await _gateway?.dispose();
  }

  Future<T> _retryOperation<T>(Future<T> Function() operation) async {
    Object? lastException;
    StackTrace? lastStackTrace;
    for (var attempt = 0; attempt < 3; attempt++) {
      try {
        if (attempt > 0) await _resetConnection();
        return await operation();
      } catch (exception, stackTrace) {
        if (exception is TransferCancelled) {
          Error.throwWithStackTrace(exception, stackTrace);
        }
        lastException = exception;
        lastStackTrace = stackTrace;
        if (attempt < 2) {
          await Future<void>.delayed(
            Duration(milliseconds: 400 * (attempt + 1)),
          );
        }
      }
    }
    Error.throwWithStackTrace(lastException!, lastStackTrace!);
  }

  Future<void> toggleTheme() async {
    isDarkTheme = !isDarkTheme;
    await _preferences.setBool('dark_theme', isDarkTheme);
    notifyListeners();
  }

  Future<void> _runSimple(Future<void> Function() action) async {
    try {
      await action();
      error = null;
    } catch (exception) {
      error = describeError(exception);
    }
  }

  @override
  void dispose() {
    _quickMaintenanceTimer?.cancel();
    _gateway?.dispose();
    super.dispose();
  }
}
