import Foundation
import TailscaleBridge
#if os(macOS)
import FlutterMacOS
#else
import Flutter
#endif

/// Runs the embedded Tailscale node off the main thread; joining can take many seconds.
final class TunnelChannel {
  private let channel: FlutterMethodChannel
  private let worker = DispatchQueue(label: "com.yomi.yomi.tunnel")

  init(messenger: FlutterBinaryMessenger) {
    channel = FlutterMethodChannel(name: "com.yomi.yomi/tunnel", binaryMessenger: messenger)
    channel.setMethodCallHandler { [worker] call, result in
      worker.async {
        let reply = TunnelChannel.run(call)
        DispatchQueue.main.async { result(reply) }
      }
    }
  }

  private static func run(_ call: FlutterMethodCall) -> Any? {
    let arguments = call.arguments as? [String: Any] ?? [:]
    var error: NSError?
    var value: Any?
    switch call.method {
    case "start":
      BridgeStart(
        arguments["stateDir"] as? String,
        arguments["authKey"] as? String ?? "",
        arguments["hostname"] as? String,
        &error
      )
    case "forward":
      var port = 0
      BridgeForward(arguments["remote"] as? String, &port, &error)
      value = port
    case "networkChanged":
      BridgeNetworkChanged()
    case "state":
      value = BridgeState()
    case "stop":
      BridgeStop(&error)
    default:
      return FlutterMethodNotImplemented
    }
    if let error {
      return FlutterError(code: "tunnel", message: error.localizedDescription, details: nil)
    }
    return value
  }
}
