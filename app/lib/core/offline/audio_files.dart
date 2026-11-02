import 'dart:io';
import 'dart:typed_data';

/// File types the app stores. iOS decides how to open a file from its extension, so
/// every saved song must carry the right one (a generic ".audio" cannot be played).
const List<String> audioExtensions = [
  'm4a',
  'mp3',
  'flac',
  'ogg',
  'wav',
  'aac',
];

const int _sniffBytes = 12;

/// Works out the file type from the first bytes of the file, or null if unrecognised.
String? sniffExtension(List<int> h) {
  if (h.length >= 8 &&
      h[4] == 0x66 &&
      h[5] == 0x74 &&
      h[6] == 0x79 &&
      h[7] == 0x70)
    return 'm4a'; // "ftyp"
  if (h.length >= 3 && h[0] == 0x49 && h[1] == 0x44 && h[2] == 0x33)
    return 'mp3'; // "ID3"
  if (h.length >= 4 &&
      h[0] == 0x66 &&
      h[1] == 0x4C &&
      h[2] == 0x61 &&
      h[3] == 0x43)
    return 'flac'; // "fLaC"
  if (h.length >= 4 &&
      h[0] == 0x4F &&
      h[1] == 0x67 &&
      h[2] == 0x67 &&
      h[3] == 0x53)
    return 'ogg'; // "OggS"
  if (h.length >= 12 &&
      h[0] == 0x52 &&
      h[1] == 0x49 &&
      h[2] == 0x46 &&
      h[3] == 0x46 &&
      h[8] == 0x57 &&
      h[9] == 0x41)
    return 'wav';
  if (h.length >= 2 && h[0] == 0xFF && (h[1] & 0xE0) == 0xE0) {
    final layer = (h[1] >> 1) & 0x03;
    return layer == 0 ? 'aac' : 'mp3'; // MPEG audio frame vs raw ADTS AAC
  }
  return null;
}

Future<String?> sniffFile(File file) async {
  final builder = BytesBuilder(copy: false);
  await for (final chunk in file.openRead(0, _sniffBytes)) {
    builder.add(chunk);
  }
  return sniffExtension(builder.takeBytes());
}

String safeFileId(String id) => id.replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '_');

/// The saved copy of [id] inside [directory], whatever its extension, or null.
File? findAudioFile(Directory directory, String id) {
  final base = '${directory.path}/${safeFileId(id)}';
  for (final ext in audioExtensions) {
    final file = File('$base.$ext');
    if (file.existsSync()) return file;
  }
  return null;
}

bool hasAudioExtension(String path) =>
    audioExtensions.any((ext) => path.toLowerCase().endsWith('.$ext'));
