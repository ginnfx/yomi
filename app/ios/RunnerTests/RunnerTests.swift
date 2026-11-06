import Flutter
import UIKit
import XCTest

@testable import Runner

class RunnerTests: XCTestCase {
  func testReadsTheSearchDartBuilds() {
    // Arrange
    let args = ["--ignore-config", "--flat-playlist", "--dump-json", "--no-warnings", "ytsearch5:Mira - Blue Hour"]

    // Act
    let command = YtDlpCommand(args)

    // Assert
    XCTAssertEqual(command, .search(query: "Mira - Blue Hour", count: 5))
  }

  func testReadsTheDownloadDartBuilds() {
    // Arrange
    let args = [
      "--ignore-config", "-f", "bestaudio", "--no-playlist", "--newline",
      "-o", "/cache/%(id)s.%(ext)s", "--print", "after_move:filepath",
      "https://www.youtube.com/watch?v=em0MknB6wFo",
    ]

    // Act
    let command = YtDlpCommand(args)

    // Assert
    XCTAssertEqual(command, .download(videoID: "em0MknB6wFo", template: "/cache/%(id)s.%(ext)s"))
  }

  func testRefusesADownloadWithABadVideoID() {
    // Arrange
    let args = ["-o", "/cache/%(id)s.%(ext)s", "https://www.youtube.com/watch?v=../../etc"]

    // Act
    let command = YtDlpCommand(args)

    // Assert
    XCTAssertEqual(command, .unsupported)
  }

  func testReadsVersion() {
    XCTAssertEqual(YtDlpCommand(["--ignore-config", "--version"]), .version)
  }

  func testParsesInnerTubeVideos() {
    // Arrange
    let payload: [String: Any] = ["contents": [
      ["videoRenderer": [
        "videoId": "em0MknB6wFo",
        "title": ["runs": [["text": "Blue Hour"]]],
        "ownerText": ["runs": [["text": "Mira"]]],
        "lengthText": ["simpleText": "3:45"],
      ]],
      ["videoRenderer": ["videoId": "em0MknB6wFo", "title": ["simpleText": "Duplicate"]]],
      ["adRenderer": ["videoId": "notavideo"]],
    ]]

    // Act
    let videos = YoutubeSearch.parse(payload)

    // Assert
    XCTAssertEqual(videos, [YoutubeVideo(id: "em0MknB6wFo", title: "Blue Hour", channel: "Mira", durationSeconds: 225)])
  }

  func testReadsLengthsAndContentRanges() {
    XCTAssertEqual(YoutubeSearch.seconds("1:02:03"), 3723)
    XCTAssertNil(YoutubeSearch.seconds("LIVE"))
    XCTAssertEqual(YoutubeAudioDownload.totalSize("bytes 0-1023/4096"), 4096)
    XCTAssertNil(YoutubeAudioDownload.totalSize(nil))
  }

  func testPrintsSearchResultsAsYtDlpJSON() throws {
    // Arrange
    let video = YoutubeVideo(id: "em0MknB6wFo", title: "Blue Hour", channel: "Mira", durationSeconds: 225)

    // Act
    let json = try JSONSerialization.jsonObject(with: Data(video.jsonLine.utf8)) as? [String: Any]

    // Assert
    XCTAssertEqual(json?["id"] as? String, "em0MknB6wFo")
    XCTAssertEqual(json?["duration"] as? Int, 225)
  }
}
