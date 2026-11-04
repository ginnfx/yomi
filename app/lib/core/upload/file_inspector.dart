import 'dart:io';
import 'dart:isolate';

import 'package:audio_metadata_reader/audio_metadata_reader.dart';
import 'package:convert/convert.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';

const int _chunkBytes = 64 * 1024;

/// File types the server accepts.
const Set<String> kUploadExtensions = {
  'mp3',
  'flac',
  'm4a',
  'aac',
  'ogg',
  'opus',
  'wav',
};

bool hasUploadExtension(String path) {
  final dot = path.lastIndexOf('.');
  return dot >= 0 &&
      kUploadExtensions.contains(path.substring(dot + 1).toLowerCase());
}

/// What Yomi learns about a file before uploading it.
@immutable
class FileFacts {
  const FileFacts({
    required this.sha256,
    this.title,
    this.artist,
    this.durationSeconds = 0,
  });

  factory FileFacts.fromJson(Map<String, dynamic> json) => FileFacts(
    sha256: json['sha256'] as String,
    title: json['title'] as String?,
    artist: json['artist'] as String?,
    durationSeconds: (json['duration'] as num?)?.toInt() ?? 0,
  );

  final String sha256;
  final String? title;
  final String? artist;
  final int durationSeconds;

  Map<String, Object?> toJson() => {
    'sha256': sha256,
    'title': title,
    'artist': artist,
    'duration': durationSeconds,
  };
}

/// Reads a whole file in a background isolate, so hashing thousands of songs
/// never stutters the UI or the music.
Future<FileFacts> inspectFile(String path) => Isolate.run(() => _inspect(path));

FileFacts _inspect(String path) {
  final file = File(path);
  final digest = AccumulatorSink<Digest>();
  final hasher = sha256.startChunkedConversion(digest);
  final handle = file.openSync();
  try {
    while (true) {
      final chunk = handle.readSync(_chunkBytes);
      if (chunk.isEmpty) break;
      hasher.add(chunk);
    }
  } finally {
    handle.closeSync();
  }
  hasher.close();
  final hash = digest.events.single.toString();
  try {
    final metadata = readMetadata(file, getImage: false);
    return FileFacts(
      sha256: hash,
      title: metadata.title,
      artist: metadata.artist,
      durationSeconds: metadata.duration?.inSeconds ?? 0,
    );
  } on Object {
    // Unreadable tags only mean the "likely duplicate" check can't apply.
    return FileFacts(sha256: hash);
  }
}
