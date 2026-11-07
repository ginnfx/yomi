import Flutter
import UIKit

/// Gets this phone's Apple push token and hands it to Dart, which gives it to the
/// Yomi server. The server then pushes to Apple directly, with no Firebase.
final class PushChannel {
  private let channel: FlutterMethodChannel
  private var lastToken: String?

  init(messenger: FlutterBinaryMessenger) {
    channel = FlutterMethodChannel(name: "yomi/push", binaryMessenger: messenger)
    channel.setMethodCallHandler { [weak self] call, result in
      switch call.method {
      case "register":
        DispatchQueue.main.async {
          UIApplication.shared.registerForRemoteNotifications()
          // A token from earlier in this launch is sent again to a late listener.
          if let token = self?.lastToken { self?.send(token) }
          result(nil)
        }
      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }

  func didRegister(deviceToken: Data) {
    let token = deviceToken.map { String(format: "%02x", $0) }.joined()
    lastToken = token
    send(token)
  }

  private func send(_ token: String) {
    channel.invokeMethod("token", arguments: ["token": token, "environment": PushChannel.environment])
  }

  /// Phones installed from Xcode use Apple's test push servers; TestFlight and the
  /// App Store use the real ones. The build says which, in its provisioning profile.
  static var environment: String {
    guard
      let url = Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision"),
      let data = try? Data(contentsOf: url),
      let text = String(data: data, encoding: .isoLatin1)
    else { return "production" }
    return text.contains("<key>aps-environment</key>\n\t\t<string>development</string>")
      || text.range(of: #"aps-environment</key>\s*<string>development"#, options: .regularExpression) != nil
      ? "sandbox" : "production"
  }
}
