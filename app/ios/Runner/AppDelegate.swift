import Flutter
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  private var tunnel: TunnelChannel?
  private var ytDlp: YtDlpChannel?
  private var push: PushChannel?
  private var iconChannel: FlutterMethodChannel?

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  override func application(
    _ application: UIApplication,
    didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
  ) {
    push?.didRegister(deviceToken: deviceToken)
    super.application(application, didRegisterForRemoteNotificationsWithDeviceToken: deviceToken)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    if let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "AppIconChannel") {
      let channel = FlutterMethodChannel(name: "yomi/app_icon", binaryMessenger: registrar.messenger())
      iconChannel = channel
      channel.setMethodCallHandler { call, result in
        switch call.method {
        case "get": result(UIApplication.shared.alternateIconName ?? "Default")
        case "set":
          guard let name = call.arguments as? String, ["Default", "Midnight", "Sakura"].contains(name), UIApplication.shared.supportsAlternateIcons else {
            result(FlutterError(code: "unsupported", message: "Alternate icons unavailable", details: nil)); return
          }
          UIApplication.shared.setAlternateIconName(name == "Default" ? nil : name) { error in
            if let error = error { result(FlutterError(code: "icon", message: error.localizedDescription, details: nil)) }
            else { result(nil) }
          }
        default: result(FlutterMethodNotImplemented)
        }
      }
    }
    if let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "TunnelChannel") {
      tunnel = TunnelChannel(messenger: registrar.messenger())
    }
    if let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "PushChannel") {
      push = PushChannel(messenger: registrar.messenger())
    }
    if let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "YtDlpChannel") {
      ytDlp = YtDlpChannel(messenger: registrar.messenger())
    }
  }
}
