import Cocoa
import FlutterMacOS

@main
class AppDelegate: FlutterAppDelegate {
  static func preserveSandboxData() {
    // Releases before desktop updating were sandboxed. Keep using their data
    // locations through symlinks, so large downloads aren't copied or lost.
    let fm = FileManager.default
    let home = fm.homeDirectoryForCurrentUser
    let legacy = home.appendingPathComponent("Library/Containers/com.yomi.yomi/Data/Library")
    let library = home.appendingPathComponent("Library")
    if fm.fileExists(atPath: legacy.path) {
      for relative in ["Application Support/com.yomi.yomi", "Caches/com.yomi.yomi"] {
        let source = legacy.appendingPathComponent(relative)
        let destination = library.appendingPathComponent(relative)
        if fm.fileExists(atPath: source.path) && !fm.fileExists(atPath: destination.path) {
          do {
            try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fm.createSymbolicLink(at: destination, withDestinationURL: source)
          } catch {
            NSLog("Could not preserve legacy Yomi data: %@", String(describing: error))
          }
        }
      }
      let marker = "yomi.didMigrateSandboxPreferences"
      if !UserDefaults.standard.bool(forKey: marker) {
        let plist = legacy.appendingPathComponent("Preferences/com.yomi.yomi.plist")
        if let values = NSDictionary(contentsOf: plist) as? [String: Any] {
          for (key, value) in values where UserDefaults.standard.object(forKey: key) == nil {
            UserDefaults.standard.set(value, forKey: key)
          }
          UserDefaults.standard.set(true, forKey: marker)
        }
      }
    }
  }

  override func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    return true
  }

  override func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
    return true
  }
}
