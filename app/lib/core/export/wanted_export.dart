import 'dart:convert';

import '../reports/reports_api.dart';

/// How a list of wanted songs can be saved, to feed into another tool.
enum WantedFormat { text, csv, json }

/// A file ready to share or copy.
class ExportedFile {
  const ExportedFile({
    required this.name,
    required this.mimeType,
    required this.content,
  });

  final String name;
  final String mimeType;
  final String content;
}

const String _baseName = 'yomi-wanted-songs';

/// Characters that make a spreadsheet read a cell as a formula.
const String _formulaStarts = '=+-@\t\r';

ExportedFile exportWanted(List<WantedSong> songs, WantedFormat format) =>
    switch (format) {
      WantedFormat.text => ExportedFile(
        name: '$_baseName.txt',
        mimeType: 'text/plain',
        content: _text(songs),
      ),
      WantedFormat.csv => ExportedFile(
        name: '$_baseName.csv',
        mimeType: 'text/csv',
        content: _csv(songs),
      ),
      WantedFormat.json => ExportedFile(
        name: '$_baseName.json',
        mimeType: 'application/json',
        content: _json(songs),
      ),
    };

/// "Artist - Title", one per line: what most downloaders and playlist tools expect.
String _text(List<WantedSong> songs) => [
  for (final song in songs)
    '${_oneLine(song.artist)} - ${_oneLine(song.title)}\n',
].join();

String _oneLine(String text) => text.replaceAll(RegExp(r'\s*[\r\n]+\s*'), ' ');

String _csv(List<WantedSong> songs) {
  final rows = [
    'artist,title,wanted_by',
    for (final song in songs)
      '${_cell(song.artist)},${_cell(song.title)},${song.count}',
  ];
  return '${rows.join('\r\n')}\r\n';
}

/// Quotes a value when it needs it, and defuses one a spreadsheet would run as a formula.
String _cell(String value) {
  final safe = value.isNotEmpty && _formulaStarts.contains(value[0])
      ? "'$value"
      : value;
  final needsQuotes = safe.contains(RegExp(r'[",\r\n]'));
  return needsQuotes ? '"${safe.replaceAll('"', '""')}"' : safe;
}

String _json(List<WantedSong> songs) =>
    const JsonEncoder.withIndent('  ').convert([
      for (final song in songs)
        {'artist': song.artist, 'title': song.title, 'wantedBy': song.count},
    ]);
