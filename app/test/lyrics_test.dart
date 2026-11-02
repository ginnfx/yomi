import 'package:flutter_test/flutter_test.dart';
import 'package:yomi/core/lyrics.dart';

void main() {
  test('parses timed lines in order and ignores metadata tags', () {
    final lyrics = Lyrics.parseLrc(
      '[ar:Someone]\n[00:12.50]first\n[01:02.5]second\n[00:05.00]zero',
    );
    expect(lyrics.isSynced, isTrue);
    expect(lyrics.lines.map((l) => l.text), ['zero', 'first', 'second']);
    expect(
      lyrics.lines[1].start,
      const Duration(seconds: 12, milliseconds: 500),
    );
  });

  test('plain text becomes unsynced lines', () {
    final lyrics = Lyrics.parsePlain('one\n\ntwo');
    expect(lyrics.isSynced, isFalse);
    expect(lyrics.lines.map((l) => l.text), ['one', '', 'two']);
  });

  test('activeIndex follows the position', () {
    final lyrics = Lyrics.parseLrc('[00:10.00]a\n[00:20.00]b');
    expect(lyrics.activeIndex(const Duration(seconds: 3)), -1);
    expect(lyrics.activeIndex(const Duration(seconds: 10)), 0);
    expect(lyrics.activeIndex(const Duration(seconds: 25)), 1);
  });

  test('multiple stamps on one line repeat it', () {
    final lyrics = Lyrics.parseLrc('[00:01.00][00:09.00]chorus');
    expect(lyrics.lines.length, 2);
  });
}
