import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;

const String kUpdateRepo = 'ginnfx/yomi';
const String kApkAssetName = 'Yomi-android.apk';
const String kApkChecksumAssetName = 'Yomi-android.apk.sha256';
const int kMaxReleaseNotesLength = 4000;

const int _defaultMaxDownloadBytes = 300 * 1024 * 1024;
const Duration _apiTimeout = Duration(seconds: 10);
const Duration _downloadStallTimeout = Duration(seconds: 30);
const String _releasesHost = 'github.com';
const String _releasesPath = '/$kUpdateRepo/releases/';

final RegExp _versionPattern = RegExp(r'^v?(\d+)\.(\d+)\.(\d+)(?:\+\d+)?$');
final RegExp _sha256Pattern = RegExp(r'^[0-9a-f]{64}$');

/// A plain `major.minor.patch` release version. Build numbers are ignored.
class AppVersion {
  const AppVersion(this.major, this.minor, this.patch);

  final int major;
  final int minor;
  final int patch;

  static AppVersion? tryParse(String text) {
    final match = _versionPattern.firstMatch(text.trim());
    if (match == null) return null;
    return AppVersion(
      int.parse(match[1]!),
      int.parse(match[2]!),
      int.parse(match[3]!),
    );
  }

  bool isNewerThan(AppVersion other) {
    if (major != other.major) return major > other.major;
    if (minor != other.minor) return minor > other.minor;
    return patch > other.patch;
  }

  @override
  String toString() => '$major.$minor.$patch';
}

/// A published release. Links are only trusted when they point at this
/// repository's releases over HTTPS, because they decide what gets installed.
class ReleaseInfo {
  const ReleaseInfo({
    required this.version,
    required this.notes,
    required this.pageUrl,
    this.apkUrl,
    this.checksumUrl,
  });

  final AppVersion version;
  final String notes;
  final Uri pageUrl;
  final Uri? apkUrl;
  final Uri? checksumUrl;

  bool get canInstallApk => apkUrl != null && checksumUrl != null;

  static ReleaseInfo? tryParse(Map<String, dynamic> json) {
    final tag = json['tag_name'];
    final page = _trustedUrl(json['html_url']);
    if (tag is! String || page == null) return null;
    final version = AppVersion.tryParse(tag);
    if (version == null) return null;
    final body = json['body'];
    final notes = body is String ? body.trim() : '';
    return ReleaseInfo(
      version: version,
      notes: notes.length > kMaxReleaseNotesLength
          ? notes.substring(0, kMaxReleaseNotesLength)
          : notes,
      pageUrl: page,
      apkUrl: _assetUrl(json['assets'], kApkAssetName),
      checksumUrl: _assetUrl(json['assets'], kApkChecksumAssetName),
    );
  }

  /// Same shape as GitHub's response, so a cached copy goes through the same
  /// validation in [tryParse] as a fresh one.
  Map<String, dynamic> toJson() => {
    'tag_name': 'v$version',
    'body': notes,
    'html_url': pageUrl.toString(),
    'assets': [
      if (apkUrl != null)
        {'name': kApkAssetName, 'browser_download_url': apkUrl.toString()},
      if (checksumUrl != null)
        {
          'name': kApkChecksumAssetName,
          'browser_download_url': checksumUrl.toString(),
        },
    ],
  };

  static Uri? _assetUrl(Object? assets, String name) {
    if (assets is! List) return null;
    for (final asset in assets) {
      if (asset is Map && asset['name'] == name) {
        return _trustedUrl(asset['browser_download_url']);
      }
    }
    return null;
  }

  static Uri? _trustedUrl(Object? value) {
    // Encoded characters could hide path traversal, and no real asset link has any.
    if (value is! String || value.contains('%')) return null;
    final uri = Uri.tryParse(value);
    if (uri == null ||
        uri.scheme != 'https' ||
        uri.host != _releasesHost ||
        uri.hasPort ||
        uri.userInfo.isNotEmpty ||
        !uri.path.startsWith(_releasesPath)) {
      return null;
    }
    return uri;
  }
}

/// A failed update step. [message] is written for people, not logs.
class UpdateException implements Exception {
  const UpdateException(this.message);

  final String message;

  @override
  String toString() => message;
}

class UpdateClient {
  UpdateClient({
    http.Client? client,
    this.maxDownloadBytes = _defaultMaxDownloadBytes,
  }) : _client = client ?? http.Client();

  final http.Client _client;
  final int maxDownloadBytes;

  Future<ReleaseInfo> fetchLatest() async {
    final body = await _getText(
      Uri.parse('https://api.github.com/repos/$kUpdateRepo/releases/latest'),
      accept: 'application/vnd.github+json',
    );
    final Object? json;
    try {
      json = jsonDecode(body);
    } on FormatException {
      throw const UpdateException('The update information was unreadable.');
    }
    final release = json is Map<String, dynamic>
        ? ReleaseInfo.tryParse(json)
        : null;
    if (release == null) {
      throw const UpdateException('The update information was unreadable.');
    }
    return release;
  }

  /// Reads the hash from `sha256sum` style output: `<hash>  <filename>`.
  Future<String> fetchChecksum(Uri url) async {
    final text = await _getText(url);
    final fields = text.trim().split(RegExp(r'\s+'));
    final hash = fields.first.toLowerCase();
    if (!_sha256Pattern.hasMatch(hash)) {
      throw const UpdateException(
        "The update couldn't be verified, so it wasn't installed.",
      );
    }
    return hash;
  }

  /// Returns [destination] only once its contents match [expectedSha256].
  /// Writes to a side file first, so a failure never leaves a partial APK.
  Future<File> downloadVerified(
    Uri url, {
    required String expectedSha256,
    required File destination,
    void Function(double? fraction)? onProgress,
  }) async {
    if (await _matches(destination, expectedSha256)) {
      onProgress?.call(1);
      return destination;
    }
    await destination.parent.create(recursive: true);
    final partial = File('${destination.path}.part');
    try {
      final hash = await _streamToFile(url, partial, onProgress);
      if (hash != expectedSha256) {
        throw const UpdateException(
          "The update couldn't be verified, so it wasn't installed.",
        );
      }
      return await partial.rename(destination.path);
    } on UpdateException {
      await _deleteIfPresent(partial);
      rethrow;
    } on Exception {
      await _deleteIfPresent(partial);
      throw const UpdateException(
        "Yomi couldn't download the update. Check your connection and try again.",
      );
    }
  }

  Future<String> _streamToFile(
    Uri url,
    File target,
    void Function(double? fraction)? onProgress,
  ) async {
    final response = await _client.send(_request(url)).timeout(_apiTimeout);
    if (response.statusCode != 200) {
      throw const UpdateException(
        "Yomi couldn't download the update. Try again later.",
      );
    }
    final total = response.contentLength;
    final digest = _DigestSink();
    final hasher = sha256.startChunkedConversion(digest);
    final sink = target.openWrite();
    var received = 0;
    try {
      await for (final chunk in response.stream.timeout(_downloadStallTimeout)) {
        received += chunk.length;
        if (received > maxDownloadBytes) {
          throw const UpdateException('The update was larger than expected.');
        }
        hasher.add(chunk);
        sink.add(chunk);
        onProgress?.call(total == null || total == 0 ? null : received / total);
      }
    } finally {
      await sink.close();
    }
    hasher.close();
    return digest.value.toString();
  }

  Future<bool> _matches(File file, String expectedSha256) async {
    if (!await file.exists()) return false;
    final digest = await sha256.bind(file.openRead()).first;
    return digest.toString() == expectedSha256;
  }

  Future<void> _deleteIfPresent(File file) async {
    if (await file.exists()) await file.delete();
  }

  Future<String> _getText(Uri url, {String? accept}) async {
    final request = _request(url);
    if (accept != null) request.headers['Accept'] = accept;
    final http.StreamedResponse response;
    try {
      response = await _client.send(request).timeout(_apiTimeout);
    } on Exception {
      throw const UpdateException("Yomi couldn't check for updates.");
    }
    if (response.statusCode != 200) {
      throw UpdateException(
        "Yomi couldn't check for updates (HTTP ${response.statusCode}).",
      );
    }
    return response.stream.bytesToString().timeout(_apiTimeout);
  }

  http.Request _request(Uri url) =>
      http.Request('GET', url)..headers['User-Agent'] = 'Yomi-app';
}

class _DigestSink implements Sink<Digest> {
  late Digest value;

  @override
  void add(Digest data) => value = data;

  @override
  void close() {}
}
