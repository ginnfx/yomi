/// Turns a GitHub release description (Markdown) into short plain lines for a
/// "What's new" list: bullets become "•", headings and emphasis lose their
/// symbols, and boilerplate links are dropped.
List<String> releaseNoteLines(String notes) {
  final lines = <String>[];
  for (final raw in notes.split('\n')) {
    var line = raw.trim();
    if (line.isEmpty) {
      if (lines.isNotEmpty && lines.last.isNotEmpty) lines.add('');
      continue;
    }
    if (_isBoilerplate(line)) continue;
    line = line
        .replaceFirst(RegExp(r'^#{1,6}\s*'), '')
        .replaceFirstMapped(RegExp(r'^[-*+]\s+'), (_) => '• ')
        .replaceAllMapped(RegExp(r'\*\*(.+?)\*\*'), (m) => m[1]!)
        .replaceAllMapped(RegExp(r'__(.+?)__'), (m) => m[1]!)
        .replaceAllMapped(RegExp(r'`([^`]+)`'), (m) => m[1]!)
        .replaceAllMapped(RegExp(r'\[([^\]]+)\]\([^)]+\)'), (m) => m[1]!);
    lines.add(line);
  }
  while (lines.isNotEmpty && lines.last.isEmpty) {
    lines.removeLast();
  }
  return lines;
}

bool _isBoilerplate(String line) {
  final lower = line.toLowerCase();
  return lower.startsWith('**full changelog') ||
      lower.startsWith('full changelog') ||
      lower.startsWith('sha256') ||
      lower.startsWith('checksums') ||
      RegExp(r'^[-*_]{3,}$').hasMatch(line);
}

/// The first useful line, for a one-line preview.
String releaseNotePreview(String notes) {
  for (final line in releaseNoteLines(notes)) {
    if (line.isEmpty) continue;
    return line.startsWith('• ') ? line.substring(2) : line;
  }
  return '';
}
