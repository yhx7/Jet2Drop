import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow {
  /// Closing the main window keeps the Flutter engine alive so transfers,
  /// presence updates, and the photo receiver can continue in the menu bar.
  /// The app delegate restores this same window from the Dock or status item.
  override func performClose(_ sender: Any?) {
    orderOut(sender)
  }

  override func awakeFromNib() {
    isReleasedWhenClosed = false
    let flutterViewController = FlutterViewController()
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)

    RegisterGeneratedPlugins(registry: flutterViewController)
    registerSecurityScopedBookmarkChannel(
      with: flutterViewController.engine.binaryMessenger
    )
    registerLifecycleChannel(
      with: flutterViewController.engine.binaryMessenger
    )
    registerTailscaleChannel(
      with: flutterViewController.engine.binaryMessenger
    )

    super.awakeFromNib()
  }

  private func registerTailscaleChannel(
    with messenger: FlutterBinaryMessenger
  ) {
    let channel = FlutterMethodChannel(
      name: "jet2drop/tailscale",
      binaryMessenger: messenger
    )
    channel.setMethodCallHandler { call, result in
      guard call.method == "openTailscale" else {
        result(FlutterMethodNotImplemented)
        return
      }

      let workspace = NSWorkspace.shared
      let bundleIdentifiers = [
        "io.tailscale.ipn.macos",
        "io.tailscale.ipn.macsys",
      ]
      let applicationURL = bundleIdentifiers.compactMap {
        workspace.urlForApplication(withBundleIdentifier: $0)
      }.first ?? URL(fileURLWithPath: "/Applications/Tailscale.app")

      guard FileManager.default.fileExists(atPath: applicationURL.path) else {
        result(false)
        return
      }

      let configuration = NSWorkspace.OpenConfiguration()
      configuration.activates = true
      workspace.openApplication(
        at: applicationURL,
        configuration: configuration
      ) { _, error in
        DispatchQueue.main.async {
          result(error == nil)
        }
      }
    }
  }

  private func registerLifecycleChannel(
    with messenger: FlutterBinaryMessenger
  ) {
    let channel = FlutterMethodChannel(
      name: "jet2drop/macos_lifecycle",
      binaryMessenger: messenger
    )
    channel.setMethodCallHandler { call, result in
      guard let delegate = NSApp.delegate as? AppDelegate else {
        result(
          FlutterError(
            code: "lifecycle_unavailable",
            message: "应用生命周期服务尚未就绪。",
            details: nil
          )
        )
        return
      }
      switch call.method {
      case "setActiveTransfers":
        guard let active = call.arguments as? Bool else {
          result(
            FlutterError(
              code: "invalid_arguments",
              message: "传输状态必须是布尔值。",
              details: nil
            )
          )
          return
        }
        delegate.setActiveTransfers(active)
        result(nil)
      case "requestExit":
        result(nil)
        DispatchQueue.main.async {
          delegate.requestExit()
        }
      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }

  private func registerSecurityScopedBookmarkChannel(
    with messenger: FlutterBinaryMessenger
  ) {
    let channel = FlutterMethodChannel(
      name: "jet2drop/macos_security_scope",
      binaryMessenger: messenger
    )
    channel.setMethodCallHandler { call, result in
      switch call.method {
      case "restoreDirectoryAccess":
        result(SecurityScopedBookmarkStore.shared.restoreDirectoryAccess())
      case "persistDirectoryAccess":
        guard let arguments = call.arguments as? [String: Any],
              let path = arguments["path"] as? String,
              !path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
          result(
            FlutterError(
              code: "invalid_arguments",
              message: "目录路径不能为空。",
              details: nil
            )
          )
          return
        }
        do {
          try SecurityScopedBookmarkStore.shared.persistDirectoryAccess(
            path: path
          )
          result(nil)
        } catch {
          result(
            FlutterError(
              code: "security_scope_error",
              message: error.localizedDescription,
              details: nil
            )
          )
        }
      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }
}
