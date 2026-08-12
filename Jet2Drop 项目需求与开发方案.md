# Jet2Drop 项目需求与开发方案

> 文档状态：可执行基线方案  
> 更新日期：2026-08-08（官方资料复核）  
> 应用名称：Jet2Drop

## 1. 结论

本项目可按以下链路落地，不依赖付费云盘，也不要求将文件上传给第三方存储服务：

```text
Windows 常开电脑
├── E:\Repository                   实际文件仓库，可被 Windows 直接编辑
├── SFTPGo Community               SFTP 文件服务，作为 Windows 服务运行
└── Tailscale                      提供跨网络的私有连接
                 │
                 │ Tailscale 私有网络 + SFTP
                 │
       ┌─────────┼─────────┐
       │         │         │
   Windows     macOS     Android 16
   Flutter     Flutter    Flutter
   客户端       客户端      客户端
```

平台条件已经与官方资料核对：

- 当前 Windows 主机为 Windows NT 10.0.26200、x64，满足 Flutter、Tailscale、SFTPGo 和 Rclone 的要求。
- MacBook Air M5 属于 Apple Silicon，使用 ARM64 构建；当前 Rclone 提供 macOS ARM64 版本。
- Android 16 对应 API 36，位于 Flutter 官方支持的 Android API 24～37 范围内。
- 当前 Tailscale macOS 客户端要求 macOS 12 或更高；M5 MacBook Air 满足要求。
- Rclone 当前版本要求 macOS 12 或更高，因此项目将 macOS 最低版本明确设为 12。

2026-08-08 再次联网复核后的结论是：**基础版不存在已知的平台或组件阻断项，可以进入三端最小原型开发。** Flutter 官方支持 Android API 24～37、Windows 10/11、macOS x64/ARM64；Tailscale 官方支持 Android 8.0+、macOS 12+ 和 Windows；SFTPGo 官方 Windows 安装器会注册并运行 Windows 服务；Rclone 官方同时提供 macOS ARM64 包、SFTP 后端和 Bisync。上述范围均覆盖本项目的 Windows x64、MacBook Air M5 和 Android 16。

需要说明：官方平台支持只能证明设计成立，不能替代真机集成测试。项目必须先完成第 15 节的“三端最小贯通原型”，通过后才能投入完整界面开发。

本方案**不要求三台设备处于同一局域网**。Windows 可以在家中有线网络，Mac 可以在其他地点的 Wi-Fi，Android 可以使用 4G/5G；只要设备能访问互联网、已登录同一个 Tailscale 私有网络（Tailnet），就能按 Tailscale 分配的私有地址连接。Tailscale 会优先建立点对点连接，受 NAT 或防火墙限制时自动改走其加密 DERP 中继。是否同一局域网只影响可能达到的速度，不决定功能是否可用。

浏览中心仓库、普通上传下载和中转式快传依赖 Windows，因此这些功能要求 Windows 开机、未睡眠、Tailscale 在线且 SFTPGo 服务正常。双方同时在线的媒体直连快传不经过 Windows，即使 Windows 暂时离线仍可发送；若直连失败，则必须等待 Windows 恢复后才能回退中转。

## 2. 项目需求

### 2.1 项目目标

开发一个自用、三端风格统一的文件仓库客户端 Jet2Drop，用于在 Windows、macOS 和 Android 之间访问自己的文件。

文件实际存储在 Windows 常开电脑的普通目录中。Windows 可以直接使用资源管理器、Office、编辑器等程序修改实际仓库；macOS 可以维护完整本地副本并与 Windows 仓库同步；Android 只进行远程浏览和单文件传输。

目标文件主要包括：

- PPT、PPTX
- DOC、DOCX
- PDF
- 代码、Markdown 和普通文本
- JPEG、PNG、WebP、GIF、BMP 等图片
- MP3、M4A、WAV、FLAC 等音频
- MP4、MOV、MKV、WebM、AVI 等视频
- 其他一般体积的资料文件

### 2.2 设备角色

#### Windows 常开电脑

- 保存唯一的实际远程仓库 `E:\Repository`。
- 仓库保持普通文件目录，不转换为私有分块格式。
- Windows 用户可以绕过客户端，直接在仓库中修改文件。
- 运行 SFTPGo Community，并在开机后作为 Windows 服务自动启动。
- 运行 Tailscale，对 macOS 和 Android 提供跨网络连接。
- 运行统一 Flutter 客户端，以与其他平台相同的界面浏览和管理仓库。
- Windows 客户端使用本地仓库适配器直接访问实际目录，不经过本机回环 SFTP。

#### macOS（MacBook Air M5）

- 运行 Apple Silicon ARM64 版统一客户端。
- 可以浏览远程仓库并上传、下载单个文件。
- 支持从 Finder 拖拽文件到客户端上传。
- 可以选择一个完整本地仓库目录，例如 `~/Documents/DocumentRepository`。
- 使用随客户端打包的 Rclone ARM64 版完成整仓增量同步。
- Windows 和 macOS 同时修改同一文件时，不静默覆盖，保留冲突副本。

#### Android 16

- 浏览完整远程目录结构和文件列表。
- 上传单个或多个选定文件。
- 下载单个选定文件，并通过 Android 系统文件选择器决定保存位置。
- 打开已经下载的文件。
- 不维护完整仓库副本。
- 不运行 Rclone，不提供整仓同步或强制覆盖功能。

### 2.3 三端公共功能

首期三端统一提供：

1. 服务器连接配置和连接测试。
2. 目录树或层级导航、面包屑路径和返回上级。
3. 文件列表，显示名称、类型、大小和修改时间。
4. 按名称、类型、大小和修改时间排序。
5. 当前目录刷新。
6. 单文件和多文件上传。
7. 单文件下载。
8. 上传、下载进度，取消和失败重试。
9. 同名文件处理：取消、覆盖、保留两份。
10. 传输任务面板和本次运行的传输记录。
11. 浅色、深色主题以及自定义本地背景图。
12. 一致的按钮、图标、间距、状态和错误提示。
13. 设备间快传：选择目标设备和文件后发送；图片、音频、视频优先使用 Tailscale 直连，普通文件默认使用 Windows 中转。
14. 快传收件箱、有效期、接收进度、完整性校验和清理状态。
15. 图片、音频和视频快传按原始字节传输，不自动压缩、缩放、转码或以预览内容替代原文件，并以速度为首要指标。

### 2.4 桌面端附加功能

- 使用系统文件窗口选择上传文件。
- 从 Windows 资源管理器或 macOS Finder 拖拽文件到当前目录上传。
- 拖入时显示明确的目标目录和投放状态。
- 选择本地保存位置下载文件。
- 导出整个仓库到指定本地目录。
- 从指定本地目录导入整个仓库。
- macOS 提供完整仓库的增量双向同步。
- 高风险的“以本地覆盖远端”和“以远端覆盖本地”操作必须先预览差异并二次确认。

### 2.5 图片支持

首期图片能力分为三部分：

1. **文件传输**：任何图片格式都可以作为普通文件上传和下载。
2. **低成本预览**：使用 Flutter 内置图片解码能力预览 JPEG、PNG、WebP、GIF 和 BMP。
3. **界面背景**：用户可以从本机选择背景图片，设置适配方式、遮罩和透明度。

远程文件列表默认只显示图片类型图标，不为整个目录自动下载原图生成缩略图。用户打开图片后，客户端将其下载到应用缓存并预览；已经缓存的图片可以显示缩略图。这样可以避免 Android 浏览目录时消耗大量流量。

### 2.6 首期低成本预览范围

首期重点是传输，不开发重型预览引擎。仅实现：

- JPEG、PNG、WebP、GIF、BMP：Flutter 内置图片预览。
- TXT、MD、JSON、YAML、CSV 和常见代码文件：限制大小的 UTF-8 只读文本预览，建议上限 1 MB。

以下文件首期只显示图标和元数据，下载后调用系统应用打开：

- PPT、PPTX
- DOC、DOCX
- PDF
- MP3、M4A、WAV、FLAC 等音频
- MP4、MOV、MKV、WebM、AVI 等视频
- 压缩包和未知二进制文件

### 2.7 分阶段原则

完整需求不会因为首期暂缓而被取消。开发顺序遵循“先实现成熟、容易验证、不容易造成数据损坏的功能，再增加高风险能力”：

#### 第一批：低风险基础功能

- 三端连接、目录浏览和刷新。
- 单文件/多文件上传和单文件下载。
- 系统文件选择器和桌面拖拽上传。
- 传输进度、取消、失败重试和临时文件保护。
- 同名文件确认和保留两份。
- 常见图片与小型UTF-8文本预览。
- 浅色/深色主题、自定义背景和按钮样式。
- 通过 Windows 中转的普通文件快传；接收方不必与发送方同时在线。
- 图片、音频和视频快传优先尝试设备间 Tailscale 直连，直连失败自动回退 Windows 中转；预览或播放只在传输完成后进行，绝不参与传输链路。

#### 第二批：基础链路稳定后加入

- 远程新建目录、重命名和移动。
- 移入回收区代替直接删除。
- macOS整仓增量同步和冲突副本。
- 整仓导入、导出和差异预览。
- “以本地为准”与“以远端为准”的受保护覆盖。

#### 后续增强

- 后台自动同步、普通小文件断点续传和计划任务。
- PDF首屏或完整预览、HEIC/HEIF统一预览。
- 文件历史浏览、搜索、收藏和最近访问。
- 公开分享、多人协作或在线编辑等扩展能力。
- 将已经用于媒体的 Tailscale 直连快传扩展到文档、代码和压缩包。

Android整仓同步不属于当前目标；PPT、DOC、PDF等二进制文件也无法自动内容合并。SFTPGo WebClient只作为管理和故障排查备用，不作为Jet2Drop最终界面。无论开发到哪个阶段，都不直接开放公网端口。

## 3. 核心使用流程

### 3.1 Windows 直接编辑

```text
用户在 E:\Repository 修改文件
→ 文件立即成为仓库当前版本
→ macOS/Android 刷新后看到变化
```

Windows 客户端中的上传操作，本质是将外部文件安全复制到仓库当前目录；下载操作是将仓库文件导出到用户指定位置。

### 3.2 macOS 单文件操作

```text
打开客户端
→ 通过 Tailscale 连接 Windows 的 SFTPGo
→ 浏览远程目录
→ 选择或拖入文件上传
→ 选择远程文件单独下载
```

### 3.3 macOS 整仓工作流

推荐的正常流程是双向同步，而不是无条件覆盖：

```text
开始工作前
→ 检查远端和本地变化
→ 执行安全双向同步
→ 在 Mac 本地仓库工作
→ 工作结束再次检查
→ 执行安全双向同步
```

客户端另外提供两个高级操作：

- **以远端为准**：让本地目录与 Windows 仓库完全一致。
- **以本地为准**：让 Windows 仓库与 macOS 本地目录完全一致。

高级操作可能覆盖和删除文件，必须满足：

1. 先生成差异清单。
2. 明确列出新增、覆盖、删除数量。
3. 默认不勾选删除。
4. 用户再次确认后才能执行。
5. 被覆盖或删除的目标端文件先移入带时间戳的备份目录。

### 3.4 Android 单文件操作

```text
打开客户端
→ 浏览仓库
→ 选择文件
→ 下载
→ Android ACTION_CREATE_DOCUMENT
→ 用户选择保存位置
```

上传使用 Android 系统 `ACTION_OPEN_DOCUMENT`/Flutter 文件选择器，不请求整块共享存储权限。

### 3.5 三端快传

基础版快传包含两条路径：普通文件和离线领取复用 Tailscale + SFTP，由 Windows 暂存；图片、音频和视频在双方在线时优先直连。Windows 中转流程如下：

```text
发送端选择目标设备和文件
→ 文件逐个上传到 Windows 快传区并使用 .part 后缀
→ 计算并记录 SHA-256
→ 所有文件完成后最后写入 manifest.ready.json
→ 接收端上线后读取自己的收件箱
→ 用户选择保存位置并下载
→ 校验大小和 SHA-256
→ 写入 acknowledgement.json，等待服务端清理
```

这不是“把文件加入正式仓库”：快传文件位于独立的 `D:\Jet2DropTransfer`，不会出现在文档仓库、整仓同步或仓库搜索中。发送方和接收方不必同时在线，只需 Windows 在两次操作期间保持在线。Windows 自己作为发送端或接收端时仍走同一任务协议，但可以用本地文件适配器完成数据复制。

媒体快传与普通文件使用相同的可靠传输语义：发送端读取原始文件流，服务端只做字节存储，接收端再写出原始字节。不会因为扩展名是 JPG、MP3 或 MP4 而进入压缩或转换分支；图片预览和音视频播放都是接收完成后的独立 UI 操作。

媒体快传的首选路径是：两端应用同时在线时，接收端在 Tailscale 私网地址上启动临时 HTTP 接收器，发送端通过二维码或一次性令牌连接；Tailscale 不转发局域网广播/多播发现，因此设备信息由 Jet2Drop 配对资料或二维码提供。Android 接收媒体时启动 `dataSync` 前台服务和常驻通知，确保切到后台仍能完成传输。目标设备离线、令牌握手失败或直连超时后，任务自动改用 Windows 中转，不丢失发送任务。

## 4. 总体技术架构

```text
┌──────────────── Windows 主机 ────────────────┐
│                                               │
│ E:\Repository                                 │
│        ▲                                      │
│        │ 本地文件系统                          │
│  SFTPGo Community ── SFTP 端口（仅 Tailnet）  │
│        ├── 仓库根目录                          │
│        └── /__jet2drop_transfer 虚拟目录       │
│                ↕ D:\Jet2DropTransfer          │
│        │                                      │
│  Tailscale Windows 客户端                     │
└────────┼──────────────────────────────────────┘
         │ Tailscale WireGuard 私有网络
         │ SFTP 自身再次加密
   ┌─────┴───────────────┐
   │                     │
macOS Flutter        Android Flutter
├─ dartssh2          ├─ dartssh2
├─ desktop_drop      ├─ file_selector
├─ file_selector     ├─ Kotlin SAF 桥接
└─ Rclone ARM64      └─ 应用缓存
```

媒体快传另有一条优先使用的短时直连通道：发送端和接收端通过 Tailscale 私网地址建立带一次性令牌的 HTTP 流；直连不可用时，任务回退到上图的 SFTPGo 中转通道。该通道不改变正式仓库内容，也不监听公网地址。

### 4.1 为什么使用 SFTP，而不是 WebDAV

- SFTPGo 的核心协议是 SFTP，Windows 服务端支持成熟。
- SFTP 自带加密，不需要为应用层处理 HTTPS 证书续期。
- 避免 Android 明文 HTTP 限制。
- 避免 WebDAV 在反向代理后因 Host 头导致 COPY/MOVE 失败的已知注意事项。
- `dartssh2` 是纯 Dart SSH/SFTP 客户端，当前明确列出 Windows、macOS 和 Android。
- Rclone 官方提供 SFTP 后端，因此单文件操作和整仓同步可以使用同一服务端协议。

### 4.2 为什么仍然需要 Tailscale

SFTP 负责文件协议和传输加密；Tailscale 负责让不同网络中的设备发现并连接 Windows 主机。

Tailscale 带来的实际价值：

- 不需要家庭公网 IPv4。
- 不需要路由器端口映射。
- SFTPGo 端口只允许 Tailnet 设备访问。
- 设备丢失后可以在 Tailscale 管理页撤销。
- 文件仍保存在自己的 Windows 硬盘，Tailscale 不提供文件存储。

跨网络连接的边界条件如下：

- 不要求公网 IPv4、固定 IP、同一 Wi-Fi 或路由器控制权。
- 三端必须登录同一 Tailnet，或者由 Tailnet ACL/Grants 明确允许互访。
- 客户端优先保存 Windows 的 MagicDNS 名称，例如 `jet2drop-win.<tailnet>.ts.net`；MagicDNS 异常时可改用 `100.x.y.z` Tailscale IPv4。
- Tailscale 显示 `direct` 时通常性能最好；显示 `relay`/DERP 时仍可用，但大文件速度受双方上行带宽和中继路径限制。
- 不将 SFTPGo 的 2022 端口映射到公网；Tailscale 退出或 Windows 睡眠后远端不可访问属于预期状态。

## 5. 技术组件与兼容性

截至 2026-08-08 的开发基线固定如下。开发期间先锁定版本，升级依赖时重新执行第 15 节门禁：

| 组件 | 固定基线 | 核验结果 |
|---|---:|---|
| Flutter stable | 3.44.9 | 2026-08-06 官方 stable；官方目标覆盖三端 |
| Dart | 随 Flutter 3.44.9 | 使用 SDK 内置版本，不单独混装或升级 |
| SFTPGo Community | 2.7.5 | Windows x64，可作为 Windows 服务运行 |
| Rclone | 1.75.0 | 提供 Windows x64、macOS ARM64；macOS 12+ |
| `dartssh2` | 2.22.5 | 三端共享 SFTP 实现 |
| `file_selector` | 1.1.0 | 三端选取文件；Android 保存另用 SAF |
| `desktop_drop` | 0.7.1 | Windows/macOS 文件拖入 |
| `path_provider` | 2.1.6 | 三端应用目录和缓存目录 |
| `flutter_secure_storage` | 10.3.1 | 固定基线；官方仍提供且 SDK 约束兼容三端 |
| `shared_preferences` | 2.5.5 | 非敏感界面设置 |

| 组件 | 用途 | 目标平台 | 当前结论 |
|---|---|---|---|
| Flutter | 统一客户端 UI | Windows、macOS、Android | 官方支持目标版本 |
| SFTPGo Community | Windows 文件服务器 | Windows | 官方安装器可注册为 Windows 服务 |
| Tailscale | 私有跨网络连接 | 三端 | 三端均有官方客户端 |
| dartssh2 | SFTP 客户端 | 三端 | 纯 Dart，支持 SFTP v3 文件操作 |
| file_selector | 系统文件选择 | 三端 | Flutter 团队维护；Android 不支持选择保存位置 |
| Android SAF | Android 下载保存 | Android | 使用系统 ACTION_CREATE_DOCUMENT |
| desktop_drop | Finder/资源管理器拖拽 | Windows、macOS | pub.dev 当前明确支持 |
| Rclone Bisync | 整仓增量同步 | macOS；Windows 可用于导入导出 | 官方支持 macOS ARM64、Windows x64 和 SFTP |
| path_provider | 缓存和本地设置目录 | 三端 | Flutter 团队维护 |
| flutter_secure_storage | 凭据存储 | 三端 | 当前包列出三端支持，须经真机门禁验证 |

关键限制：

- 当前 Rclone 要求 macOS 12 或更高。
- Flutter 的 Android 最低支持 API 24；项目直接采用该下限。
- Android `file_selector` 不能选择下载保存位置，必须使用小型 Kotlin 平台通道调用 SAF。
- `dartssh2`、`desktop_drop` 和 `flutter_secure_storage` 不是 Flutter SDK 内置组件，应通过接口封装，避免业务层直接依赖。
- macOS App Sandbox 可能影响 Finder 拖入文件。首期为自用、非 Mac App Store 分发，并将拖拽权限列入最小原型门禁。
- `flutter_secure_storage` 最新正式版已是 11.0.0，但发布时间很短且属于新的主版本。V0.1 不为追新而升级，继续锁定 10.3.1；它的官方元数据支持 Android、macOS、Windows，要求 Dart >=3.3、Flutter >=3.19，均被 Flutter 3.44.9 满足。升级 11.x 必须单独做凭据迁移和三端回归测试。

### 5.1 需求到官方能力的复核结果

| Jet2Drop 需求 | 官方依据和实际边界 | 结论 |
|---|---|---|
| 不同局域网访问 | Tailscale 官方说明 Tailnet 有直连、DERP 中继和 Peer Relay 三种连接，全部 WireGuard 端到端加密；差别主要是性能 | 可实现，不要求同一 Wi-Fi 或公网 IP |
| Windows 常开仓库服务 | SFTPGo 官方 Windows 安装器/winget 包会注册并运行 Windows 服务，SQLite 可作为内嵌数据提供者 | 可实现，Windows 重启后自动运行 |
| 仓库外独立快传区 | SFTPGo 官方虚拟目录可把用户主目录外的 `C:\mapped`/本地路径映射成指定虚拟路径，同一虚拟目录可共享给多个用户 | 可实现 `/__jet2drop_transfer` |
| 三端统一客户端 | Flutter 官方支持 Android API 24～37、Windows 10/11 x64/ARM64、macOS 10.15～26 x64/ARM64 | 覆盖 Windows x64、M5 ARM64、Android 16/API 36 |
| 浏览和单文件传输 | `dartssh2` 2.22.5 官方示例包含 `listdir`、流式 download、流式 upload、mkdir/rmdir/stat，包页列出 Android/macOS/Windows | 可实现目录浏览、上传、下载、进度和取消 |
| SSH 主机密钥固定 | `dartssh2` 官方源码公开 `onVerifyHostKey` 回调；Rclone 官方支持 `known_hosts_file`/host key pinning | 可实现首次配对和后续阻止指纹变化 |
| 桌面选文件和拖入 | Flutter 官方 `file_selector` 支持 Windows/macOS 选文件；`desktop_drop` 0.7.1 插件元数据声明 Windows/macOS 原生实现 | 可实现点击选择和 Finder/资源管理器拖入；真机验证权限 |
| Android 上传 | `file_selector` 1.1.0 支持 Android 单选/多选文件，最低 Android SDK 21 | 可实现，项目最低 API 24 更高 |
| Android 指定位置下载 | `file_selector` 官方功能矩阵明确 Android 不支持“Choose a save location”；Android 官方 SAF 提供 `ACTION_CREATE_DOCUMENT`，且不需要系统存储权限 | 必须保留 Kotlin 平台通道；可实现单文件另存为 |
| 图片预览 | Flutter `instantiateImageCodec` 官方列出 JPEG、PNG、GIF/动图、WebP/动图、BMP、WBMP | 首期列出的图片格式可实现 |
| 凭据安全存储 | `flutter_secure_storage` 10.3.1 官方元数据声明 Android、macOS、Windows；Android 使用加密存储、macOS 使用 Keychain、Windows 使用平台后端 | 可实现，三端必须做读写/升级回归 |
| Mac 整仓同步 | Rclone 1.75.0 官方下载提供 macOS ARM64，SFTP 后端允许 `shell_type = none`，Bisync 提供 resync、访问检查、删除限制、冲突和备份参数 | 可实现，但属于 Gate B 高风险功能，不能跳过真机冲突测试 |
| 三端快传 | 普通文件使用已验证的 SFTP 中转；图片、音频、视频优先使用 Tailscale 内一次性令牌 HTTP 直连，失败回退中转；两者共用清单、临时文件和 SHA-256 | 基础版可实现；直连要求双方在线，普通中转可延迟领取 |
| 主题、背景和统一按钮 | Flutter 三端共享 Widget、Theme、ButtonStyle 和图片渲染层 | 可实现，属于应用 UI，不依赖服务端能力 |

复核没有发现“官方明确不支持而方案却依赖”的环节。仍不能用文档代替真机验证的部分只有：第三方插件在本项目组合下的运行质量、macOS 拖放/entitlement、Android Activity 重建与 SAF URI、长时间网络切换，以及 Rclone Bisync 的数据安全。这些已经分别被 Gate A 和 Gate B 阻断在完整功能开发之前；Gate A 失败时不得继续堆叠 UI，Gate B 失败只暂停整仓同步，不影响基础仓库和快传。

## 6. Windows 服务端方案

### 6.1 建议目录

```text
E:\Repository\                       实际仓库
├── .jet2drop-history\                覆盖历史，客户端默认隐藏且不同步
└── <用户文件与目录>
D:\Jet2DropServer\
└── backups\                          导出的 SFTPGo 配置/数据库备份
D:\Jet2DropHistoryBackup\            Windows维护任务保存的仓库外备份
D:\Jet2DropTransfer\
├── inbox\<目标device-id>\<transfer-id>\
│   ├── files\                         完成后的待领取文件
│   ├── manifest.ready.json            就绪标志，最后原子发布
│   └── acknowledgement.json           接收结果
└── quarantine\                        异常或过期任务隔离区
```

SFTP客户端只能在被授权的仓库根目录内操作，因此单文件覆盖历史暂存在 `.jet2drop-history`。该目录必须同时满足：客户端文件列表默认隐藏、Rclone过滤、禁止用户上传同名顶层目录。Windows维护任务再将历史复制到仓库外的 `D:\Jet2DropHistoryBackup`。这样既能完成安全替换，又不会让历史备份进入macOS工作副本。快传目录作为 SFTPGo 虚拟目录挂载到 `/__jet2drop_transfer`，UI 和 Rclone 过滤该保留路径。

### 6.2 SFTPGo 配置原则

- 使用 Community Edition。
- 通过官方 Windows Installer 或 `winget install -e --id drakkan.SFTPGo` 安装。
- 注册为 Windows 服务并设置自动启动。
- 使用 SQLite 数据提供者，满足单人场景，避免部署外部数据库。
- 创建日常文件用户，不使用管理员账号传输文件。
- 用户主目录指向 `E:\Repository`。
- 为每个用户挂载同一个虚拟目录：虚拟路径 `/__jet2drop_transfer`，实际路径 `D:\Jet2DropTransfer`。
- 为 Windows、macOS、Android 分配独立凭据，便于单独撤销。
- SFTP 监听端口使用非冲突端口，例如 2022。
- 端口只绑定 Tailscale 地址，或通过 Windows 防火墙仅允许 Tailscale 接口/地址段。
- SFTPGo WebAdmin 只允许本机访问。
- 不启用公网 FTP，不做路由器端口映射。

### 6.3 主机密钥与首次配对

客户端不能无条件接受服务器主机密钥。首次配对流程：

1. Windows 客户端读取 SFTPGo 主机密钥指纹。
2. 显示指纹和一次性配对二维码。
3. macOS/Android 扫码或手动输入连接信息。
4. 客户端保存指纹。
5. 后续连接发现指纹变化时立即阻止连接并提示。

连接信息至少包含：

- Tailscale MagicDNS 名称或 Tailscale IP
- SFTP 端口
- 用户名
- SSH 主机密钥指纹
- 可选的初始一次性密码

密码保存在系统安全存储中，不写入日志或普通配置文件。

## 7. Flutter 客户端设计

### 7.1 统一代码与平台适配

应用采用“共享业务层 + 平台适配器”结构：

```text
UI / 状态管理
       │
文件仓库用例层
       │
RepositoryGateway 接口
├── LocalRepositoryGateway        Windows 本地实际仓库
└── SftpRepositoryGateway         macOS / Android 远程仓库
       │
平台能力接口
├── FilePickerAdapter
├── SaveFileAdapter
├── DragDropAdapter
├── SecureStorageAdapter
├── WholeRepositorySyncAdapter
└── DeviceIdentityAdapter
```

这样可以在不改 UI 和业务逻辑的情况下替换第三方插件。

### 7.2 建议模块目录

```text
lib/
├── app/
│   ├── router/
│   ├── theme/
│   └── app.dart
├── core/
│   ├── errors/
│   ├── logging/
│   ├── platform/
│   └── security/
├── features/
│   ├── connection/
│   ├── browser/
│   ├── transfer/
│   ├── quick_drop/
│   ├── preview/
│   ├── repository_sync/
│   └── settings/
├── infrastructure/
│   ├── local_repository/
│   ├── sftp/
│   ├── rclone/
│   └── persistence/
└── shared/
    ├── models/
    └── widgets/

android/app/src/main/kotlin/.../
└── DocumentSaveChannel.kt

assets/
├── images/
└── defaults/

tool/
├── rclone/macos-arm64/
└── rclone/windows-x64/
```

### 7.3 核心数据模型

```text
ConnectionProfile
├── host
├── port
├── username
├── hostKeyFingerprint
└── deviceId

FileEntry
├── path
├── name
├── type
├── size
├── modifiedAt
└── permissions

TransferTask
├── id
├── direction
├── source
├── destination
├── transferredBytes
├── totalBytes
├── status
└── error

QuickTransferManifest
├── schemaVersion
├── transferId
├── senderDeviceId / senderName
├── targetDeviceId / targetName
├── createdAt / expiresAt
└── files[{relativeName, mimeType, size, sha256, chunkSize, chunks[]}]

QuickTransferReceipt
├── transferId
├── receiverDeviceId
├── receivedAt
├── status
└── files[{relativeName, status, sha256}]

SyncPlan
├── additions
├── modifications
├── deletions
├── conflicts
└── estimatedBytes
```

### 7.4 状态管理

首期选择一个轻量、可测试的单向状态管理方案。业务状态至少拆分为：

- 连接状态
- 当前目录和导航状态
- 文件列表加载状态
- 文件选择状态
- 传输队列状态
- 快传设备、发件箱和收件箱状态
- 预览缓存状态
- 整仓同步状态
- 主题和背景设置

任何网络错误都转换为统一错误模型，UI 不直接展示底层异常堆栈。

## 8. 图形界面方案

### 8.1 桌面布局

```text
┌────────────────────────────────────────────────────┐
│ 工具栏：返回 / 前进 / 刷新 / 上传 / 下载 / 同步     │
├──────────────┬─────────────────────────────────────┤
│ 目录树        │ 面包屑路径                          │
│              ├─────────────────────────────────────┤
│              │ 文件列表                            │
│              │ 名称 | 大小 | 修改时间 | 状态        │
│              │                                     │
├──────────────┴─────────────────────────────────────┤
│ 传输任务：进度 / 速度 / 取消 / 重试                 │
└────────────────────────────────────────────────────┘
```

- 文件界面以高效列表为主，不使用大量装饰卡片。
- 工具操作使用图标按钮，并为不熟悉的图标提供 Tooltip。
- 上传、下载、刷新、返回使用常见图标，不使用纯文字圆角按钮替代熟悉符号。
- 文件行高度和图标尺寸固定，传输进度更新不能造成列表跳动。
- 拖入文件时，整个文件列表区域变为清晰的投放区，显示当前目标路径。
- 左侧导航固定包含“仓库”“快传收件箱”“传输任务”；快传与正式仓库在视觉和路径上明确分开。
- 快传发送窗口先选择目标设备，再支持点击选择或拖入文件，最后显示有效期和总大小。

### 8.2 Android 布局

- 顶部显示当前目录和返回按钮。
- 主体使用单列文件列表。
- 上传使用明确的图标命令入口。
- 文件操作放入底部操作栏或上下文菜单。
- 下载任务显示在固定任务页，不覆盖目录内容。
- 底部导航提供“仓库”“快传”“任务”；快传页显示待领取、正在接收和已完成三种状态。
- 触控目标不小于平台推荐尺寸。

### 8.3 主题和自定义背景

- 默认提供浅色和深色主题。
- 用户可选择本地图片作为背景。
- 背景设置包括：填充、适应、平铺、透明度和遮罩强度。
- 内容区必须有足够对比度，复杂背景不能影响文件名和状态文字阅读。
- 背景图片复制到应用支持目录，避免原图移动后设置失效。
- 背景属于每台设备本地设置，不自动进入文档仓库。
- 按钮通过统一 Theme 和 ButtonStyle 定义默认、悬停、按下、禁用和聚焦状态。

## 9. 单文件传输实现

### 9.1 上传

桌面端入口：

- 点击上传按钮并使用系统文件选择器。
- 从 Finder/资源管理器拖拽单个或多个文件。

Android 入口：

- 使用系统文件选择器选择单个或多个文件。

安全上传流程：

```text
读取源文件
→ 上传到目标目录的临时名称 .jet2drop-upload-<uuid>.part
→ 校验已传输大小
→ 处理同名文件策略
→ 将临时文件重命名为正式文件
→ 刷新目录
```

如果上传失败，正式文件不应被半成品覆盖。临时文件在下次启动或服务端清理任务中删除。

### 9.2 下载

桌面端：

- 使用 `file_selector` 获取保存位置。
- 先写入同目录 `.part` 文件。
- 下载完成并校验大小后重命名为正式文件。

Android：

- Kotlin 平台通道调用 `ACTION_CREATE_DOCUMENT`。
- Flutter 获得 `content://` URI 后，以流式方式写入。
- 不把整个文件一次性载入内存。
- 取消或失败后提示用户删除不完整目标；必要时先下载到应用缓存再提交到目标 URI。
- Android 官方明确规定 `ACTION_CREATE_DOCUMENT` 不覆盖已经存在的文件；同名下载由系统选择器要求用户改名/创建新文档。Jet2Drop 不承诺绕过 SAF 强制覆盖手机上的既有文件。

### 9.3 进度和取消

- 传输按固定大小分块，持续累计已传输字节。
- UI 节流更新进度，避免每个网络包都触发重绘。
- 取消操作关闭当前流并清理临时文件。
- 普通小文件首期失败重试从头开始；大于 32 MiB 的媒体快传按第 10 节分块并支持跨应用重启续传。

### 9.4 覆盖安全

单文件覆盖采用以下顺序：

1. 新文件完整上传为临时文件。
2. 旧文件移动到仓库内受保护的 `.jet2drop-history/<时间>/<原相对路径>`。
3. 临时文件重命名为正式文件。
4. 任一步失败时尽量恢复旧文件。

`.jet2drop-history`不出现在普通文件浏览结果中，也不参与整仓同步。首期将“保留旧版本”设为默认，并提供按保留天数复制和清理历史的Windows维护任务。

## 10. 三端快传实现

### 10.1 设备身份与投递地址

每次安装首次启动时生成随机 UUID 作为 `deviceId`，用户设置易读设备名，例如“Windows 主机”“M5 Mac”“我的手机”。`deviceId` 存在应用支持目录，设备名可修改但 ID 不变。基础版设备列表是配对配置的一部分，并保存在三端本地；不搭建额外账户和推送服务器。

快传投递路径固定为：

```text
/__jet2drop_transfer/inbox/<target-device-id>/<transfer-id>/
```

客户端只把目标为本机 `deviceId` 的任务显示在收件箱。由于这是个人 Tailnet 内的自用系统，该过滤主要用于避免误操作，不被视为不同用户之间的强隔离；如果未来扩展多人使用，必须改为每台设备独立 SFTP 权限和服务端授权。

### 10.2 清单格式

`manifest.ready.json` 使用 UTF-8 JSON，`schemaVersion` 首期固定为 `1`。时间使用 UTC ISO 8601，文件名只允许单层安全文件名，不接受发送端提供的绝对路径或 `..`。示例：

```json
{
  "schemaVersion": 1,
  "transferId": "018f...uuid",
  "senderDeviceId": "win-uuid",
  "senderName": "Windows 主机",
  "targetDeviceId": "android-uuid",
  "targetName": "我的手机",
  "createdAt": "2026-08-08T08:00:00Z",
  "expiresAt": "2026-08-15T08:00:00Z",
  "files": [
    {
      "relativeName": "clip.mp4",
      "mimeType": "video/mp4",
      "size": 381240000,
      "sha256": "...整文件64位十六进制...",
      "chunkSize": 8388608,
      "chunks": [{"index": 0, "size": 8388608, "sha256": "...分块哈希..."}]
    }
  ]
}
```

默认有效期为 7 天，可选 1 天或 30 天。首期限制单任务最多 100 个文件、总计 10 GB；限制写成设置项，目的是防止误选整个磁盘，并非协议上限。小于 32 MiB 的文件可以省略 `chunks` 并作为单流传输；达到 32 MiB 的音视频默认使用 8 MiB 分块。每块和整文件都记录 SHA-256。

### 10.3 发送状态机

```text
draft → hashing → uploading → publishing → ready
                         ↘ failed / cancelled
```

发送端先在任务目录创建 `files`，文件以 `<安全文件名>.part` 上传，同时在本机流式计算 SHA-256；完成后核对远端大小，再原子重命名去掉 `.part`。只有所有文件都完成，才上传 `manifest.uploading.json` 并将它原子重命名为 `manifest.ready.json`。因此接收端只扫描 `manifest.ready.json`，永远不会把半成品显示为可领取文件。相同名称在一个任务中出现时，发送前改为 `name (2).ext` 并让用户确认。

媒体文件额外记录 `mimeType` 以及可选的像素尺寸/时长，仅用于接收端显示；`size` 和 `sha256` 始终以原始文件流为准。发送端不把完整媒体载入内存：图片按约 64 KiB 的流块发送，大于 32 MiB 的音视频按 8 MiB 可恢复分块发送。图片默认最多 3 个并行，单个音视频内部最多 2 个分块并行；最终并发由基准测试决定，并允许用户切换“最快”与“减少后台占用”。

### 10.4 接收状态机

```text
ready → downloading → verifying → received
                    ↘ failed / cancelled
```

桌面端可选目标目录；Android 对每个文件调用 `ACTION_CREATE_DOCUMENT`，首期不尝试静默写入任意公共目录。数据流写入 `.part` 或应用缓存，完成后核对大小及 SHA-256，全部成功才记录回执。回执状态可为 `received`、`partial` 或 `rejected`。取消只清理本机临时文件，不删除服务端任务，用户可以重新领取。

Android 的系统保存选择器对每个媒体文件都可能要求一次保存位置确认，这是系统 SAF 的交互约束，不是传输失败。Jet2Drop 先把媒体分块下载到应用缓存并校验，再按顺序合成为完整临时文件、计算整文件 SHA-256，最后提交到用户选定的 `content://` URI；提交失败时保留已校验缓存并允许重试，不重新下载。开始视频任务前必须确认缓存可用空间至少为文件大小加 10%，不足时先提示释放空间。

### 10.5 清理与并发

- Windows 每日计划任务扫描 `expiresAt`；过期任务先移动到 `quarantine`，7 天后删除。
- `manifest.ready.json` 缺失且目录超过 24 小时视为中断上传，可隔离清理。
- 收到 `received` 回执后保留 24 小时，便于发送端看到结果，之后删除任务。
- 清理程序先取得任务目录的排他锁文件；正在上传或下载的任务跳过本轮清理。
- 小文件断网后从当前文件重新传输；大于 32 MiB 的音视频记录已校验分块位图，断线或应用重启后只补传缺失/损坏分块。
- Windows 磁盘剩余空间低于“待传文件大小 + 1 GB”时拒绝接收新任务并明确提示。

### 10.6 媒体直连快速路径与回退

图片、音频和视频快传在 V0.1 就采用“直连优先、Windows 中转兜底”，其中媒体速度是首要指标：

```text
媒体任务
→ 目标端在线并通过 Tailscale 配对
→ 目标端随机监听临时端口，仅接受一次性 token
→ 发送端使用 HTTP 流式 PUT 直接发送文件或分块
→ 目标端写入临时文件、校验 SHA-256、原子落盘
→ 直连失败/超时 10 秒
→ 自动转为 Windows 中转任务
```

实现约束：

- 接收器只在任务期间存在，端口随机、token 单次使用、默认有效期 10 分钟。
- 目标端只接受来自 Tailnet `100.64.0.0/10` 的连接；服务端检查远端地址，不依赖 mDNS、UDP 广播或公网端口。
- Tailscale 能直连时，媒体只经过发送端和接收端；Tailscale 只能走 DERP 时仍可使用该路径，但速度由中继决定。
- Windows 和 macOS 使用 Dart `HttpServer`/HTTP 客户端；Android 使用 Kotlin 前台 `dataSync` 服务承载接收期间的监听和通知。
- Android 清单增加 `FOREGROUND_SERVICE` 与 `FOREGROUND_SERVICE_DATA_SYNC`，服务声明 `android:foregroundServiceType="dataSync"`；传输完成或取消立即停止服务。
- 多张图片默认 3 个并行并复用 HTTP keep-alive 连接；大于 32 MiB 的音视频使用 8 MiB 分块、分块编号和 `Content-Range`，接收端只确认已落盘且哈希正确的分块。
- 直连路径和中转路径共用 `QuickTransferManifest`、临时后缀、SHA-256、回执和过期清理，因而切换路径不会改变可靠性语义。
- 任何直连实现失败都必须自动回退中转；禁止因为追求速度而让媒体只支持直连。

文档、代码等普通文件仍默认走 Windows 中转，以降低 Android 后台服务、临时监听和防火墙适配的开发风险。后续版本可以把直连能力扩展到所有文件类型。

## 11. 整仓同步设计

### 11.1 默认模式：安全双向同步

macOS 通过 Rclone Bisync 比较：

- Path 1：macOS 本地仓库
- Path 2：SFTPGo 上的 Windows 仓库

第一次运行必须使用初始化/重同步流程；后续使用普通 Bisync。客户端负责生成参数、启动进程、读取标准输出和退出码，不让用户直接编辑命令行。

默认安全策略：

- 开启访问检查。
- 设置单次最大删除比例或数量。
- 使用锁，阻止同一设备重复启动同步。
- 排除 Office 临时文件和系统元数据。
- 冲突策略设为不自动选择赢家，保留双方冲突副本。
- 同步错误时不继续执行删除。
- 每次同步保存机器可读日志。

建议排除：

```text
.DS_Store
Thumbs.db
desktop.ini
._*
~$*
*.tmp
.jet2drop-*.part
/.jet2drop-history/**
/__jet2drop_transfer/**
```

### 11.2 冲突

冲突定义：同一相对路径在上次成功同步后，Windows 和 macOS 两边都发生修改，并且当前内容不同。

处理方式：

- 不尝试合并 PPT、DOC、PDF 和图片。
- 保留两个带设备和时间标记的文件。
- 在客户端冲突页列出原路径、两个版本、大小和修改时间。
- 用户下载/打开比较后，手动选择保留版本。

### 11.3 强制覆盖模式

“以本地为准”和“以远端为准”属于高级危险操作，不与普通同步按钮放在同一位置。

执行流程：

```text
生成 dry-run 差异
→ 展示将覆盖和删除的文件
→ 生成目标端备份目录
→ 用户二次确认
→ 执行单向 sync
→ 校验结果
→ 记录日志
```

Android 不显示这些功能。

### 11.4 Windows 本地模式

Windows 实际仓库本身就是中心仓库，因此不对自己运行 Bisync。Windows 客户端提供：

- 浏览和管理实际仓库。
- 从外部目录导入文件或目录。
- 将仓库导出到指定目录作为快照。
- 直接显示 macOS 同步留下的冲突文件。

## 12. 文件系统兼容规则

中心仓库位于 Windows，因此所有客户端必须遵守 Windows 文件名规则：

- 拒绝 `< > : " / \\ | ? *` 等 Windows 禁止字符。
- 拒绝尾部空格和尾部句点。
- 拒绝 `CON`、`PRN`、`AUX`、`NUL`、`COM1` 等保留名称。
- 按大小写不敏感方式检测同目录重名。
- 文件名统一为 Unicode NFC 后再比较。
- 显示路径长度风险，首期避免创建过深目录。

macOS 可能产生 Unicode 分解形式和 `._` 资源文件，客户端和同步过滤器必须处理这些差异。

## 13. 安全方案

- 不开放路由器端口，不把 SFTPGo 直接暴露到公网。
- 只允许 Tailscale 私有网络访问 SFTP 端口。
- Tailscale 账号开启多因素认证和设备审批。
- Windows、macOS、Android 使用独立 SFTPGo 用户或独立凭据。
- 固定并校验 SSH 主机密钥指纹。
- 密码/私钥存放于 Windows Credential Manager、macOS Keychain、Android Keystore 对应的安全存储实现。
- 日志不得记录密码、私钥、完整认证报文或文件正文。
- Android 下载通过 SAF，不申请不必要的全盘存储权限。
- Windows 仓库与 SFTPGo 配置必须定期备份到另一块物理磁盘。
- 同步不是备份；误删除可能传播到另一端。

## 14. 部署、配置与构建手册

以下步骤是固定基线的首次部署顺序。先使用 `E:\Jet2DropTestRepository` 做完整门禁，确认无误后再把用户根目录切换为正式的 `E:\Repository`。

### 14.1 Windows 主机准备

1. 在“设置 → 系统 → 电源”中将接通电源后的睡眠设为“从不”；允许显示器单独关闭。
2. 给 Windows 设备设置稳定名称，例如 `jet2drop-win`。
3. 以管理员 PowerShell 创建目录：

```powershell
New-Item -ItemType Directory -Force -Path @(
  'E:\Jet2DropTestRepository'
  'E:\Repository'
  'D:\Jet2DropServer\backups'
  'D:\Jet2DropHistoryBackup'
  'D:\Jet2DropTransfer\inbox'
  'D:\Jet2DropTransfer\quarantine'
)
```

4. 确认 D 盘为 NTFS、当前 Windows 账户对这些目录有完全控制，并保证磁盘有足够余量。
5. 不把仓库放进 OneDrive 或其他同步目录，避免两个同步引擎同时改写文件。

### 14.2 三端安装和连接 Tailscale

Windows 安装：

```powershell
winget install -e --id Tailscale.Tailscale
```

macOS 从 Tailscale 官方 macOS 下载页安装当前正式版；选择 Standalone 版或 App Store 版后保持一种渠道，不要并装。Android 16 从 Google Play 安装官方 Tailscale。三端登录同一个 Tailscale 账户，在管理控制台批准设备，并开启账户 MFA 和设备审批。

验证步骤：

1. Windows 执行 `tailscale status` 和 `tailscale ip -4`，记录 `100.x.y.z` 地址。
2. 在管理控制台开启 MagicDNS，记录 Windows 的完整 DNS 名称。
3. Mac 执行 `tailscale ping jet2drop-win`；Android 在 Tailscale 应用中确认 Windows 在线。
4. 将 Mac/Android 切换到与 Windows 不同的网络，例如手机移动数据或另一处 Wi-Fi，再重复连接测试。这一步直接验证“不要求同一局域网”。
5. `tailscale ping` 输出 `direct` 或 `via DERP(...)` 都算连通；后者表示使用加密中继，可能更慢。

个人自用可以使用 Tailscale 当期免费个人方案；Tailscale 不保存仓库文件。仍然存在本机电费、网络流量和硬盘成本，但方案不要求购买服务商云盘空间。若将来免费策略变化，只替换网络适配层，不改变 SFTP 和仓库格式。

### 14.3 安装 SFTPGo Community 2.7.5

在管理员 PowerShell 安装固定版本对应的官方 Windows 包；若 winget 源仍提供该版本可使用：

```powershell
winget install -e --id drakkan.SFTPGo --version 2.7.5
Get-Service -Name SFTPGo
```

如果 winget 源已经移除该历史版本，则从第 21 节记录的 SFTPGo `v2.7.5` 官方发布页下载 Windows x64 安装器并核对发布校验值，不改用第三方下载站。

安装完成后执行以下配置：

1. 仅在 Windows 本机打开 `http://127.0.0.1:8080/web/admin`，完成首个 WebAdmin 管理员创建。管理员只管理服务，不用于客户端登录。安装器管理的配置、SQLite 数据库和主机密钥保留在它显示的默认数据目录，不手工搬移；通过 SFTPGo 备份/导出能力将副本保存到 `D:\Jet2DropServer\backups`。
2. 在状态页确认 SFTP 服务监听 2022；Web 管理监听地址保持 loopback/本机，不向 Tailnet 或公网提供管理页。
3. 数据提供者保持 SQLite，单人部署无需 PostgreSQL/MySQL。
4. 创建虚拟文件夹定义 `jet2drop-transfer`，实际路径为 `D:\Jet2DropTransfer`。
5. 分别创建 `jet2drop-windows`、`jet2drop-macos`、`jet2drop-android` 三个用户，首轮测试根目录均指向 `E:\Jet2DropTestRepository`；测试通过后改为 `E:\Repository`。
6. 给三个用户挂载虚拟目录，虚拟路径统一为 `/__jet2drop_transfer`，指向 `jet2drop-transfer`。
7. 三个用户使用不同的随机长密码或不同 SSH 密钥。客户端需要列目录、下载、上传、覆盖、重命名和清理临时文件，因此相关权限必须具备；删除正式文件功能在 UI 中仍按开发阶段控制。
8. 禁用匿名、FTP/明文协议和不使用的 HTTP 文件服务。不要开启路由器端口映射。
9. 从 SFTPGo 状态页或主机密钥文件取得 Ed25519 主机密钥 SHA-256 指纹，保存到三端配对资料。

SFTP 监听采用以下二选一策略，优先 A：

- A：监听 `0.0.0.0:2022`，Windows 防火墙只添加来自 `100.64.0.0/10` 的入站允许规则，并确认安装器没有遗留“任意远端地址均允许”的 SFTPGo 规则。这在 Tailscale 服务启动顺序变化时更稳。
- B：监听 Windows 当前 Tailscale `100.x.y.z:2022`。暴露面更小，但 Tailscale 地址或接口未就绪时 SFTPGo 可能绑定失败。

策略 A 的防火墙规则：

```powershell
New-NetFirewallRule `
  -DisplayName 'Jet2Drop SFTP from Tailnet' `
  -Direction Inbound -Action Allow -Protocol TCP `
  -LocalPort 2022 -RemoteAddress '100.64.0.0/10'
```

Windows 防火墙默认入站阻止必须保持启用。配置后分别验证：Mac 经 Tailscale 能连 `2022`；一台未加入 Tailnet 的设备通过 Windows 家庭公网地址不能连通。最后重启 Windows，检查 `Get-Service SFTPGo` 为 `Running`，三端仍能连接。

### 14.4 SFTPGo 账户和配对资料

每个客户端配置只包含自己的账户：

```text
host: jet2drop-win.<tailnet-name>.ts.net
fallbackHost: 100.x.y.z
port: 2022
username: jet2drop-macos（按设备选择）
hostKeyFingerprint: SHA256:...
deviceId: 首次安装生成的 UUID
deviceName: 用户可读名称
```

首次连接必须比较服务端返回的原始主机公钥指纹。指纹不匹配就停止连接，不能提供“仍然继续”快捷按钮。密码进入系统安全存储；host、port、设备名和主题等非敏感值进入普通首选项。配对二维码只在用户主动打开时生成，不包含可长期使用的明文密码；基础版可让用户在设备上手动输入密码。

### 14.5 Flutter 工程和依赖

在 Windows 安装 Flutter 3.44.9、Git，以及 Visual Studio 的“使用 C++ 的桌面开发”工作负载；运行：

```powershell
flutter doctor -v
flutter config --enable-windows-desktop
flutter create --platforms=windows,macos,android jet2drop
cd jet2drop
flutter pub add dartssh2:2.22.5 file_selector:1.1.0 desktop_drop:0.7.1
flutter pub add path_provider:2.1.6 flutter_secure_storage:10.3.1 shared_preferences:2.5.5
```

项目将依赖版本提交到 `pubspec.lock`。`dartssh2` 的 socket、SFTP client 和文件流全部封装在 `SftpRepositoryGateway`；业务层不直接导入插件。上传和下载按流处理，禁止用 `readAsBytes()` 一次加载大文件。

Android 工程设置 `minSdk = 24`，目标/编译 SDK 使用 Flutter 3.44.9 模板支持的 API 36 或更新的兼容值。普通仓库访问只需要网络权限；媒体直连接收还需要 Android 官方前台数据同步服务权限：

```xml
<uses-permission android:name="android.permission.INTERNET" />
<uses-permission android:name="android.permission.FOREGROUND_SERVICE" />
<uses-permission android:name="android.permission.FOREGROUND_SERVICE_DATA_SYNC" />
<uses-permission android:name="android.permission.POST_NOTIFICATIONS" />

<application ...>
    <service
        android:name=".MediaReceiveService"
        android:exported="false"
        android:foregroundServiceType="dataSync" />
</application>
```

文件选择使用 `ACTION_OPEN_DOCUMENT`；下载保存由 `DocumentSaveChannel.kt` 发起 `ACTION_CREATE_DOCUMENT`，通过 `ContentResolver.openOutputStream(uri, "w")` 流式写入。不要申请 `MANAGE_EXTERNAL_STORAGE`。Activity 重建后仍要恢复待处理的 URI 请求结果；用户取消选择返回明确的 cancelled 状态而不是异常。`POST_NOTIFICATIONS` 在 Android 13+ 运行时请求，仅用于显示媒体接收进度；服务启动后立即调用 `startForeground`，任务完成、取消或失败立即停止，不能把前台服务当成永久后台进程。

Windows/macOS 的 `desktop_drop` 只接受文件 URI，忽略网页文本等拖拽内容；拖入目录功能放到整仓导入阶段。目标目录在鼠标释放前固定显示，释放后再弹出同名策略确认。

### 14.6 Rclone 1.75.0 配置和 Bisync 模板

此节只用于 V0.2。Mac 下载官方 macOS ARM64 压缩包，校验发布页提供的哈希，把 `rclone` 放入应用私有工具目录并赋予执行权限。开发验证时可先放入 `/usr/local/bin` 或用户工具目录。执行：

```bash
rclone version
rclone config
```

创建名为 `jet2drop` 的 SFTP remote，填写 Windows MagicDNS 主机、端口 2022 和 `jet2drop-macos` 凭据。关键配置必须包含：

```ini
[jet2drop]
type = sftp
host = jet2drop-win.<tailnet-name>.ts.net
user = jet2drop-macos
port = 2022
shell_type = none
known_hosts_file = /Users/<用户名>/Library/Application Support/Jet2Drop/known_hosts
```

SFTPGo 不提供普通 SSH shell，因此 `shell_type = none` 是官方 Rclone SFTP 后端支持的兼容方式。密码用 `rclone config` 写入其混淆字段，配置文件权限限制为当前用户；更稳妥的最终方案是每设备 SSH 私钥 + 系统安全存储解锁。`known_hosts` 必须预先写入已核对的 SFTPGo 公钥，不能设置跳过校验。

Rclone 官方同时说明：SFTP 协议原生不提供文件哈希，远端校验通常依赖 SSH shell 命令；设置 `shell_type = none` 后远端哈希检查也会禁用。这不会阻止复制或 Bisync，因为 SFTP 修改时间（1 秒精度）和文件大小仍受支持，但整仓同步不得声明为“逐文件远端 SHA-256 比较”。V0.2 使用大小、修改时间和 Bisync 双端状态判定变化；普通下载、单文件上传和快传仍由 Jet2Drop 自己流式计算 SHA-256。Gate B 必须专门覆盖“相同大小但内容变化”和双端同时修改，若实测不能可靠识别，则整仓功能停留在显式差异确认，不自动执行。

过滤文件 `bisync-filter.txt`：

```text
- /.jet2drop-history/**
- /__jet2drop_transfer/**
- .DS_Store
- Thumbs.db
- desktop.ini
- ._*
- ~$*
- *.tmp
- .jet2drop-*.part
```

本地仓库为 `~/Documents/DocumentRepository`。正式运行前，客户端先执行并解析：

```bash
rclone bisync "$HOME/Documents/DocumentRepository" jet2drop:/ \
  --filter-from bisync-filter.txt --check-access --dry-run -vv
```

`--check-access` 要求按 Rclone Bisync 文档在两端根目录准备检查标记文件；应用初始化向导负责创建和验证。第一次建立 Bisync 状态必须在用户确认 dry-run 清单、两端已备份后运行一次：

```bash
rclone bisync "$HOME/Documents/DocumentRepository" jet2drop:/ \
  --filter-from bisync-filter.txt --check-access --resync -vv
```

以后移除 `--resync` 执行普通 Bisync。`--resync` 不是“修复一切”按钮，错误使用可能让一端覆盖另一端；只能由首次向导或状态损坏后的恢复向导调用。应用记录命令版本、起止时间、退出码和脱敏日志；非零退出码时禁止继续删除或自动重试。冲突参数必须先在 Gate B 用 Rclone 1.75.0 的 `rclone bisync --help` 和真机双改测试锁定，不能仅凭文件修改时间推断二进制文件胜者。

“以本地为准”和“以远端为准”使用 `rclone sync --dry-run` 生成清单，备份目标端后才去掉 `--dry-run`。命令方向分别是本地到 `jet2drop:/`、`jet2drop:/` 到本地；绝不能通过字符串拼接用户路径，必须用进程参数数组传递。

### 14.7 构建和安装三端客户端

Windows 在当前主机构建：

```powershell
flutter analyze
flutter test
flutter build windows --release
```

产物位于 `build\windows\x64\runner\Release`。首期整个目录打包为 ZIP，不只复制 EXE，因为 Flutter DLL 和插件必须随包存在。

macOS 必须在 MacBook Air M5 上安装 Xcode、Flutter 3.44.9；执行 `sudo xcodebuild -runFirstLaunch` 并用 `flutter doctor -v` 检查。然后：

```bash
flutter pub get
flutter analyze
flutter test
flutter build macos --release
```

生成的 `.app` 为 Apple Silicon 可运行版本。Rclone ARM64 作为应用资源打包时，首次复制到应用支持目录后再执行，设置可执行位；自用、在该 Mac 本机编译运行不要求购买 Apple Developer Program。若向其他 Mac 分发并消除 Gatekeeper 警告，则需要 Apple 签名/公证并重新评估费用。首期不走 Mac App Store Sandbox，以免 Rclone 子进程和用户目录访问增加不必要限制；若保留 Sandbox，则必须按 `file_selector` 官方说明添加 `com.apple.security.files.user-selected.read-write` entitlement，并重新验证 Finder 拖入和 Rclone 子进程，不能两种方案混用。

Android 可在 Windows 构建：

```powershell
flutter doctor -v
flutter devices
flutter analyze
flutter test
flutter build apk --release
```

使用自有 release keystore 签名并离线备份 keystore 和密码；不要长期分发 debug APK。通过 USB/ADB 或本机文件侧载到 Android 16，不需要 Google Play 开发者账号。安装后逐项测试 Tailscale VPN 切换、SAF 保存、应用切后台、屏幕锁定和大文件传输。

### 14.8 Windows 日常运行和恢复

- SFTPGo 与 Tailscale 均设为开机启动；Jet2Drop GUI 不必常驻，仓库服务仍可工作。
- GUI 和同步/校验任务设置低并发，基础版默认 2 个并行文件传输，避免影响日常办公和磁盘响应。
- Windows 编辑中的 Office 文件可能处于锁定状态；客户端显示“文件正在使用”，不强行覆盖，Office 的 `~$` 临时文件永不上传。
- 每周备份 SFTPGo 配置/数据库和仓库到另一块物理磁盘；每月执行一次恢复演练。
- 主机密钥或数据库恢复后若指纹变化，必须重新人工配对；不能批量静默更新客户端指纹。
- 故障排查顺序固定为：Windows 是否醒着 → `tailscale status` → `Get-Service SFTPGo` → `Test-NetConnection <MagicDNS> -Port 2022`（从另一台 Windows 时）→ SFTPGo 日志 → Jet2Drop 脱敏日志。

## 15. 开发前真机门禁

为了避免开发到一半才发现平台问题，第一阶段不是完整 UI，而是一个最小技术验证应用。

### 15.1 必须验证的端到端链路

1. Windows 安装 SFTPGo 并以 Windows 服务运行。
2. SFTPGo 用户主目录映射到测试仓库，而不是正式文件目录。
3. Windows、M5 Mac、Android 16 加入同一 Tailnet。
4. macOS 和 Android 通过 `dartssh2` 连接 SFTPGo。
5. 三端列出包含中文、空格、Emoji、长文件名的目录。
6. 三端上传和下载 1 KB、100 MB、至少 1 GB 的测试文件。
7. 下载后比较 SHA-256，确认内容一致。
8. Windows 从资源管理器拖拽文件上传。
9. macOS 从 Finder 拖拽文件上传。
10. Android 通过 `ACTION_CREATE_DOCUMENT` 保存并重新打开文件。
11. macOS ARM64 Rclone 完成首次 Bisync 和第二次增量 Bisync。
12. Windows 与 macOS 同时修改同一文件，确认生成两个冲突版本。
13. 在传输中切断 Tailscale，再恢复网络，确认错误可控且不会产生正式名半文件。
14. Windows 重启后 SFTPGo 自动恢复。
15. Mac 与 Windows 分处两个真实网络时完成上传下载；Android 使用移动数据完成相同测试。
16. Windows→Android、Android→Mac、Mac→Windows 各完成一次快传，发送或接收一方延迟上线仍可领取。
17. 快传上传中断时收件箱不显示半成品；完成后 SHA-256 一致，过期任务能被清理。
18. JPEG、PNG、WebP、GIF、BMP 各至少传输一次；发送端和接收端对原文件计算出的 SHA-256 完全一致，且接收文件可被系统或 Flutter 解码打开。
19. MP3/M4A/FLAC 和 MP4/MOV/MKV 各至少传输一次；至少用一个 1 GB 视频执行断网、恢复和应用重启测试，只补传缺失分块，最终 SHA-256 一致。
20. 三对设备分别测试媒体直连；确认 Windows 快传目录没有直连任务副本，直连失败时自动回退中转。
21. 在相同网络和设备条件下先执行内置 TCP 吞吐基准，媒体直连稳定阶段的有效吞吐应达到基准的 70% 以上；未达到时 Gate A 不通过并分析分块、并发或磁盘瓶颈。

### 15.2 门禁判定

门禁分为两级，避免高风险整仓功能阻塞低风险基础版：

#### Gate A：V0.1基础链路门禁

以下任一项失败，都不能进入V0.1完整 UI 开发：

- 三端无法稳定列目录。
- Android 无法安全保存文件。
- Finder/资源管理器拖拽权限不稳定。
- 中文和跨平台文件名出现不可预测损坏。
- 中断上传会覆盖原文件或留下无法识别的正式文件。
- 跨网络只能在同一局域网成功，或 DERP 中继场景无法完成传输。
- 快传提前发布清单、接收损坏文件，或过期清理会删除正在传输的任务。
- 媒体直连无法稳定建立、1 GB 视频不能断点恢复，或有效吞吐低于同链路 TCP 基准的 70%。

#### Gate B：V0.2整仓门禁

Rclone ARM64无法通过SFTPGo完成首次同步、增量同步或冲突保留时，只暂停V0.2整仓开发，不影响已经验证的V0.1单文件客户端。

失败后优先替换适配层，不推翻整个应用：

- `dartssh2` 失败：评估原生 libssh2 桥接。
- `desktop_drop` 失败：分别实现 Windows/macOS 原生拖放平台通道。
- Android SAF 桥接失败：直接扩展 Kotlin实现，不更改共享业务层。
- Rclone Bisync 不满足：保留单文件客户端，重新评估桌面同步引擎。

## 16. 开发阶段

### 阶段 0：技术原型

交付：

- Windows 测试 SFTPGo服务。
- 最小 Flutter三端应用。
- 列目录、上传、下载。
- 两个真实外部网络之间的 Tailscale/SFTP 贯通。
- 快传清单最后发布、延迟领取和 SHA-256 验证。
- 媒体直连 HTTP 原型、8 MiB 分块恢复、Android `dataSync` 前台接收服务和吞吐基准。
- Android SAF保存。
- 桌面拖拽。
- macOS Rclone ARM64同步验证。
- 兼容性验证报告。

退出条件：Gate A通过后进入V0.1开发；Gate B通过后才允许进入V0.2整仓开发。

### 阶段 1：共享领域层和传输核心

交付：

- `RepositoryGateway`抽象。
- Windows本地适配器。
- SFTP远程适配器。
- 分块上传和下载。
- 临时文件和原子替换。
- 传输任务队列、进度、取消和重试。
- 主机密钥固定和安全凭据存储。
- 快传清单、回执、哈希校验、发布和清理状态机。
- 媒体直连选择、一次性 token、分块位图、断点续传和中转回退状态机。

### 阶段 2：三端统一文件界面

交付：

- 响应式桌面/Android布局。
- 目录导航、文件列表、排序和刷新。
- 上传和下载。
- 桌面拖拽投放。
- 传输任务面板。
- 快传发送、收件箱、领取和结果状态。
- 媒体“最快/减少后台占用”模式、直连/DERP/中转链路状态和实时速度。
- 浅色/深色主题。

### 阶段 3：低成本预览和个性化

交付：

- 常见图片预览。
- 小型UTF-8文本预览。
- 本地预览缓存和清理。
- 自定义背景图、遮罩和透明度。
- 三端统一按钮和交互状态。
- V0.1基础版三端打包和真机验收。

### 阶段 4：安全文件管理与整仓同步

交付：

- 远程新建目录、重命名和移动。
- 移入回收区代替直接删除。
- Rclone配置生成和进程管理。
- 首次同步向导。
- 普通安全双向同步。
- dry-run差异预览。
- 冲突列表。
- 以本地/远端为准的高级操作。
- 备份目录和同步日志。

### 阶段 5：打包和部署

交付：

- Windows x64 Release包。
- macOS ARM64 Release包。
- Android 16真机可安装 APK。
- Windows服务端部署说明。
- 三端安装、配对、备份和恢复说明。
- 验收测试记录。

## 17. 测试方案

### 17.1 单元测试

- Windows文件名合法性。
- Unicode规范化和大小写冲突。
- 远程路径拼接，禁止 `..`逃逸。
- 文件大小和时间格式。
- 传输状态机。
- 同名文件策略。
- 同步计划解析。
- 快传清单 JSON 兼容、路径净化、过期时间和状态机。
- SHA-256 大文件流式计算及不一致处理。
- 媒体分块编号、重复块幂等、缺块恢复、分块合并和整文件哈希。
- 敏感信息日志脱敏。

### 17.2 集成测试

- 本地测试SFTPGo的目录和文件操作。
- 上传临时文件后原子替换。
- 下载中断后的清理。
- 权限不足和磁盘空间不足。
- 主机密钥变化。
- Tailscale离线和恢复。
- Tailscale跨 Wi-Fi/移动数据以及 DERP 中继路径。
- 快传清单最后发布、延迟领取、回执和过期清理锁。
- 媒体直连失败回退、1 GB 视频断点续传、Android 前台服务结束和空间不足拒绝。
- Rclone退出码、冲突和大规模删除保护。

### 17.3 真机测试矩阵

| 场景 | Windows x64 | MacBook Air M5 | Android 16 |
|---|---:|---:|---:|
| 登录和主机密钥校验 | 是 | 是 | 是 |
| 目录浏览 | 是 | 是 | 是 |
| 单/多文件上传 | 是 | 是 | 是 |
| 单文件下载 | 是 | 是 | 是 |
| 媒体直连及中转领取 | 是 | 是 | 是 |
| 拖拽上传 | 是 | 是 | 不适用 |
| 图片预览 | 是 | 是 | 是 |
| 文本预览 | 是 | 是 | 是 |
| 整仓同步 | 本地仓库端 | 是 | 不适用 |
| 冲突处理 | 是 | 是 | 只显示远端结果 |
| 网络中断恢复 | 是 | 是 | 是 |
| 不同网络远程访问 | 是 | 是 | 是 |

## 18. 分阶段验收标准

### 18.1 V0.1基础版

V0.1只包含成熟、容易验证且不易损坏数据的功能，必须同时满足：

1. 三端使用统一视觉语言浏览同一个仓库。
2. Windows直接修改仓库后，macOS/Android刷新可见。
3. 三端可以上传和下载单个文件。
4. Windows和macOS支持文件选择与拖拽上传。
5. Android只下载所选文件，不下载整个仓库。
6. 上传中断不会破坏同名正式文件。
7. 常见图片和小型文本可以低成本预览。
8. 背景图和按钮主题在三端布局中不影响可读性。
9. SFTPGo只在Tailnet可访问，公网扫描不到服务端口。
10. Windows重启后服务自动恢复。
11. 安装和使用不依赖付费云盘。
12. 三端任意一端可向另两端发起快传，接收端可稍后上线领取。
13. 快传文件不进入正式仓库，发布前不显示，领取后通过 SHA-256 校验。
14. Windows 与另一设备不在同一局域网时，仓库浏览、传输和快传仍可使用。
15. 图片、音频和视频快传不改变文件大小或格式；网络中断后可续传，不能产生损坏的正式媒体文件。
16. 双方在线时媒体默认绕过 Windows 直连；有效吞吐达到同链路 TCP 基准的 70% 以上，失败时自动转入中转队列。

### 18.2 V0.2整仓版

V0.1稳定后，V0.2必须另外满足：

1. macOS可以在M5设备上完成首次和增量整仓同步。
2. 同一文件双端修改时保留冲突双方。
3. 同步前可以预览新增、覆盖、删除和冲突。
4. 大规模删除触发保护并停止执行。
5. 以本地/远端为准前创建目标端备份。
6. Windows实际仓库在同步中断后仍保持可用。

## 19. 主要风险与控制

| 风险 | 影响 | 控制措施 |
|---|---|---|
| Windows和Mac同时修改二进制文件 | 无法内容合并 | 保留冲突副本，不自动选择赢家 |
| Windows主机睡眠、重启或断网 | 远程不可用 | 禁止睡眠、服务自启、离线错误提示 |
| Tailscale免费策略未来变化 | 外网链路受影响 | 网络层封装，保留ZeroTier/自建WireGuard替换空间 |
| 第三方Flutter包失效 | 某个平台功能受影响 | 使用适配器隔离并做阶段0真机门禁 |
| Android存储权限变化 | 下载保存失败 | 依赖系统SAF，不依赖绝对文件路径 |
| Android 同时运行其他 VPN | Tailscale 可能无法接管 VPN 通道 | 首次连接检查并提示关闭冲突 VPN；不把它误报为 SFTP 故障 |
| macOS沙箱影响拖拽/Rclone | 桌面功能受限 | 首期非App Store分发，M5真机先验证 |
| 误执行整仓覆盖 | 大量文件丢失 | dry-run、二次确认、最大删除限制、备份目录 |
| 同步被误认为备份 | 硬盘故障后无恢复副本 | 外置物理硬盘定期备份 |
| 图片目录自动缩略图耗流量 | Android浏览缓慢 | 默认图标，打开后缓存缩略图 |
| 快传暂存占满 Windows 磁盘 | 仓库和日常使用受影响 | 任务限额、空间预检、有效期、隔离后清理 |
| DERP 中继或家庭上行较慢 | 跨网络大文件耗时 | 显示链路/速度，限制并发；同网时自动获得直连优势 |

## 20. 后续版本候选

- 普通小文件的跨重启断点续传（大于 32 MiB 的媒体已在基础版支持分块恢复）。
- 自动后台同步和计划任务。
- PDF首屏预览。
- HEIC/HEIF统一预览和缩略图。
- 文件收藏和最近访问。
- 仓库全文搜索。
- 服务端缩略图生成。
- 文件历史版本浏览和恢复。
- 局域网直连状态和速度诊断。
- 替代Tailscale的自建WireGuard/Headscale部署。

## 21. 官方资料与核验来源

- Flutter支持平台：https://docs.flutter.dev/reference/supported-platforms
- Flutter SDK发布归档：https://docs.flutter.dev/install/archive
- Flutter Windows构建：https://docs.flutter.dev/deployment/windows
- Flutter macOS构建：https://docs.flutter.dev/deployment/macos
- Flutter Android构建：https://docs.flutter.dev/deployment/android
- Flutter Image API：https://api.flutter.dev/flutter/widgets/Image-class.html
- Flutter ButtonStyle：https://api.flutter.dev/flutter/material/ButtonStyle-class.html
- Flutter官方file_selector：https://pub.dev/packages/file_selector
- Flutter官方path_provider：https://pub.dev/packages/path_provider
- Android Storage Access Framework：https://developer.android.com/training/data-storage/shared/documents-files
- Android ACTION_CREATE_DOCUMENT：https://developer.android.com/reference/android/content/Intent#ACTION_CREATE_DOCUMENT
- SFTPGo文档：https://docs.sftpgo.com/latest/
- SFTPGo Windows安装：https://docs.sftpgo.com/latest/installation/
- SFTPGo虚拟目录：https://docs.sftpgo.com/latest/virtual-folders/
- SFTPGo Community项目：https://github.com/drakkan/sftpgo
- SFTPGo 2.7.5发布：https://github.com/drakkan/sftpgo/releases/tag/v2.7.5
- Tailscale下载：https://tailscale.com/download
- Tailscale Windows安装：https://tailscale.com/docs/install/windows
- Tailscale macOS安装：https://tailscale.com/docs/install/mac
- Tailscale Android安装：https://tailscale.com/docs/install/android
- Tailscale个人方案：https://tailscale.com/pricing
- Tailscale连接类型与DERP：https://tailscale.com/docs/reference/connection-types
- Tailscale MagicDNS：https://tailscale.com/docs/features/magicdns
- Tailscale防火墙与端口说明：https://tailscale.com/kb/1082/firewall-ports
- Rclone下载与系统要求：https://rclone.org/downloads/
- Rclone SFTP后端：https://rclone.org/sftp/
- Rclone Bisync：https://rclone.org/bisync/
- Rclone 1.75.0发布：https://github.com/rclone/rclone/releases/tag/v1.75.0
- dartssh2：https://pub.dev/packages/dartssh2
- desktop_drop：https://pub.dev/packages/desktop_drop
- flutter_secure_storage：https://pub.dev/packages/flutter_secure_storage
- shared_preferences：https://pub.dev/packages/shared_preferences
- Apple M5 MacBook Air规格：https://www.apple.com/macbook-air/specs/
