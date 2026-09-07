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
  override func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    return true
  }

  override func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
    return true
  }

  override func applicationWillTerminate(_ notification: Notification) {
    SecurityScopedBookmarkStore.shared.releaseDirectoryAccess()
    super.applicationWillTerminate(notification)
  }
}
