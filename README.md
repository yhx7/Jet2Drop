# Jet2Drop

Jet2Drop 是一个面向个人设备的三端文件仓库客户端，用于在 Windows、macOS 和 Android 之间浏览、传输和管理文件。

Windows 电脑保存实际仓库并运行 SFTPGo；三端通过同一个 Tailscale 私有网络互联。普通文件通过 SFTP 和 Windows 仓库可靠中转，照片可以在目标桌面端在线时直接传入其默认保存目录。

## 运行环境

- Windows 10/11：运行 Tailscale、SFTPGo 和 Jet2Drop。
- macOS 12 或更高：运行 Tailscale 和 Jet2Drop。
- Android 8.0（API 24）或更高：运行 Tailscale 和 Jet2Drop。
- 三台设备需加入同一个 Tailnet。

需求目标和部署背景见 [Jet2Drop 项目需求与开发方案.md](Jet2Drop%20项目需求与开发方案.md)；详细设计和功能行为以当前真实实现为准。

## 首次连接

1. 确认 Windows 已启动 Tailscale 和 SFTPGo，客户端设备也已连接 Tailscale。
2. 打开 Jet2Drop，进入“连接设置”。
3. 选择 `SFTPGo`，填写 Windows 的 Tailscale IP 或 MagicDNS 主机名、SFTP 端口、用户名、密码和主机密钥指纹。
4. 桌面端选择快传默认保存目录。
5. 点击“保存并连接”。

密码等敏感信息只应存入系统安全存储，不要写入仓库或提交到 Git。

## 基本使用

- “仓库”页用于浏览目录、排序、刷新、上传、下载、预览和文件管理。
- Windows 和 macOS 支持从资源管理器或 Finder 拖入文件上传。
- “快传”页选择在线设备并发送文件。照片直传要求目标桌面应用在线；其他文件可由接收端稍后领取。
- “任务”页可查看进度，并对支持的任务执行暂停、继续、取消、重试和清理。
- 普通仓库下载由用户选择保存位置；快传领取和照片接收使用桌面端记忆的默认保存目录。

## 开发与构建

项目使用 Flutter。提交前运行：

```bash
flutter pub get
flutter analyze
flutter test
```

构建对应平台的 Release：

```bash
flutter build macos --release
flutter build windows --release
flutter build apk --release
```

Windows 可在项目目录运行 `powershell -ExecutionPolicy Bypass -File .\tools\deploy_windows.ps1` 完成构建和部署；仅部署已有构建时追加 `-SkipBuild`。

未正式发布前，应用版本保持 `0.0.0+0`。
