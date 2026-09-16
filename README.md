# Jet2Drop

Jet2Drop is a private file workspace for Windows, macOS, and Android. It lets devices in your own Tailnet browse, transfer, and manage files securely.

## Overview

Windows runs the central SFTPGo repository. macOS can optionally keep a local repository copy for offline work and explicit pull/push synchronization. Previously discovered Jet2Drop devices are stored locally and probed directly before a transfer; the app does not depend on an undocumented Tailscale device-list API.

Quick Transfer offers two clear routes:

- **Direct transfer** is the default. Any file is streamed directly to an online Windows or macOS receiver, verified with SHA-256, written to a temporary `.part` file, then atomically finalized. It supports cancel and retry, but intentionally does not support pause or resume.
- **Reliable relay** temporarily stores the file in the Windows/SFTPGo quick-transfer area. The recipient may collect it later; pause, resume, recovery after restart, retry, and cleanup are supported.

Android can send files and receive reliable-relay transfers. It is not yet a direct-transfer receiver, so transfers addressed to Android use reliable relay.

## Requirements

- All devices must join the same Tailnet.
- Windows 10/11: Tailscale, SFTPGo, and Jet2Drop. Windows can receive direct transfers.
- macOS 12 or later: Tailscale and Jet2Drop. macOS can receive direct transfers and optionally maintain a local repository copy.
- Android 8.0 (API 24) or later: Tailscale and Jet2Drop.
- Repository browsing and reliable relay require Windows/SFTPGo to be online. Direct transfer between compatible online devices does not.

## First connection

1. Connect the devices to Tailscale. For repository access or reliable relay, ensure that the Windows host and SFTPGo are running.
2. Open **Connection settings** in Jet2Drop.
3. Choose **SFTPGo** and enter the Windows Tailscale IP address or MagicDNS host name, SFTP port, user name, password, and host-key fingerprint.
4. On Windows or macOS, choose a default quick-transfer save directory when the device will receive direct transfers.
5. Select **Save and connect**.

Passwords and other credentials belong only in system secure storage. Do not place them in the repository or commit them to Git. Before an official release, the application version remains `0.0.0+0`.

---

## 中文说明

Jet2Drop 是一个面向个人设备的三端文件仓库客户端，用于在 Windows、macOS 和 Android 之间浏览、传输和管理文件。

Windows 电脑保存实际仓库并运行 SFTPGo，三端通过同一个 Tailscale 私有网络互联。macOS 可选择一个副本仓库目录，离线浏览和修改仓库内容，再手动“拉取更新”或“推送更新”；Windows/SFTPGo 仍是唯一中心仓库。快传发送页提供一行两个四字选项“直连快传 / 可靠中转”，默认选择直连：直连支持任意文件，但接收端必须在线；可靠中转使用 Windows/SFTPGo 暂存，支持离线领取、暂停、续传和恢复。第一阶段 Android 暂不作为直连接收端，因此发往 Android 只显示“可靠中转”；Windows 和 macOS 可以接收直连，Windows、macOS、Android 三端均可发送。

设备列表不依赖 Tailscale 未公开的跨应用设备列表。Jet2Drop 会自动持久化已经发现的 Jet2Drop 设备，并在发送前直接探测目标的接收服务；不使用二维码。设计和行为说明以当前真实实现为准。

### 运行环境

- Windows 10/11：运行 Tailscale、SFTPGo 和 Jet2Drop，可作为直连接收端。
- macOS 12 或更高：运行 Tailscale 和 Jet2Drop，可作为直连接收端，也可保存完整副本仓库。
- Android 8.0（API 24）或更高：运行 Tailscale 和 Jet2Drop；第一阶段只能作为可靠中转的接收端，仍可发送文件。
- 需要加入同一个 Tailnet。Android→Mac 的直连不依赖 Windows 在线；仓库和可靠中转仍依赖 Windows/SFTPGo。

详细功能和行为以当前实现为准。未正式发布前，应用版本保持 `0.0.0+0`。

### 首次连接

1. 确认客户端设备已连接 Tailscale；需要浏览仓库或使用可靠中转时，再确认 Windows 已启动且 SFTPGo 正常运行。
2. 打开 Jet2Drop，进入“连接设置”。
3. 选择 `SFTPGo`，填写 Windows 的 Tailscale IP 或 MagicDNS 主机名、SFTP 端口、用户名、密码和主机密钥指纹。
4. Windows 或 macOS 作为直连接收端时，在设置中选择快传默认保存目录。
5. 点击“保存并连接”。

密码等敏感信息只应存入系统安全存储，不要写入仓库或提交到 Git。

### 基本使用

- “仓库”页用于浏览目录、排序、刷新、上传、下载、预览和文件管理。
- macOS 选择“副本仓库”后，仓库页浏览的是所选本地目录；网络可用时可手动拉取远端更新，完成本地修改后可手动推送。双方同时修改同一路径时会显示冲突，需处理后重试，不会静默覆盖；同步目录权限会在重启后恢复。
- Windows 和 macOS 支持从资源管理器或 Finder 拖入文件上传。
- “快传”页先选择目标设备和文件，再在同一行选择“直连快传 / 可靠中转”；默认是“直连快传”。直连发送任意文件，目标 Windows/macOS Jet2Drop 必须在线，传输可取消，失败只能从头重试，不支持暂停、断点或重启恢复，也不会自动改走中转。接收时使用 `.part`、SHA-256 校验和原子改名。
- “可靠中转”在 Windows/SFTPGo 可达时将文件暂存到独立快传区，接收端可以离线领取，并支持暂停、续传和重启恢复。若开始前确认 Windows/SFTPGo 不可达，则对支持直连且在线的目标自动切换直连；链路一旦开始就不再切换。发往 Android 第一阶段只显示“可靠中转”。
- “任务”页按传输链路显示进度和可用操作：直连支持取消与失败重试，中转支持暂停、继续、取消、续传恢复、重试和清理。
- 普通仓库下载由用户选择保存位置；桌面端快传接收使用已记忆的默认保存目录，Android 领取可靠中转使用 Android 系统文件选择器。
