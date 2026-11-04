import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow {
  private var tunnel: TunnelChannel?

  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)
    self.setContentSize(NSSize(width: 1180, height: 800))
    self.contentMinSize = NSSize(width: 720, height: 640)
    self.title = "Yomi"
    self.center()
    self.setFrameAutosaveName("YomiMainWindow")

    RegisterGeneratedPlugins(registry: flutterViewController)
    tunnel = TunnelChannel(messenger: flutterViewController.engine.binaryMessenger)

    super.awakeFromNib()
  }
}
