import Flutter
import Foundation

/// yt-dlp for the iPhone, which can't run Python. It answers the two commands Dart
/// builds (a `ytsearchN:` search and an audio download) with the Swift YouTubeKit
/// extractor, and prints what yt-dlp would print, so the Dart side is the same as on
/// Android: JSON lines for a search, `download:NN%` lines, then the file's path.
final class YtDlpChannel {
  static let version = "YouTubeKit 0.4.10"

  private let channel: FlutterMethodChannel

  init(messenger: FlutterBinaryMessenger) {
    channel = FlutterMethodChannel(name: "com.yomi.yomi/ytdlp", binaryMessenger: messenger)
    channel.setMethodCallHandler { [weak self] call, result in
      self?.handle(call, result: result)
    }
  }

  private func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "run":
      let arguments = call.arguments as? [String: Any] ?? [:]
      guard let args = arguments["args"] as? [String] else {
        result(FlutterError(code: "bad_args", message: "No arguments", details: nil))
        return
      }
      let job = arguments["job"] as? String ?? UUID().uuidString
      Task { await self.run(args, job: job, result: result) }
    case "update":
      // The extractor is compiled into the app, so it updates with the app.
      result(nil)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private func run(_ args: [String], job: String, result: @escaping FlutterResult) async {
    do {
      let out = try await perform(YtDlpCommand(args), job: job)
      await MainActor.run { result(out) }
    } catch {
      let message = (error as? LocalizedError)?.errorDescription ?? "\(error)"
      await MainActor.run {
        result(FlutterError(code: "failed", message: message, details: nil))
      }
    }
  }

  private func perform(_ command: YtDlpCommand, job: String) async throws -> String {
    switch command {
    case .version:
      return YtDlpChannel.version
    case let .search(query, count):
      let videos = try await YoutubeSearch.videos(matching: query, limit: count)
      return videos.map(\.jsonLine).joined(separator: "\n")
    case let .download(videoID, template):
      let path = try await YoutubeAudioDownload.run(
        videoID: videoID,
        template: template,
        onProgress: { [weak self] percent in
          self?.send(String(format: "download: %.1f%%", percent), job: job)
        }
      )
      send(path, job: job)
      return path
    case .unsupported:
      throw YtDlpError.unsupported
    }
  }

  private func send(_ line: String, job: String) {
    DispatchQueue.main.async { [channel] in
      channel.invokeMethod("line", arguments: ["job": job, "line": line])
    }
  }
}

/// The yt-dlp command lines Dart sends, read back into what they ask for.
enum YtDlpCommand: Equatable {
  case version
  case search(query: String, count: Int)
  case download(videoID: String, template: String)
  case unsupported

  init(_ args: [String]) {
    if args.contains("--version") {
      self = .version
    } else if let search = args.first(where: { $0.hasPrefix("ytsearch") }) {
      self = YtDlpCommand.search(from: search)
    } else if let output = args.firstIndex(of: "-o").map({ $0 + 1 }),
              output < args.count,
              let url = args.last.flatMap(URLComponents.init(string:)),
              let id = url.queryItems?.first(where: { $0.name == "v" })?.value,
              YtDlpCommand.isVideoID(id) {
      self = .download(videoID: id, template: args[output])
    } else {
      self = .unsupported
    }
  }

  private static func search(from text: String) -> YtDlpCommand {
    // "ytsearch5:artist - title": the count sits between the prefix and the colon.
    guard let colon = text.firstIndex(of: ":") else { return .unsupported }
    let count = Int(text[text.index(text.startIndex, offsetBy: 8)..<colon]) ?? 1
    let query = String(text[text.index(after: colon)...])
    return query.isEmpty ? .unsupported : .search(query: query, count: max(1, min(count, 20)))
  }

  static func isVideoID(_ id: String) -> Bool {
    (6...20).contains(id.count)
      && id.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }
  }
}

enum YtDlpError: LocalizedError {
  case unsupported
  case searchFailed
  case noAudio
  case downloadFailed(String)
  case tooLarge

  var errorDescription: String? {
    switch self {
    case .unsupported: "This yt-dlp command isn't supported on iPhone"
    case .searchFailed: "YouTube search is unavailable right now"
    case .noAudio: "YouTube returned no playable audio for this video"
    case let .downloadFailed(reason): "Couldn't download from YouTube: \(reason)"
    case .tooLarge: "The file is too large for a song"
    }
  }
}
