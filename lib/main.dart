import 'dart:async';
import 'dart:io';

import 'package:desktop_drop/desktop_drop.dart';
import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path_provider/path_provider.dart';

import 'app_controller.dart';
import 'core/models/file_entry.dart';
import 'core/models/transfer_task.dart';
import 'core/quick_transfer.dart';
import 'infrastructure/sftp_repository_gateway.dart';
import 'platform/android_media_picker.dart';
import 'platform/android_save_file.dart';
import 'platform/tailscale_bridge.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final controller = AppController();
  runApp(Jet2DropApp(controller: controller));
  unawaited(controller.initialize());
}

class Jet2DropApp extends StatelessWidget {
  const Jet2DropApp({super.key, required this.controller});

  final AppController controller;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: controller,
      builder: (context, _) => MaterialApp(
        title: 'Jet2Drop',
        debugShowCheckedModeBanner: false,
        themeMode: controller.isDarkTheme ? ThemeMode.dark : ThemeMode.light,
        theme: _theme(Brightness.light),
        darkTheme: _theme(Brightness.dark),
        home: RepositoryPage(controller: controller),
      ),
    );
  }

  ThemeData _theme(Brightness brightness) {
    final scheme = ColorScheme.fromSeed(
      seedColor: const Color(0xff0678d7),
      brightness: brightness,
    );
    return ThemeData(
      colorScheme: scheme,
      useMaterial3: true,
      scaffoldBackgroundColor: brightness == Brightness.dark
          ? const Color(0xff10151b)
          : const Color(0xfff5f7fa),
      appBarTheme: AppBarTheme(
        backgroundColor: brightness == Brightness.dark
            ? const Color(0xff151c24)
            : Colors.white,
        foregroundColor: scheme.onSurface,
        elevation: 0,
        surfaceTintColor: Colors.transparent,
      ),
      cardTheme: CardThemeData(
        elevation: 0,
        margin: EdgeInsets.zero,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(8),
          side: BorderSide(color: scheme.outlineVariant),
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: scheme.surface,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: BorderSide(color: scheme.outlineVariant),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: BorderSide(color: scheme.outlineVariant),
        ),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          minimumSize: const Size(0, 44),
          padding: const EdgeInsets.symmetric(horizontal: 16),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          minimumSize: const Size(0, 44),
          padding: const EdgeInsets.symmetric(horizontal: 16),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
        ),
      ),
      navigationBarTheme: NavigationBarThemeData(
        height: 72,
        indicatorShape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(8),
        ),
      ),
    );
  }
}

class RepositoryPage extends StatefulWidget {
  const RepositoryPage({super.key, required this.controller});

  final AppController controller;

  @override
  State<RepositoryPage> createState() => _RepositoryPageState();
}

class _RepositoryPageState extends State<RepositoryPage>
    with WidgetsBindingObserver {
  bool _dragging = false;
  int _page = 0;
  bool _awaitingTailscale = false;
  Timer? _quickRefreshTimer;
  final Set<String> _materializedUploadPaths = <String>{};

  AppController get controller => widget.controller;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _quickRefreshTimer = Timer.periodic(const Duration(seconds: 3), (_) {
      if (mounted && _page == 1 && controller.isReady) {
        unawaited(controller.refreshQuickTransfer());
      }
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _quickRefreshTimer?.cancel();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && _awaitingTailscale) {
      _awaitingTailscale = false;
      unawaited(controller.connect());
    }
  }

  @override
  Widget build(BuildContext context) {
    final wide = MediaQuery.sizeOf(context).width >= 840;
    final content = switch (_page) {
      0 => _repositoryView(),
      1 => _quickTransferView(),
      _ => _taskView(),
    };
    return Scaffold(
      appBar: AppBar(
        title: const Text('Jet2Drop'),
        actions: [
          IconButton(
            tooltip: '切换主题',
            onPressed: controller.toggleTheme,
            icon: Icon(
              controller.isDarkTheme
                  ? Icons.light_mode_outlined
                  : Icons.dark_mode_outlined,
            ),
          ),
          IconButton(
            tooltip: '连接设置',
            onPressed: _showConnectionDialog,
            icon: const Icon(Icons.settings_outlined),
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: wide
          ? Row(
              children: [
                _navigationRail(),
                const VerticalDivider(width: 1),
                Expanded(child: content),
              ],
            )
          : content,
      bottomNavigationBar: wide
          ? null
          : NavigationBar(
              selectedIndex: _page,
              onDestinationSelected: _selectPage,
              destinations: const [
                NavigationDestination(
                  icon: Icon(Icons.folder_outlined),
                  selectedIcon: Icon(Icons.folder),
                  label: '仓库',
                ),
                NavigationDestination(
                  icon: Icon(Icons.bolt_outlined),
                  selectedIcon: Icon(Icons.bolt),
                  label: '快速传输',
                ),
                NavigationDestination(
                  icon: Icon(Icons.sync_alt_outlined),
                  selectedIcon: Icon(Icons.sync_alt),
                  label: '任务',
                ),
              ],
            ),
    );
  }

  Widget _navigationRail() => NavigationRail(
    selectedIndex: _page,
    labelType: NavigationRailLabelType.all,
    onDestinationSelected: _selectPage,
    destinations: const [
      NavigationRailDestination(
        icon: Icon(Icons.folder_outlined),
        selectedIcon: Icon(Icons.folder),
        label: Text('仓库'),
      ),
      NavigationRailDestination(
        icon: Icon(Icons.bolt_outlined),
        selectedIcon: Icon(Icons.bolt),
        label: Text('快速传输'),
      ),
      NavigationRailDestination(
        icon: Icon(Icons.sync_alt_outlined),
        selectedIcon: Icon(Icons.sync_alt),
        label: Text('任务'),
      ),
    ],
  );

  void _selectPage(int value) {
    setState(() => _page = value);
    if (value == 1) unawaited(controller.refreshQuickTransfer());
  }

  Widget _repositoryView() {
    if (controller.isInitializing) {
      return const Center(child: CircularProgressIndicator());
    }
    if (!controller.isReady && controller.error != null) {
      return _connectionRequired();
    }
    return Column(
      children: [
        _responsiveToolbar(),
        _breadcrumbs(),
        if (controller.error != null)
          MaterialBanner(
            content: Text(controller.error!),
            actions: [
              TextButton(
                onPressed: controller.refresh,
                child: const Text('重试'),
              ),
            ],
          ),
        Expanded(
          child: DropTarget(
            onDragEntered: (_) => setState(() => _dragging = true),
            onDragExited: (_) => setState(() => _dragging = false),
            onDragDone: (detail) async {
              setState(() => _dragging = false);
              await _prepareUpload(
                detail.files.map((item) => File(item.path)).toList(),
              );
            },
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 120),
              margin: const EdgeInsets.fromLTRB(16, 0, 16, 16),
              decoration: BoxDecoration(
                color: _dragging
                    ? Theme.of(context).colorScheme.primaryContainer
                    : Theme.of(context).colorScheme.surface,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(
                  color: _dragging
                      ? Theme.of(context).colorScheme.primary
                      : Theme.of(context).colorScheme.outlineVariant,
                  width: _dragging ? 2 : 1,
                ),
              ),
              child: controller.isLoading
                  ? const Center(child: CircularProgressIndicator())
                  : controller.entries.isEmpty
                  ? Center(child: Text(_dragging ? '松开以上传到当前目录' : '此目录为空'))
                  : ListView.separated(
                      itemCount: controller.entries.length,
                      separatorBuilder: (_, _) => const Divider(height: 1),
                      itemBuilder: (_, index) =>
                          _entryTile(controller.entries[index]),
                    ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _connectionRequired() => Center(
    child: ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 500),
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.cloud_off_outlined, size: 48),
            const SizedBox(height: 16),
            const Text(
              '尚未连接到仓库',
              style: TextStyle(fontSize: 20, fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 8),
            Text(controller.error!, textAlign: TextAlign.center),
            const SizedBox(height: 20),
            if (controller.needsTailscale)
              FilledButton.icon(
                onPressed: _openTailscaleAndRetry,
                icon: const Icon(Icons.vpn_key_outlined),
                label: const Text('打开 Tailscale 并自动重试'),
              ),
            if (controller.needsTailscale) const SizedBox(height: 10),
            FilledButton.icon(
              onPressed: _showConnectionDialog,
              icon: const Icon(Icons.settings),
              label: const Text('连接设置'),
            ),
          ],
        ),
      ),
    ),
  );

  Future<void> _openTailscaleAndRetry() async {
    _awaitingTailscale = true;
    final opened = await TailscaleBridge.open();
    if (!mounted) return;
    if (!opened) {
      _awaitingTailscale = false;
      _message('请启动 Tailscale');
    }
  }

  Widget _responsiveToolbar() => LayoutBuilder(
    builder: (context, constraints) {
      final compact = constraints.maxWidth < 560;
      final navigation = Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          IconButton(
            tooltip: '返回上级',
            onPressed: controller.currentPath.isEmpty ? null : controller.goUp,
            icon: const Icon(Icons.arrow_back),
          ),
          IconButton(
            tooltip: '刷新',
            onPressed: controller.refresh,
            icon: const Icon(Icons.refresh),
          ),
        ],
      );
      final actions = Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          FilledButton.icon(
            onPressed: _pickUpload,
            icon: const Icon(Icons.upload_file),
            label: const Text('上传'),
          ),
          const SizedBox(width: 8),
          OutlinedButton.icon(
            onPressed: _createFolder,
            icon: const Icon(Icons.create_new_folder_outlined),
            label: const Text('新建文件夹'),
          ),
        ],
      );
      return Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 10),
        child: compact
            ? Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Center(child: actions),
                  const SizedBox(height: 4),
                  navigation,
                ],
              )
            : Row(children: [navigation, const Spacer(), actions]),
      );
    },
  );

  Widget _breadcrumbs() {
    final parts = controller.currentPath.isEmpty
        ? const <String>[]
        : controller.currentPath.split('/');
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 0, 24, 12),
      child: Row(
        children: [
          const Icon(Icons.storage_outlined, size: 18),
          const SizedBox(width: 6),
          Text(controller.mode == RepositoryMode.local ? 'Repository' : '远程仓库'),
          for (var index = 0; index < parts.length; index++) ...[
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 5),
              child: Text('/'),
            ),
            Text(parts[index]),
          ],
        ],
      ),
    );
  }

  Widget _entryTile(FileEntry entry) {
    final compact = MediaQuery.sizeOf(context).width < 600;
    return ListTile(
      contentPadding: EdgeInsets.symmetric(
        horizontal: compact ? 12 : 16,
        vertical: 4,
      ),
      leading: Icon(
        entry.isDirectory ? Icons.folder_outlined : _fileIcon(entry.name),
        color: entry.isDirectory ? Theme.of(context).colorScheme.primary : null,
      ),
      title: Text(entry.name, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Text(
        entry.isDirectory
            ? '文件夹'
            : '${_formatBytes(entry.size)}  ·  ${_formatDate(entry.modifiedAt)}',
      ),
      trailing: compact
          ? PopupMenuButton<String>(
              tooltip: '更多操作',
              onSelected: (value) {
                if (value == 'download') _download(entry);
                if (value == 'delete') _confirmDelete(entry);
              },
              itemBuilder: (context) => [
                if (!entry.isDirectory)
                  const PopupMenuItem(
                    value: 'download',
                    child: ListTile(
                      leading: Icon(Icons.download_outlined),
                      title: Text('下载'),
                    ),
                  ),
                const PopupMenuItem(
                  value: 'delete',
                  child: ListTile(
                    leading: Icon(Icons.delete_outline),
                    title: Text('删除'),
                  ),
                ),
              ],
            )
          : Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (entry.isDirectory) const Icon(Icons.chevron_right),
                if (!entry.isDirectory)
                  IconButton(
                    tooltip: '下载',
                    icon: const Icon(Icons.download_outlined),
                    onPressed: () => _download(entry),
                  ),
                IconButton(
                  tooltip: '删除',
                  icon: const Icon(Icons.delete_outline),
                  onPressed: () => _confirmDelete(entry),
                ),
              ],
            ),
      onTap: () => entry.isDirectory ? controller.open(entry) : _preview(entry),
    );
  }

  Future<void> _confirmDelete(FileEntry entry) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('删除项目？'),
        content: Text(
          entry.isDirectory
              ? '将删除“${entry.name}”及其所有内容，且无法恢复。'
              : '将删除“${entry.name}”，且无法恢复。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(context).colorScheme.error,
              foregroundColor: Theme.of(context).colorScheme.onError,
            ),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (confirmed == true) await controller.deleteEntry(entry);
  }

  Widget _taskView() => ListView(
    padding: const EdgeInsets.all(16),
    children: [
      Text('传输任务', style: Theme.of(context).textTheme.titleLarge),
      const SizedBox(height: 12),
      if (controller.tasks.isEmpty)
        const Padding(
          padding: EdgeInsets.only(top: 40),
          child: Center(child: Text('当前没有传输任务')),
        ),
      for (final task in controller.tasks) _taskTile(task),
    ],
  );

  Widget _quickTransferView() => LayoutBuilder(
    builder: (context, constraints) {
      final compact = constraints.maxWidth < 640;
      final recipients = controller.quickRecipients;
      final selected = recipients.any((device) => device.id == _quickTarget)
          ? _quickTarget
          : (recipients.isEmpty ? null : recipients.first.id);
      return RefreshIndicator(
        onRefresh: controller.refreshQuickTransfer,
        child: ListView(
          padding: EdgeInsets.all(compact ? 16 : 28),
          children: [
            Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '快速传输',
                        style: Theme.of(context).textTheme.headlineSmall,
                      ),
                      const SizedBox(height: 4),
                      const Text('原文件传输，接收完成后自动校验并清理中转文件。'),
                    ],
                  ),
                ),
                IconButton(
                  tooltip: '刷新设备与收件箱',
                  onPressed: controller.refreshQuickTransfer,
                  icon: const Icon(Icons.refresh),
                ),
              ],
            ),
            const SizedBox(height: 24),
            _quickIdentityBar(),
            const SizedBox(height: 16),
            DropTarget(
              onDragDone: (detail) async {
                if (selected == null) return;
                await _sendQuickFiles(
                  detail.files.map((item) => File(item.path)).toList(),
                );
              },
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.surface,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(
                    color: Theme.of(context).colorScheme.outlineVariant,
                  ),
                ),
                child: Padding(
                  padding: EdgeInsets.all(compact ? 16 : 24),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '发送到设备',
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                      const SizedBox(height: 16),
                      DropdownButtonFormField<String>(
                        initialValue: selected,
                        isExpanded: true,
                        decoration: const InputDecoration(
                          labelText: '目标设备',
                          prefixIcon: Icon(Icons.devices_other_outlined),
                        ),
                        hint: const Text('选择已绑定设备'),
                        items: recipients
                            .map(
                              (device) => DropdownMenuItem(
                                value: device.id,
                                child: Text(
                                  device.name,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                            )
                            .toList(),
                        onChanged: recipients.isEmpty
                            ? null
                            : (value) =>
                                  setState(() => _quickTarget = value ?? ''),
                      ),
                      const SizedBox(height: 16),
                      if (Platform.isAndroid)
                        compact
                            ? Column(
                                crossAxisAlignment: CrossAxisAlignment.stretch,
                                children: [
                                  FilledButton.icon(
                                    onPressed: selected == null
                                        ? null
                                        : _pickQuickMedia,
                                    icon: const Icon(Icons.perm_media_outlined),
                                    label: const Text('传图片或视频'),
                                  ),
                                  const SizedBox(height: 10),
                                  OutlinedButton.icon(
                                    onPressed: selected == null
                                        ? null
                                        : _pickQuickFiles,
                                    icon: const Icon(
                                      Icons.attach_file_outlined,
                                    ),
                                    label: const Text('传其他文件'),
                                  ),
                                ],
                              )
                            : Wrap(
                                spacing: 12,
                                runSpacing: 12,
                                children: [
                                  FilledButton.icon(
                                    onPressed: selected == null
                                        ? null
                                        : _pickQuickMedia,
                                    icon: const Icon(Icons.perm_media_outlined),
                                    label: const Text('传图片或视频'),
                                  ),
                                  OutlinedButton.icon(
                                    onPressed: selected == null
                                        ? null
                                        : _pickQuickFiles,
                                    icon: const Icon(
                                      Icons.attach_file_outlined,
                                    ),
                                    label: const Text('传其他文件'),
                                  ),
                                ],
                              )
                      else
                        FilledButton.icon(
                          onPressed: selected == null ? null : _pickQuickFiles,
                          icon: const Icon(Icons.attach_file_outlined),
                          label: const Text('选择文件'),
                        ),
                    ],
                  ),
                ),
              ),
            ),
            const SizedBox(height: 28),
            if (controller.quickError case final quickError?) ...[
              Text(
                quickError,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
              const SizedBox(height: 16),
            ],
            Row(
              children: [
                Text('收件箱', style: Theme.of(context).textTheme.titleLarge),
                const Spacer(),
                Text('${controller.quickInbox.length} 项'),
              ],
            ),
            const SizedBox(height: 8),
            if (controller.quickInbox.isEmpty)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 28),
                child: Center(child: Text('没有待领取的文件')),
              )
            else
              for (final manifest in controller.quickInbox)
                _quickInboxTile(manifest, compact),
          ],
        ),
      );
    },
  );

  String _quickTarget = '';

  Widget _quickIdentityBar() => DecoratedBox(
    decoration: BoxDecoration(
      color: Theme.of(context).colorScheme.secondaryContainer,
      borderRadius: BorderRadius.circular(8),
    ),
    child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      child: Row(
        children: [
          const Icon(Icons.devices_outlined),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              controller.deviceName,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.titleSmall,
            ),
          ),
          IconButton(
            tooltip: '修改设备名称',
            onPressed: _editQuickDeviceName,
            icon: const Icon(Icons.edit_outlined),
          ),
        ],
      ),
    ),
  );

  Widget _quickInboxTile(QuickTransferManifest manifest, bool compact) {
    final tile = ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      leading: Icon(
        manifest.isClaimed
            ? Icons.check_circle_outline
            : _fileIcon(manifest.name),
        color: manifest.isClaimed ? Theme.of(context).disabledColor : null,
      ),
      title: Text(
        manifest.name,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: manifest.isClaimed
            ? TextStyle(color: Theme.of(context).disabledColor)
            : null,
      ),
      subtitle: Text(
        '来自 ${controller.quickDeviceName(manifest.senderDevice)} · ${_formatDate(manifest.createdAt)}',
        style: manifest.isClaimed
            ? TextStyle(color: Theme.of(context).disabledColor)
            : null,
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (manifest.isClaimed)
            const SizedBox(
              width: 48,
              height: 48,
              child: Center(child: Icon(Icons.history_outlined)),
            )
          else if (controller.canClaimQuickTransfer(manifest))
            IconButton(
              tooltip: '领取并保存',
              onPressed: () => _claimQuickTransfer(manifest),
              icon: const Icon(Icons.download_outlined),
            )
          else
            const SizedBox(
              width: 48,
              height: 48,
              child: Center(child: Icon(Icons.schedule_outlined)),
            ),
          if (!Platform.isAndroid)
            IconButton(
              tooltip: '删除记录',
              onPressed: () => _confirmDeleteQuickTransfer(manifest),
              icon: const Icon(Icons.close),
            ),
        ],
      ),
    );
    if (!Platform.isAndroid) return tile;
    return Dismissible(
      key: ValueKey('quick-transfer-${manifest.id}'),
      direction: DismissDirection.endToStart,
      confirmDismiss: (_) => _confirmDeleteQuickTransfer(manifest),
      background: Container(
        alignment: Alignment.centerRight,
        padding: const EdgeInsets.symmetric(horizontal: 20),
        color: Theme.of(context).colorScheme.error,
        child: Icon(
          Icons.delete_outline,
          color: Theme.of(context).colorScheme.onError,
        ),
      ),
      child: tile,
    );
  }

  Future<bool> _confirmDeleteQuickTransfer(
    QuickTransferManifest manifest,
  ) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('删除快传记录？'),
        content: Text(
          manifest.isClaimed
              ? '将从所有参与设备的列表中删除“${manifest.name}”记录。'
              : '删除后将无法领取该文件。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(context).colorScheme.error,
              foregroundColor: Theme.of(context).colorScheme.onError,
            ),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (confirmed != true) return false;
    try {
      await controller.deleteQuickTransfer(manifest);
      if (mounted) _message('已删除');
      return true;
    } catch (exception) {
      if (mounted) _message('删除失败：${controller.describeError(exception)}');
      return false;
    }
  }

  Future<void> _pickQuickFiles() async {
    final files = await openFiles(
      acceptedTypeGroups: const [
        XTypeGroup(label: '所有文件', extensions: <String>[]),
      ],
    );
    if (files.isEmpty) return;
    final materialized = await _materialize(files);
    try {
      await _sendQuickFiles(materialized);
    } finally {
      await _cleanMaterializedUploads();
    }
  }

  Future<void> _pickQuickMedia() async {
    final List<File> files;
    if (Platform.isAndroid) {
      files = await AndroidMediaPicker.pickImagesAndVideos();
    } else {
      files = (await ImagePicker().pickMultipleMedia())
          .map((item) => File(item.path))
          .toList();
    }
    if (files.isEmpty) return;
    await _sendQuickFiles(files);
  }

  Future<void> _sendQuickFiles(List<File> files) async {
    final target = _quickTarget.isNotEmpty
        ? _quickTarget
        : controller.quickRecipients.firstOrNull?.id ?? '';
    if (target.isEmpty) {
      if (mounted) _message('请先选择目标设备');
      return;
    }
    for (final file in files) {
      try {
        await controller.publishQuickTransfer(file, targetDevice: target);
        if (mounted) {
          _message('已发送');
        }
      } catch (exception) {
        if (mounted) _message('快传失败：${controller.describeError(exception)}');
      }
    }
  }

  Future<void> _claimQuickTransfer(QuickTransferManifest manifest) async {
    if (Platform.isAndroid) {
      final mimeType = _mimeType(manifest.name);
      final isMedia =
          mimeType.startsWith('image/') || mimeType.startsWith('video/');
      final documentTarget = isMedia
          ? null
          : await AndroidSaveFile.chooseDocumentTarget(
              suggestedName: manifest.name,
              mimeType: mimeType,
            );
      if (!isMedia && documentTarget == null) return;
      final temporary = await getTemporaryDirectory();
      final target = File(
        '${temporary.path}${Platform.pathSeparator}${manifest.name}',
      );
      try {
        await controller.receiveQuickTransfer(
          manifest,
          target: target,
          finalize: false,
        );
        if (!mounted) return;
        final saved = isMedia
            ? await AndroidSaveFile.saveMedia(
                source: target,
                suggestedName: manifest.name,
                mimeType: mimeType,
              )
            : await AndroidSaveFile.saveToDocumentTarget(
                source: target,
                targetUri: documentTarget!,
              );
        if (saved) {
          await controller.markQuickTransferClaimed(manifest);
          if (mounted) _message('文件已保存');
        } else if (mounted) {
          _message('已取消保存');
        }
      } catch (exception) {
        if (mounted) _message('领取失败：${controller.describeError(exception)}');
      } finally {
        if (await target.exists()) await target.delete();
      }
      return;
    }
    final location = await getSaveLocation(suggestedName: manifest.name);
    if (location == null) return;
    try {
      await controller.receiveQuickTransfer(
        manifest,
        target: File(location.path),
      );
      if (mounted) _message('文件已保存');
    } catch (exception) {
      if (mounted) _message('领取失败：${controller.describeError(exception)}');
    }
  }

  Future<void> _editQuickDeviceName() async {
    final input = TextEditingController(text: controller.deviceName);
    final name = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('设备名称'),
        content: TextField(
          controller: input,
          autofocus: true,
          maxLength: 40,
          decoration: const InputDecoration(labelText: '显示名称'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, input.text),
            child: const Text('保存'),
          ),
        ],
      ),
    );
    if (name != null) await controller.setQuickDeviceName(name);
  }

  Widget _taskTile(TransferTask task) => Card(
    margin: const EdgeInsets.only(bottom: 8),
    child: Padding(
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                task.direction == TransferDirection.upload
                    ? Icons.upload_outlined
                    : task.direction == TransferDirection.quickDrop
                    ? Icons.bolt_outlined
                    : Icons.download_outlined,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  task.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              Text(task.isPaused ? '已暂停' : _statusLabel(task.status)),
            ],
          ),
          const SizedBox(height: 10),
          LinearProgressIndicator(
            value: task.status == TransferStatus.completed ? 1 : task.progress,
          ),
          const SizedBox(height: 6),
          Text(
            '${_formatBytes(task.transferredBytes)} / ${_formatBytes(task.totalBytes)}',
          ),
          if (task.error != null) ...[
            const SizedBox(height: 4),
            Text(
              '失败原因：${task.error}',
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          ],
          const SizedBox(height: 6),
          Align(
            alignment: Alignment.centerRight,
            child: task.status == TransferStatus.running
                ? Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      OutlinedButton.icon(
                        onPressed: task.isPaused
                            ? () => controller.resumeTask(task)
                            : () => controller.pauseTask(task),
                        icon: Icon(
                          task.isPaused
                              ? Icons.play_arrow_outlined
                              : Icons.pause_outlined,
                        ),
                        label: Text(task.isPaused ? '继续' : '暂停'),
                      ),
                      const SizedBox(width: 8),
                      OutlinedButton.icon(
                        onPressed: () => controller.cancelTask(task),
                        icon: const Icon(Icons.cancel_outlined),
                        label: const Text('取消并清理'),
                      ),
                    ],
                  )
                : TextButton.icon(
                    onPressed: () => controller.removeTask(task),
                    icon: const Icon(Icons.delete_outline),
                    label: const Text('移除任务'),
                  ),
          ),
        ],
      ),
    ),
  );

  Future<void> _pickUpload() async {
    final files = await openFiles(
      acceptedTypeGroups: const [
        XTypeGroup(label: '所有文件', extensions: <String>[]),
      ],
    );
    if (files.isEmpty || !mounted) return;
    final materialized = await _materialize(files);
    try {
      await _prepareUpload(materialized);
    } finally {
      await _cleanMaterializedUploads();
    }
  }

  Future<List<File>> _materialize(List<XFile> files) async {
    final directory = await getTemporaryDirectory();
    final result = <File>[];
    for (final item in files) {
      final candidate = File(item.path);
      if (await candidate.exists()) {
        result.add(candidate);
      } else {
        final target = File(
          '${directory.path}${Platform.pathSeparator}${DateTime.now().microsecondsSinceEpoch}-${item.name}',
        );
        await item.saveTo(target.path);
        result.add(target);
        _materializedUploadPaths.add(target.path);
      }
    }
    return result;
  }

  Future<void> _prepareUpload(List<File> files) async {
    if (files.isEmpty || !mounted) return;
    final existing = controller.entries
        .map((entry) => entry.name.toLowerCase())
        .toSet();
    final conflict = files.any(
      (file) => existing.contains(file.uri.pathSegments.last.toLowerCase()),
    );
    var overwrite = true;
    var keepBoth = false;
    if (conflict) {
      final choice = await showDialog<String>(
        context: context,
        builder: _conflictDialog,
      );
      if (choice == null || choice == 'cancel') return;
      overwrite = choice == 'overwrite';
      keepBoth = choice == 'keep';
    }
    await controller.uploadFiles(
      files,
      overwrite: overwrite,
      keepBoth: keepBoth,
    );
  }

  Future<void> _cleanMaterializedUploads() async {
    final paths = _materializedUploadPaths.toList(growable: false);
    _materializedUploadPaths.clear();
    for (final path in paths) {
      final file = File(path);
      if (await file.exists()) await file.delete();
    }
  }

  Widget _conflictDialog(BuildContext context) => AlertDialog(
    title: const Text('发现同名文件'),
    content: const Text('请选择上传策略。覆盖会在确认新文件完整写入后替换现有文件。'),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context, 'cancel'),
        child: const Text('取消'),
      ),
      TextButton(
        onPressed: () => Navigator.pop(context, 'keep'),
        child: const Text('保留两份'),
      ),
      FilledButton(
        onPressed: () => Navigator.pop(context, 'overwrite'),
        child: const Text('覆盖'),
      ),
    ],
  );

  Future<void> _createFolder() async {
    final input = TextEditingController();
    final name = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('新建文件夹'),
        content: TextField(
          controller: input,
          autofocus: true,
          decoration: const InputDecoration(labelText: '文件夹名称'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, input.text),
            child: const Text('创建'),
          ),
        ],
      ),
    );
    if (name != null && name.trim().isNotEmpty) {
      await controller.createDirectory(name.trim());
    }
  }

  Future<void> _download(FileEntry entry) async {
    if (Platform.isAndroid) {
      final documentTarget = await AndroidSaveFile.chooseDocumentTarget(
        suggestedName: entry.name,
        mimeType: _mimeType(entry.name),
      );
      if (documentTarget == null) return;
      final temp = await getTemporaryDirectory();
      final target = File(
        '${temp.path}${Platform.pathSeparator}${DateTime.now().microsecondsSinceEpoch}-${entry.name}',
      );
      try {
        await controller.downloadFile(entry, target);
        if (!mounted) return;
        final saved = await AndroidSaveFile.saveToDocumentTarget(
          source: target,
          targetUri: documentTarget,
        );
        if (mounted) _message(saved ? '文件已保存' : '已取消保存');
      } finally {
        if (await target.exists()) await target.delete();
      }
      return;
    }
    final location = await getSaveLocation(suggestedName: entry.name);
    if (location == null) return;
    await controller.downloadFile(entry, File(location.path));
  }

  Future<void> _preview(FileEntry entry) async {
    if (!_isPreviewable(entry.name)) {
      _message('请下载后使用系统应用打开');
      return;
    }
    final file = await controller.previewFile(entry);
    if (!mounted) return;
    try {
      await showDialog<void>(
        context: context,
        builder: (_) => _PreviewDialog(file: file, name: entry.name),
      );
    } finally {
      await controller.releasePreview(file);
    }
  }

  Future<void> _showConnectionDialog() async {
    final local = TextEditingController(text: controller.localRoot);
    final host = TextEditingController(
      text: controller.sftpProfile?.host ?? '',
    );
    final port = TextEditingController(
      text: '${controller.sftpProfile?.port ?? 2022}',
    );
    final username = TextEditingController(
      text: controller.sftpProfile?.username ?? '',
    );
    final password = TextEditingController(
      text: controller.sftpProfile?.password ?? '',
    );
    final fingerprint = TextEditingController(
      text: controller.sftpProfile?.hostKeyFingerprint ?? '',
    );
    var selectedMode = controller.mode;
    final save = await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: const Text('连接设置'),
          content: SizedBox(
            width: 460,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  SegmentedButton<RepositoryMode>(
                    segments: const [
                      ButtonSegment(
                        value: RepositoryMode.local,
                        label: Text('本地仓库'),
                      ),
                      ButtonSegment(
                        value: RepositoryMode.sftp,
                        label: Text('SFTPGo'),
                      ),
                    ],
                    selected: {selectedMode},
                    onSelectionChanged: (value) =>
                        setDialogState(() => selectedMode = value.first),
                  ),
                  const SizedBox(height: 16),
                  if (selectedMode == RepositoryMode.local)
                    TextField(
                      controller: local,
                      decoration: const InputDecoration(
                        labelText: 'Windows 仓库路径',
                        hintText: r'E:\Repository',
                      ),
                    ),
                  if (selectedMode == RepositoryMode.sftp) ...[
                    TextField(
                      controller: host,
                      decoration: const InputDecoration(
                        labelText: 'MagicDNS 主机名或 Tailscale IP',
                      ),
                    ),
                    TextField(
                      controller: port,
                      keyboardType: TextInputType.number,
                      decoration: const InputDecoration(labelText: 'SFTP 端口'),
                    ),
                    TextField(
                      controller: username,
                      decoration: const InputDecoration(labelText: '用户名'),
                    ),
                    TextField(
                      controller: password,
                      obscureText: true,
                      decoration: const InputDecoration(labelText: '密码'),
                    ),
                    TextField(
                      controller: fingerprint,
                      decoration: const InputDecoration(
                        labelText: 'SSH 主机密钥指纹',
                        hintText: 'SHA256:...',
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('保存并连接'),
            ),
          ],
        ),
      ),
    );
    if (save != true) return;
    if (selectedMode == RepositoryMode.local) {
      await controller.configureLocalRoot(local.text.trim());
    } else {
      await controller.configureSftp(
        SftpConnectionProfile(
          host: host.text.trim(),
          port: int.tryParse(port.text.trim()) ?? 2022,
          username: username.text.trim(),
          password: password.text,
          hostKeyFingerprint: fingerprint.text.trim(),
        ),
      );
    }
  }

  void _message(String text) {
    final messenger = ScaffoldMessenger.of(context);
    messenger.hideCurrentSnackBar();
    messenger.showSnackBar(
      SnackBar(
        duration: const Duration(seconds: 2),
        content: Text(text, maxLines: 1, overflow: TextOverflow.ellipsis),
      ),
    );
  }
}

class _PreviewDialog extends StatelessWidget {
  const _PreviewDialog({required this.file, required this.name});

  final File file;
  final String name;

  @override
  Widget build(BuildContext context) {
    final image = _isImage(name);
    return Dialog(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 900, maxHeight: 700),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      name,
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                  ),
                  IconButton(
                    onPressed: () => Navigator.pop(context),
                    icon: const Icon(Icons.close),
                  ),
                ],
              ),
              const Divider(),
              Expanded(
                child: image
                    ? InteractiveViewer(child: Center(child: Image.file(file)))
                    : FutureBuilder<String>(
                        future: _readText(file),
                        builder: (context, snapshot) => SingleChildScrollView(
                          child: SelectableText(snapshot.data ?? '正在读取...'),
                        ),
                      ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<String> _readText(File file) async {
    final length = await file.length();
    if (length > 1024 * 1024) return '文件超过 1 MB，首期不在应用内预览。';
    return file.readAsString();
  }
}

bool _isImage(String name) => const {
  'jpg',
  'jpeg',
  'png',
  'webp',
  'gif',
  'bmp',
}.contains(name.split('.').last.toLowerCase());
bool _isPreviewable(String name) =>
    _isImage(name) ||
    const {
      'txt',
      'md',
      'json',
      'yaml',
      'yml',
      'csv',
      'dart',
      'py',
      'js',
      'ts',
      'java',
      'kt',
      'cpp',
      'c',
      'h',
      'html',
      'css',
      'xml',
    }.contains(name.split('.').last.toLowerCase());
IconData _fileIcon(String name) => _isImage(name)
    ? Icons.image_outlined
    : const {
        'mp3',
        'm4a',
        'wav',
        'flac',
      }.contains(name.split('.').last.toLowerCase())
    ? Icons.audio_file_outlined
    : const {
        'mp4',
        'mov',
        'mkv',
        'webm',
        'avi',
      }.contains(name.split('.').last.toLowerCase())
    ? Icons.video_file_outlined
    : Icons.description_outlined;
String _formatBytes(int value) {
  if (value < 1024) return '$value B';
  final units = ['KB', 'MB', 'GB', 'TB'];
  var amount = value / 1024;
  var index = 0;
  while (amount >= 1024 && index < units.length - 1) {
    amount /= 1024;
    index++;
  }
  return '${amount.toStringAsFixed(amount >= 10 ? 0 : 1)} ${units[index]}';
}

String _formatDate(DateTime value) =>
    '${value.year}-${value.month.toString().padLeft(2, '0')}-${value.day.toString().padLeft(2, '0')} ${value.hour.toString().padLeft(2, '0')}:${value.minute.toString().padLeft(2, '0')}';
String _statusLabel(TransferStatus status) => switch (status) {
  TransferStatus.queued => '等待中',
  TransferStatus.running => '传输中',
  TransferStatus.completed => '已完成',
  TransferStatus.failed => '失败',
  TransferStatus.cancelled => '已取消',
};
String _mimeType(String name) {
  final extension = name.split('.').last.toLowerCase();
  return switch (extension) {
    'jpg' || 'jpeg' => 'image/jpeg',
    'png' => 'image/png',
    'webp' => 'image/webp',
    'gif' => 'image/gif',
    'mp3' => 'audio/mpeg',
    'm4a' => 'audio/mp4',
    'wav' => 'audio/wav',
    'mp4' => 'video/mp4',
    'mov' => 'video/quicktime',
    _ => 'application/octet-stream',
  };
}
