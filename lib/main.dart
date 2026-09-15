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
import 'core/path_utils.dart';
import 'core/photo_transfer.dart';
import 'core/quick_transfer.dart';
import 'core/transfer_control.dart';
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
  final Set<String> _materializedUploadPaths = <String>{};

  AppController get controller => widget.controller;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    controller.setQuickTransferPageActive(_page == 1);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    controller.setQuickTransferPageActive(false);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      if (_awaitingTailscale) {
        _awaitingTailscale = false;
        _message('正在重新连接…');
      }
      unawaited(controller.onAppResumed());
    }
  }

  @override
  Widget build(BuildContext context) {
    final wide = MediaQuery.sizeOf(context).width >= 840;
    final content = switch (_page) {
      0 => _repositoryView(),
      1 when !controller.isReady => _connectionRequired(),
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
            onPressed: controller.hasActiveTransfers || controller.isLoading
                ? null
                : _showConnectionDialog,
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
    controller.setQuickTransferPageActive(value == 1);
  }

  Widget _repositoryView() {
    if (!controller.isReady && controller.isInitializing) {
      return const Center(child: CircularProgressIndicator());
    }
    if (!controller.isReady) {
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
                  : controller.sortedEntries.isEmpty
                  ? Center(child: Text(_dragging ? '松开以上传到当前目录' : '此目录为空'))
                  : ListView.separated(
                      itemCount: controller.sortedEntries.length,
                      separatorBuilder: (_, _) => const Divider(height: 1),
                      itemBuilder: (_, index) =>
                          _entryTile(controller.sortedEntries[index]),
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
            Icon(
              controller.isLoading
                  ? Icons.cloud_sync_outlined
                  : Icons.cloud_off_outlined,
              size: 48,
            ),
            const SizedBox(height: 16),
            Text(
              controller.isLoading ? '正在连接仓库' : '尚未连接到仓库',
              style: TextStyle(fontSize: 20, fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 8),
            if (controller.error case final error?)
              Text(error, textAlign: TextAlign.center)
            else
              const Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                  SizedBox(width: 10),
                  Text('正在连接…'),
                ],
              ),
            const SizedBox(height: 20),
            FilledButton.icon(
              onPressed: controller.isLoading ? null : _retryConnection,
              icon: const Icon(Icons.refresh),
              label: const Text('重试'),
            ),
            const SizedBox(height: 10),
            FilledButton.icon(
              onPressed: controller.isLoading ? null : _showConnectionDialog,
              icon: const Icon(Icons.settings),
              label: const Text('连接设置'),
            ),
          ],
        ),
      ),
    ),
  );

  Future<void> _retryConnection() async {
    await controller.connect();
    if (!mounted || controller.isReady) return;

    final tailscaleActive = await TailscaleBridge.isActive();
    final shouldOpenTailscale = Platform.isAndroid
        ? !tailscaleActive
        : controller.needsTailscale && !tailscaleActive;
    if (!mounted || !shouldOpenTailscale) return;

    _message('未检测到 Tailscale 连接，正在打开 Tailscale…');
    await Future<void>.delayed(const Duration(milliseconds: 350));
    if (!mounted) return;

    _awaitingTailscale = true;
    final opened = await TailscaleBridge.open();
    if (!mounted) return;
    if (!opened) {
      _awaitingTailscale = false;
      _message('无法启动 Tailscale，请确认已安装');
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
      final fileActions = Wrap(
        alignment: WrapAlignment.center,
        spacing: 8,
        runSpacing: 4,
        children: [
          FilledButton.icon(
            onPressed: _pickUpload,
            icon: const Icon(Icons.upload_file),
            label: const Text('上传'),
          ),
          OutlinedButton.icon(
            onPressed: _createFolder,
            icon: const Icon(Icons.create_new_folder_outlined),
            label: const Text('新建文件夹'),
          ),
        ],
      );
      final sorting = Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          IconButton(
            tooltip: controller.sortAscending ? '当前升序' : '当前降序',
            onPressed: () => controller.setSort(
              controller.sortField,
              ascending: !controller.sortAscending,
            ),
            icon: Icon(
              controller.sortAscending
                  ? Icons.arrow_upward
                  : Icons.arrow_downward,
            ),
          ),
          PopupMenuButton<FileSortField>(
            tooltip: '排序',
            icon: const Icon(Icons.sort),
            initialValue: controller.sortField,
            onSelected: controller.setSort,
            itemBuilder: (_) => const [
              PopupMenuItem(value: FileSortField.name, child: Text('按名称')),
              PopupMenuItem(value: FileSortField.type, child: Text('按类型')),
              PopupMenuItem(value: FileSortField.size, child: Text('按大小')),
              PopupMenuItem(
                value: FileSortField.modifiedAt,
                child: Text('按修改时间'),
              ),
            ],
          ),
        ],
      );
      return Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 10),
        child: compact
            ? Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Center(child: fileActions),
                  const SizedBox(height: 8),
                  Row(children: [navigation, const Spacer(), sorting]),
                ],
              )
            : Row(children: [navigation, sorting, const Spacer(), fileActions]),
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
          const Spacer(),
          _connectionStatusChip(),
        ],
      ),
    );
  }

  Widget _connectionStatusChip() {
    final (label, color, icon) = switch (controller.connectionStatus) {
      RepositoryConnectionStatus.connected => (
        '已连接',
        Colors.green,
        Icons.cloud_done_outlined,
      ),
      RepositoryConnectionStatus.connecting => (
        '连接中',
        Colors.orange,
        Icons.cloud_sync_outlined,
      ),
      RepositoryConnectionStatus.retrying => (
        '重连中',
        Colors.orange,
        Icons.sync_outlined,
      ),
      RepositoryConnectionStatus.disconnected => (
        '未连接',
        Colors.red,
        Icons.cloud_off_outlined,
      ),
    };
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 16, color: color),
        const SizedBox(width: 4),
        Text(label, style: TextStyle(color: color, fontSize: 12)),
      ],
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
    if (confirmed == true) {
      try {
        await controller.deleteEntry(entry);
        if (mounted) _message('已删除');
      } catch (exception) {
        if (mounted) _message(controller.describeError(exception));
      }
    }
  }

  Widget _taskView() => ListView(
    padding: const EdgeInsets.all(16),
    children: [
      Row(
        children: [
          Text('传输任务', style: Theme.of(context).textTheme.titleLarge),
          const Spacer(),
          if (controller.tasks.any(
            (task) =>
                task.status == TransferStatus.completed ||
                task.status == TransferStatus.cancelled,
          ))
            TextButton.icon(
              onPressed: controller.clearFinishedTasks,
              icon: const Icon(Icons.cleaning_services_outlined),
              label: const Text('清除已完成任务'),
            ),
        ],
      ),
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
        onRefresh: () => controller.refreshQuickTransfer(refreshDevices: true),
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
                      const Text('照片直达默认目录，其他文件可靠中转并自动校验。'),
                    ],
                  ),
                ),
                IconButton(
                  tooltip: '刷新设备与收件箱',
                  onPressed: () =>
                      controller.refreshQuickTransfer(refreshDevices: true),
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
                  targetDevice: selected,
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
                        key: ValueKey(
                          'quick-target-$selected-${recipients.map((device) => device.id).join(',')}',
                        ),
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
                                        : () => _pickQuickMedia(selected),
                                    icon: const Icon(Icons.perm_media_outlined),
                                    label: const Text('传图片或视频'),
                                  ),
                                  const SizedBox(height: 10),
                                  OutlinedButton.icon(
                                    onPressed: selected == null
                                        ? null
                                        : () => _pickQuickFiles(selected),
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
                                        : () => _pickQuickMedia(selected),
                                    icon: const Icon(Icons.perm_media_outlined),
                                    label: const Text('传图片或视频'),
                                  ),
                                  OutlinedButton.icon(
                                    onPressed: selected == null
                                        ? null
                                        : () => _pickQuickFiles(selected),
                                    icon: const Icon(
                                      Icons.attach_file_outlined,
                                    ),
                                    label: const Text('传其他文件'),
                                  ),
                                ],
                              )
                      else
                        FilledButton.icon(
                          onPressed: selected == null
                              ? null
                              : () => _pickQuickFiles(selected),
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
              tooltip: controller.isQuickTransferReceiving(manifest.id)
                  ? '正在领取'
                  : '领取并保存',
              onPressed: controller.isQuickTransferReceiving(manifest.id)
                  ? null
                  : () => _claimQuickTransfer(manifest),
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
      // The controller removes the item optimistically as soon as deletion is
      // confirmed. Keep the completion callback present so Dismissible can
      // finish its resize lifecycle even if a slow repository delete is still
      // running in the background.
      onDismissed: (_) {},
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
    // Dismissible must receive its answer immediately. Waiting for remote
    // deletion and the follow-up refresh leaves the Android row stranded on
    // its red background whenever the network is slow.
    unawaited(_deleteQuickTransferInBackground(manifest));
    return true;
  }

  Future<void> _deleteQuickTransferInBackground(
    QuickTransferManifest manifest,
  ) async {
    try {
      await controller.deleteQuickTransfer(manifest);
      if (mounted) _message('已删除');
    } catch (exception) {
      if (mounted) _message('删除失败：${controller.describeError(exception)}');
    }
  }

  Future<void> _pickQuickFiles(String targetDevice) async {
    final files = await openFiles(
      acceptedTypeGroups: const [
        XTypeGroup(label: '所有文件', extensions: <String>[]),
      ],
    );
    if (files.isEmpty) return;
    final materialized = await _materialize(files);
    try {
      await _sendQuickFiles(materialized, targetDevice: targetDevice);
    } finally {
      await _cleanMaterializedUploads();
    }
  }

  Future<void> _pickQuickMedia(String targetDevice) async {
    final selections = <_QuickFileSelection>[];
    if (Platform.isAndroid) {
      selections.addAll(
        (await AndroidMediaPicker.pickImagesAndVideos()).map(
          (item) => _QuickFileSelection(
            file: item.file,
            name: item.name,
            mimeType: item.mimeType,
          ),
        ),
      );
    } else {
      selections.addAll(
        (await ImagePicker().pickMultipleMedia()).map(
          (item) => _QuickFileSelection(
            file: File(item.path),
            name: item.name,
            mimeType: mimeTypeForName(item.name),
          ),
        ),
      );
    }
    final files = selections.map((item) => item.file).toList(growable: false);
    if (files.isEmpty) return;
    try {
      await _sendQuickFiles(
        files,
        targetDevice: targetDevice,
        allowPhotoDirect: true,
        metadata: {
          for (final selection in selections) selection.file.path: selection,
        },
      );
    } finally {
      if (Platform.isAndroid) await AndroidMediaPicker.cleanup(files);
    }
  }

  Future<void> _sendQuickFiles(
    List<File> files, {
    required String targetDevice,
    bool allowPhotoDirect = false,
    Map<String, _QuickFileSelection>? metadata,
  }) async {
    final target = targetDevice;
    if (target.isEmpty) {
      if (mounted) _message('请先选择目标设备');
      return;
    }
    try {
      final total = await controller.validateTransferSelection(files);
      if (mounted) {
        _message('已加入 ${files.length} 个文件，共 ${_formatBytes(total)}');
      }
      final results = await Future.wait<String>([
        for (final file in files)
          _sendQuickFile(
            file,
            target,
            allowPhotoDirect: allowPhotoDirect,
            metadata: metadata?[file.path],
          ),
      ]);
      if (mounted) {
        final succeeded = results.where((value) => value == 'sent').length;
        final cancelled = results.where((value) => value == 'cancelled').length;
        final failed = results.length - succeeded - cancelled;
        final parts = <String>[
          '成功 $succeeded 个',
          if (failed > 0) '失败 $failed 个',
          if (cancelled > 0) '取消 $cancelled 个',
        ];
        _message('本批次已结束：${parts.join('，')}');
      }
    } catch (exception) {
      if (mounted) _message(controller.describeError(exception));
    }
  }

  Future<void> _retryTask(TransferTask task) async {
    try {
      await controller.retryTask(task);
      if (mounted && task.status == TransferStatus.completed) {
        _message('重试成功：${task.name}');
      }
    } catch (exception) {
      if (mounted) _message('重试失败：${controller.describeError(exception)}');
    }
  }

  Future<String> _sendQuickFile(
    File file,
    String target, {
    bool allowPhotoDirect = false,
    _QuickFileSelection? metadata,
  }) async {
    try {
      final name = metadata?.name ?? file.uri.pathSegments.last;
      final mimeType = metadata?.mimeType ?? mimeTypeForName(name);
      final isPhoto =
          allowPhotoDirect &&
          isSupportedPhotoTransfer(name: name, mimeType: mimeType);
      await controller.publishQuickTransfer(
        file,
        targetDevice: target,
        originalName: name,
        mimeType: mimeType,
        isPhoto: isPhoto,
      );
      return 'sent';
    } on TransferCancelled {
      return 'cancelled';
    } catch (exception) {
      return 'failed';
    }
  }

  Future<void> _claimQuickTransfer(QuickTransferManifest manifest) async {
    if (Platform.isAndroid) {
      final mimeType = mimeTypeForName(manifest.name);
      final isMedia = isMediaMimeType(mimeType);
      final documentTarget = isMedia
          ? null
          : await AndroidSaveFile.chooseDocumentTarget(
              suggestedName: manifest.name,
              mimeType: mimeType,
            );
      if (!isMedia && documentTarget == null) return;
      final temporary = await getApplicationSupportDirectory();
      final target = File(
        '${temporary.path}${Platform.pathSeparator}${manifest.id}-${manifest.name}',
      );
      try {
        final saved = await controller.receiveQuickTransfer(
          manifest,
          target: target,
          androidTargetUri: documentTarget,
          saveAsMedia: isMedia,
          mimeType: mimeType,
        );
        if (saved && mounted) _message('文件已保存');
      } catch (exception) {
        if (mounted) _message('领取失败：${controller.describeError(exception)}');
      }
      return;
    }
    try {
      final saved = await controller.receiveQuickTransfer(
        manifest,
        target: await controller.defaultQuickReceiveTarget(manifest.name),
      );
      if (saved && mounted) _message('文件已保存');
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
                    : task.direction == TransferDirection.quickSend ||
                          task.direction == TransferDirection.quickReceive
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
            child: task.status == TransferStatus.finalizing
                ? const Text('正在安全保存，请稍候…')
                : task.status == TransferStatus.running ||
                      task.status == TransferStatus.queued
                ? Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (task.status == TransferStatus.running &&
                          task.supportsPause) ...[
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
                      ],
                      OutlinedButton.icon(
                        onPressed: () => controller.cancelTask(task),
                        icon: const Icon(Icons.cancel_outlined),
                        label: const Text('取消并清理'),
                      ),
                    ],
                  )
                : Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (task.status == TransferStatus.failed &&
                          controller.canRetryTask(task)) ...[
                        FilledButton.icon(
                          onPressed: () => _retryTask(task),
                          icon: const Icon(Icons.refresh),
                          label: const Text('重试'),
                        ),
                        const SizedBox(width: 8),
                      ],
                      TextButton.icon(
                        onPressed: () => controller.removeTask(task),
                        icon: const Icon(Icons.delete_outline),
                        label: const Text('移除任务'),
                      ),
                    ],
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
    try {
      final total = await controller.validateTransferSelection(files);
      if (mounted) {
        _message('已选择 ${files.length} 个文件，共 ${_formatBytes(total)}');
      }
    } catch (exception) {
      if (mounted) _message(controller.describeError(exception));
      return;
    }
    if (!mounted) return;
    final existing = controller.entries
        .map((entry) => entry.name.toLowerCase())
        .toSet();
    final conflict = files.any(
      (file) => existing.contains(
        sanitizeTransferFileName(file.uri.pathSegments.last).toLowerCase(),
      ),
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
    try {
      await controller.uploadFiles(
        files,
        overwrite: overwrite,
        keepBoth: keepBoth,
      );
    } catch (exception) {
      if (mounted) _message('上传失败：${controller.describeError(exception)}');
    }
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
      try {
        await controller.createDirectory(name.trim());
      } catch (exception) {
        if (mounted) _message(controller.describeError(exception));
      }
    }
  }

  Future<void> _download(FileEntry entry) async {
    if (Platform.isAndroid) {
      final documentTarget = await AndroidSaveFile.chooseDocumentTarget(
        suggestedName: entry.name,
        mimeType: mimeTypeForName(entry.name),
      );
      if (documentTarget == null) return;
      final temp = await getApplicationSupportDirectory();
      final target = File(
        '${temp.path}${Platform.pathSeparator}${uniqueSuffix()}-${entry.name}',
      );
      try {
        await controller.downloadFile(
          entry,
          target,
          deleteTargetOnCancel: true,
          androidTargetUri: documentTarget,
        );
        if (mounted) _message('文件已保存');
      } catch (exception) {
        if (mounted) _message('下载失败：${controller.describeError(exception)}');
      }
      return;
    }
    final location = await getSaveLocation(suggestedName: entry.name);
    if (location == null) return;
    try {
      await controller.downloadFile(entry, File(location.path));
      if (mounted) _message('文件已保存');
    } catch (exception) {
      if (mounted) _message('下载失败：${controller.describeError(exception)}');
    }
  }

  Future<void> _preview(FileEntry entry) async {
    if (!_isPreviewable(entry.name)) {
      _message('请下载后使用系统应用打开');
      return;
    }
    final image = _isImage(entry.name);
    final limit = image ? 50 * 1024 * 1024 : 1024 * 1024;
    if (entry.size > limit) {
      _message(image ? '图片过大，请下载后查看' : '文本超过 1 MB，请下载后查看');
      return;
    }
    var loadingOpen = true;
    var cancelled = false;
    final previewControl = TransferControl();
    final future = controller.previewFile(entry, control: previewControl);
    unawaited(
      showDialog<void>(
        context: context,
        barrierDismissible: false,
        builder: (dialogContext) => AlertDialog(
          content: const Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              SizedBox(
                width: 22,
                height: 22,
                child: CircularProgressIndicator(strokeWidth: 2.5),
              ),
              SizedBox(width: 16),
              Text('正在准备预览…'),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () {
                cancelled = true;
                loadingOpen = false;
                unawaited(previewControl.cancel());
                Navigator.pop(dialogContext);
              },
              child: const Text('取消'),
            ),
          ],
        ),
      ),
    );
    late final File file;
    try {
      file = await future;
    } catch (exception) {
      if (mounted && loadingOpen) Navigator.of(context).pop();
      if (mounted && !cancelled) _message(controller.describeError(exception));
      return;
    }
    if (mounted && loadingOpen) Navigator.of(context).pop();
    if (cancelled) {
      await controller.releasePreview(file);
      return;
    }
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
    if (controller.isLoading) return;
    if (controller.hasActiveTransfers) {
      _message('有任务正在传输，请完成或取消后再更改连接');
      return;
    }
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
    var selectedQuickSaveDirectory = controller.defaultQuickSaveDirectory;
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
                        labelText: '本地仓库路径',
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
                  if (!Platform.isAndroid) ...[
                    const SizedBox(height: 18),
                    Align(
                      alignment: Alignment.centerLeft,
                      child: Text(
                        '快传接收默认保存目录',
                        style: Theme.of(context).textTheme.titleSmall,
                      ),
                    ),
                    const SizedBox(height: 6),
                    Align(
                      alignment: Alignment.centerLeft,
                      child: Text(
                        selectedQuickSaveDirectory ?? '尚未设置',
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    if (controller.photoTransferError case final warning?) ...[
                      const SizedBox(height: 6),
                      Align(
                        alignment: Alignment.centerLeft,
                        child: Text(
                          warning,
                          style: TextStyle(
                            color: Theme.of(context).colorScheme.error,
                          ),
                        ),
                      ),
                    ],
                    const SizedBox(height: 8),
                    Align(
                      alignment: Alignment.centerLeft,
                      child: OutlinedButton.icon(
                        onPressed: () async {
                          final path = await getDirectoryPath();
                          if (path != null && context.mounted) {
                            setDialogState(
                              () => selectedQuickSaveDirectory = path,
                            );
                          }
                        },
                        icon: const Icon(Icons.folder_open_outlined),
                        label: const Text('选择目录'),
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
    try {
      if (!Platform.isAndroid &&
          selectedQuickSaveDirectory != controller.defaultQuickSaveDirectory) {
        if (selectedQuickSaveDirectory == null) {
          throw StateError('请选择快传接收默认保存目录。');
        }
        await controller.setDefaultQuickSaveDirectory(
          selectedQuickSaveDirectory!,
        );
      }
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
    } catch (exception) {
      if (mounted) _message(controller.describeError(exception));
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
                    ? InteractiveViewer(
                        child: Center(
                          child: Image.file(
                            file,
                            cacheWidth:
                                (MediaQuery.sizeOf(context).width *
                                        MediaQuery.devicePixelRatioOf(context))
                                    .round()
                                    .clamp(800, 4096),
                            errorBuilder: (_, _, _) => const Text('图片无法预览'),
                          ),
                        ),
                      )
                    : FutureBuilder<String>(
                        future: _readText(file),
                        builder: (context, snapshot) => SingleChildScrollView(
                          child: SelectableText(
                            snapshot.hasError
                                ? '无法预览：文件不是有效文本或已损坏。'
                                : snapshot.data ?? '正在读取...',
                          ),
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

bool _isImage(String name) => isPreviewImageFileName(name);

class _QuickFileSelection {
  const _QuickFileSelection({
    required this.file,
    required this.name,
    required this.mimeType,
  });

  final File file;
  final String name;
  final String mimeType;
}

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
    }.contains(fileExtension(name));
IconData _fileIcon(String name) => _isImage(name)
    ? Icons.image_outlined
    : isAudioFileName(name)
    ? Icons.audio_file_outlined
    : isVideoFileName(name)
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
  TransferStatus.finalizing => '正在完成',
  TransferStatus.completed => '已完成',
  TransferStatus.failed => '失败',
  TransferStatus.cancelled => '已取消',
};
