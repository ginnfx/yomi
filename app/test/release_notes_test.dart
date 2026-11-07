import 'package:flutter_test/flutter_test.dart';
import 'package:yomi/core/release_notes.dart';

void main() {
  test('turns Markdown into plain lines with bullets', () {
    const notes = '''
## What's new

- **Faster** lyrics
* Tap [Home](https://example.com) to go up
- `Messages` look better

**Full Changelog**: https://github.com/x/y/compare/a...b
''';

    expect(releaseNoteLines(notes), [
      "What's new",
      '',
      '• Faster lyrics',
      '• Tap Home to go up',
      '• Messages look better',
    ]);
  });

  test('preview is the first real line without its bullet', () {
    expect(releaseNotePreview('# 1.2\n- Timed lyrics for more songs'), '1.2');
    expect(
      releaseNotePreview('- Timed lyrics for more songs'),
      'Timed lyrics for more songs',
    );
    expect(releaseNotePreview(''), '');
  });
}
