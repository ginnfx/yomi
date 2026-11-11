import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow {
  private var tunnel: TunnelChannel?

  override func awakeFromNib() {
    AppDelegate.preserveSandboxData()
    let flutterViewController = FlutterViewController()
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)
    self.setContentSize(NSSize(width: 1180, height: 800))
    self.contentMinSize = NSSize(width: 720, height: 640)
    self.title = "Yomi"
    // Content runs under a transparent title bar, so the app reads as one surface
    // instead of a box under a grey bar. The traffic lights stay in place.
    self.titlebarAppearsTransparent = true
    self.titleVisibility = .hidden
    self.styleMask.insert(.fullSizeContentView)
    self.backgroundColor = NSColor(red: 0.063, green: 0.063, blue: 0.071, alpha: 1)
    let windowChannel = FlutterMethodChannel(
      name: "yomi/window", binaryMessenger: flutterViewController.engine.binaryMessenger)
    windowChannel.setMethodCallHandler { [weak self] call, result in
      switch call.method {
      case "drag":
        if let event = NSApp.currentEvent { self?.performDrag(with: event) }
        result(nil)
      case "zoom":
        self?.zoom(nil)
        result(nil)
      default:
        result(FlutterMethodNotImplemented)
      }
    }
    self.center()
    self.setFrameAutosaveName("YomiMainWindow")

    RegisterGeneratedPlugins(registry: flutterViewController)
    tunnel = TunnelChannel(messenger: flutterViewController.engine.binaryMessenger)

    super.awakeFromNib()
  }
}
