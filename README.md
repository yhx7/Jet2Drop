# Jet2Drop

Jet2Drop 是 Android 与 Windows 之间使用 Tailscale 和 SFTPGo 的私人文件仓库客户端。

当前只采用一条正式传输链路：普通传输和快传都通过 Windows 中转仓库完成。发送方和接收方不必同时在线，暂停、取消、重试、校验与异常退出恢复共用同一套任务规则。未接入产品的直连实验通道不属于当前实现。

## 质量检查

提交前应依次通过 `flutter analyze`、`flutter test`、Android Release 构建与 Windows Release 构建。真实文件选择、相册保存和跨设备传输由连接的实际设备最终确认。

## Windows 一键部署

在项目目录运行 `powershell -ExecutionPolicy Bypass -File .\tools\deploy_windows.ps1`。脚本会构建正式版、只关闭部署目录中的旧进程、完整复制并校验文件，然后重新启动应用。仅部署已有构建可追加 `-SkipBuild`。
