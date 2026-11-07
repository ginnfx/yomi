import Foundation
@preconcurrency import YouTubeKit

/// Saves a video's audio to a file, m4a when YouTube has it. It asks for the file in
/// ranges like yt-dlp does: YouTube cuts off a single request for a whole file.
enum YoutubeAudioDownload {
  private static let chunkBytes = 10 * 1_024 * 1_024
  private static let maxBytes = 250 * 1_024 * 1_024
  private static let attemptsPerChunk = 3
  private static let timeout: TimeInterval = 30

  /// Downloads [videoID] to [template] (yt-dlp's `%(id)s.%(ext)s` form) and returns
  /// the file's path. [onProgress] gets 0 to 100.
  static func run(
    videoID: String,
    template: String,
    onProgress: @escaping (Double) -> Void
  ) async throws -> String {
    let stream = try await bestAudio(videoID)
    let ext = stream.fileExtension.rawValue
    let path = template
      .replacingOccurrences(of: "%(id)s", with: videoID)
      .replacingOccurrences(of: "%(ext)s", with: ext)
    let destination = URL(fileURLWithPath: path)
    let partial = destination.appendingPathExtension("part")
    let files = FileManager.default
    try files.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
    try? files.removeItem(at: partial)
    guard files.createFile(atPath: partial.path, contents: nil) else {
      throw YtDlpError.downloadFailed("can't write to the cache")
    }
    do {
      try await fetch(stream.url, into: partial, onProgress: onProgress)
      try? files.removeItem(at: destination)
      try files.moveItem(at: partial, to: destination)
    } catch {
      try? files.removeItem(at: partial)
      throw error
    }
    return destination.path
  }

  private static func bestAudio(_ videoID: String) async throws -> YouTubeKit.Stream {
    guard let url = URL(string: "https://www.youtube.com/watch?v=\(videoID)") else {
      throw YtDlpError.noAudio
    }
    let streams = try await YouTube(url: url, methods: [.local]).streams
    let acceptedExtensions: Set<String> = ["m4a", "aac", "mp3", "ogg", "opus", "flac", "wav"]
    let audio = streams.filterAudioOnly().filter {
      $0.isNativelyPlayable && acceptedExtensions.contains($0.fileExtension.rawValue)
    }
    let m4a = audio.filter { $0.fileExtension == .m4a }
    guard let stream = m4a.highestAudioBitrateStream() ?? audio.highestAudioBitrateStream() else {
      throw YtDlpError.noAudio
    }
    return stream
  }

  private static func fetch(_ url: URL, into file: URL, onProgress: (Double) -> Void) async throws {
    let handle = try FileHandle(forWritingTo: file)
    defer { try? handle.close() }
    var written = 0
    var total: Int?
    while total.map({ written < $0 }) ?? true {
      let end = written + chunkBytes - 1
      let (data, size) = try await chunk(url, from: written, to: end)
      guard !data.isEmpty else { break }
      try handle.write(contentsOf: data)
      written += data.count
      // An unknown size ("bytes a-b/*") only ends on a short chunk; never assume it ended.
      total = size ?? (data.count < chunkBytes ? written : nil)
      guard written <= maxBytes, (total ?? 0) <= maxBytes else { throw YtDlpError.tooLarge }
      onProgress(Double(written) / Double(max(total ?? written, 1)) * 100)
    }
    guard written > 0 else { throw YtDlpError.downloadFailed("empty file") }
  }

  /// One range of the file and the whole file's size, retried a few times.
  private static func chunk(_ url: URL, from start: Int, to end: Int) async throws -> (Data, Int?) {
    var lastError: Error = YtDlpError.downloadFailed("no response")
    for _ in 0..<attemptsPerChunk {
      var request = URLRequest(url: url, timeoutInterval: timeout)
      request.setValue("bytes=\(start)-\(end)", forHTTPHeaderField: "Range")
      do {
        let (data, response) = try await URLSession.shared.data(for: request)
        let http = response as? HTTPURLResponse
        switch http?.statusCode {
        case 206:
          let range = http?.value(forHTTPHeaderField: "Content-Range")
          // A body shorter than the range it claims was cut off; retry rather than keep it.
          guard let expected = rangeLength(range), expected == data.count else {
            lastError = YtDlpError.downloadFailed("incomplete download")
            continue
          }
          return (data, totalSize(range))
        case 200 where start == 0:
          // The server ignored the range and sent the whole file.
          return (data, data.count)
        case let code:
          lastError = YtDlpError.downloadFailed("HTTP \(code ?? 0)")
        }
      } catch {
        lastError = error
      }
    }
    throw lastError
  }

  /// The byte count a Content-Range such as "bytes 0-1023/4096" promises (1024).
  static func rangeLength(_ contentRange: String?) -> Int? {
    guard let span = contentRange?.split(separator: " ").last?.split(separator: "/").first else {
      return nil
    }
    let ends = span.split(separator: "-").compactMap { Int($0) }
    guard ends.count == 2, ends[1] >= ends[0] else { return nil }
    return ends[1] - ends[0] + 1
  }

  /// The size after the slash in "bytes 0-1023/4096".
  static func totalSize(_ contentRange: String?) -> Int? {
    contentRange?.split(separator: "/").last.flatMap { Int($0) }
  }
}
