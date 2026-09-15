import Cocoa
import FlutterMacOS

/// Owns the one security-scoped URL used by the desktop quick-transfer
/// receiver. The bookmark itself is persisted in the app's UserDefaults, while
/// the access scope is kept alive only for the current process.
final class SecurityScopedBookmarkStore {
  static let shared = SecurityScopedBookmarkStore()

  private static let bookmarkKey = "jet2drop.macos.quickSaveDirectoryBookmark"
  private var activeURL: URL?

  private init() {}

  func restoreDirectoryAccess() -> String? {
    guard activeURL == nil else { return activeURL?.path }
    guard let data = UserDefaults.standard.data(forKey: Self.bookmarkKey) else {
      return nil
    }

    var isStale = false
    do {
      let url = try URL(
        resolvingBookmarkData: data,
        options: [.withSecurityScope, .withoutUI],
        relativeTo: nil,
        bookmarkDataIsStale: &isStale
      )
      guard url.isFileURL, isDirectory(url),
            url.startAccessingSecurityScopedResource() else {
        UserDefaults.standard.removeObject(forKey: Self.bookmarkKey)
        return nil
      }

      activeURL = url
      if isStale {
        let refreshed = try url.bookmarkData(
          options: [.withSecurityScope],
          includingResourceValuesForKeys: nil,
          relativeTo: nil
        )
        UserDefaults.standard.set(refreshed, forKey: Self.bookmarkKey)
      }
      return url.path
    } catch {
      activeURL?.stopAccessingSecurityScopedResource()
      activeURL = nil
      UserDefaults.standard.removeObject(forKey: Self.bookmarkKey)
      return nil
    }
  }

  func persistDirectoryAccess(path: String) throws {
    let url = URL(fileURLWithPath: path, isDirectory: true)
    guard url.isFileURL, isDirectory(url) else {
      throw NSError(
        domain: "Jet2Drop.SecurityScopedBookmark",
        code: 1,
        userInfo: [NSLocalizedDescriptionKey: "默认保存位置必须是文件夹。"]
      )
    }

    if samePath(activeURL, url) {
      let bookmark = try url.bookmarkData(
        options: [.withSecurityScope],
        includingResourceValuesForKeys: nil,
        relativeTo: nil
      )
      UserDefaults.standard.set(bookmark, forKey: Self.bookmarkKey)
      return
    }

    guard url.startAccessingSecurityScopedResource() else {
      throw NSError(
        domain: "Jet2Drop.SecurityScopedBookmark",
        code: 2,
        userInfo: [NSLocalizedDescriptionKey: "无法取得默认保存目录的访问权限。"]
      )
    }

    do {
      let bookmark = try url.bookmarkData(
        options: [.withSecurityScope],
        includingResourceValuesForKeys: nil,
        relativeTo: nil
      )
      UserDefaults.standard.set(bookmark, forKey: Self.bookmarkKey)
      let previous = activeURL
      activeURL = url
      previous?.stopAccessingSecurityScopedResource()
    } catch {
      url.stopAccessingSecurityScopedResource()
      throw error
    }
  }

  func releaseDirectoryAccess() {
    activeURL?.stopAccessingSecurityScopedResource()
    activeURL = nil
  }

  private func isDirectory(_ url: URL) -> Bool {
    var isDirectory: ObjCBool = false
    return FileManager.default.fileExists(
      atPath: url.path,
      isDirectory: &isDirectory
    ) && isDirectory.boolValue
  }

  private func samePath(_ left: URL?, _ right: URL) -> Bool {
    guard let left else { return false }
    return left.standardizedFileURL.path == right.standardizedFileURL.path
  }
}

@main
class AppDelegate: FlutterAppDelegate {
  private var statusItem: NSStatusItem?
  private var statusMenu: NSMenu?
  private var hasActiveTransfers = false

  override func applicationDidFinishLaunching(_ notification: Notification) {
    NSApp.setActivationPolicy(.regular)
    installStatusItem()
  }

  override func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    return false
  }

  override func applicationShouldHandleReopen(
    _ sender: NSApplication,
    hasVisibleWindows flag: Bool
  ) -> Bool {
    DispatchQueue.main.async { [weak self] in
      self?.showMainWindow()
    }
    return true
  }

  override func applicationShouldTerminate(
    _ sender: NSApplication
  ) -> NSApplication.TerminateReply {
    guard hasActiveTransfers else {
      return .terminateNow
    }
    let alert = NSAlert()
    alert.messageText = "仍有文件正在传输"
    alert.informativeText = "退出会中断当前任务，确定退出吗？"
    alert.alertStyle = .warning
    alert.addButton(withTitle: "取消")
    alert.addButton(withTitle: "退出")
    guard alert.runModal() == .alertSecondButtonReturn else {
      return .terminateCancel
    }
    hasActiveTransfers = false
    return .terminateNow
  }

  override func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
    return true
  }

  override func applicationWillTerminate(_ notification: Notification) {
    statusMenu = nil
    statusItem = nil
    SecurityScopedBookmarkStore.shared.releaseDirectoryAccess()
  }

  func setActiveTransfers(_ active: Bool) {
    hasActiveTransfers = active
  }

  func requestExit() {
    NSApp.terminate(nil)
  }

  @objc private func showMainWindow() {
    guard let window = NSApp.windows.first(where: { $0 is MainFlutterWindow }) else {
      return
    }
    NSApp.activate(ignoringOtherApps: true)
    if window.isMiniaturized {
      window.deminiaturize(nil)
    }
    window.makeKeyAndOrderFront(nil)
  }

  @objc private func exitApplication() {
    requestExit()
  }

  @objc private func statusItemClicked(_ sender: NSStatusBarButton) {
    guard NSApp.currentEvent?.type == .rightMouseUp,
          let item = statusItem,
          let menu = statusMenu else {
      showMainWindow()
      return
    }

    item.menu = menu
    sender.performClick(nil)
    item.menu = nil
  }

  private func installStatusItem() {
    let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    statusItem = item
    if let button = item.button {
      let image = (NSApp.applicationIconImage.copy() as? NSImage) ?? NSImage(
        systemSymbolName: "arrow.left.arrow.right",
        accessibilityDescription: "Jet2Drop"
      )!
      image.size = NSSize(width: 18, height: 18)
      button.image = image
      button.toolTip = "Jet2Drop"
      button.target = self
      button.action = #selector(statusItemClicked(_:))
      button.sendAction(on: [.leftMouseUp, .rightMouseUp])
    }
    let menu = NSMenu()
    let openItem = NSMenuItem(
      title: "打开 Jet2Drop",
      action: #selector(showMainWindow),
      keyEquivalent: ""
    )
    openItem.target = self
    menu.addItem(openItem)
    menu.addItem(.separator())
    let exitItem = NSMenuItem(
      title: "退出 Jet2Drop",
      action: #selector(exitApplication),
      keyEquivalent: "q"
    )
    exitItem.target = self
    menu.addItem(exitItem)
    statusMenu = menu
    item.isVisible = true
  }
}
