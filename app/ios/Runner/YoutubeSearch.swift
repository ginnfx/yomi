import Foundation

/// One search result, printed the way `yt-dlp --flat-playlist --dump-json` prints it.
struct YoutubeVideo: Equatable {
  let id: String
  let title: String
  let channel: String
  let durationSeconds: Int?

  var jsonLine: String {
    var object: [String: Any] = ["id": id, "title": title, "channel": channel]
    if let durationSeconds { object["duration"] = durationSeconds }
    guard let data = try? JSONSerialization.data(withJSONObject: object),
          let line = String(data: data, encoding: .utf8) else { return "" }
    return line
  }
}

/// Searches YouTube through InnerTube, the JSON endpoint youtube.com itself calls.
/// Its results page can be a consent page on a phone; this endpoint isn't.
enum YoutubeSearch {
  private static let endpoint = URL(string: "https://www.youtube.com/youtubei/v1/search?prettyPrint=false")!
  private static let clientVersion = "2.20260708.00.00"
  private static let timeout: TimeInterval = 10

  static func videos(matching query: String, limit: Int) async throws -> [YoutubeVideo] {
    var request = URLRequest(url: endpoint, timeoutInterval: timeout)
    request.httpMethod = "POST"
    request.httpBody = try JSONSerialization.data(withJSONObject: [
      "context": ["client": [
        "clientName": "WEB", "clientVersion": clientVersion, "hl": "en", "gl": "US",
      ]],
      "query": query,
    ])
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue("1", forHTTPHeaderField: "X-YouTube-Client-Name")
    request.setValue(clientVersion, forHTTPHeaderField: "X-YouTube-Client-Version")
    request.setValue("https://www.youtube.com", forHTTPHeaderField: "Origin")
    request.setValue("Mozilla/5.0", forHTTPHeaderField: "User-Agent")

    let (data, response) = try await URLSession.shared.data(for: request)
    guard (response as? HTTPURLResponse)?.statusCode == 200,
          let payload = try? JSONSerialization.jsonObject(with: data) else {
      throw YtDlpError.searchFailed
    }
    return Array(parse(payload).prefix(limit))
  }

  /// Every video in a search response, in order, each once.
  static func parse(_ payload: Any) -> [YoutubeVideo] {
    var found: [YoutubeVideo] = []
    var seen = Set<String>()
    collect(payload, into: &found, seen: &seen)
    return found
  }

  private static func collect(_ value: Any, into found: inout [YoutubeVideo], seen: inout Set<String>) {
    if let object = value as? [String: Any] {
      if let renderer = object["videoRenderer"] as? [String: Any],
         let video = video(from: renderer),
         seen.insert(video.id).inserted {
        found.append(video)
      }
      for nested in object.values { collect(nested, into: &found, seen: &seen) }
    } else if let array = value as? [Any] {
      for nested in array { collect(nested, into: &found, seen: &seen) }
    }
  }

  private static func video(from renderer: [String: Any]) -> YoutubeVideo? {
    guard let id = renderer["videoId"] as? String, YtDlpCommand.isVideoID(id),
          let title = text(renderer["title"]) else { return nil }
    let channel = text(renderer["ownerText"]) ?? text(renderer["longBylineText"]) ?? ""
    let length = (renderer["lengthText"] as? [String: Any])?["simpleText"] as? String
    return YoutubeVideo(id: id, title: title, channel: channel, durationSeconds: length.flatMap(seconds))
  }

  /// InnerTube text is either `{simpleText}` or `{runs: [{text}]}`.
  private static func text(_ value: Any?) -> String? {
    guard let object = value as? [String: Any] else { return nil }
    if let simple = object["simpleText"] as? String { return simple }
    let runs = (object["runs"] as? [[String: Any]])?.compactMap { $0["text"] as? String }
    return runs.flatMap { $0.isEmpty ? nil : $0.joined() }
  }

  /// "1:02:03" or "3:45" in seconds.
  static func seconds(_ length: String) -> Int? {
    let parts = length.split(separator: ":").map { Int($0) }
    guard !parts.isEmpty, parts.count <= 3, !parts.contains(nil) else { return nil }
    return parts.compactMap { $0 }.reduce(0) { $0 * 60 + $1 }
  }
}
