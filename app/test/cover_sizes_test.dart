import 'package:flutter_test/flutter_test.dart';
import 'package:yomi/core/cover_sizes.dart';

void main() {
  test('a song keeps one saved cover whichever form of its ID the server sends', () {
    expect(
      coverCacheKey('mf-2wTG7v993NsjJ7bL6OeFIz_856ea3607b69e089', 240),
      coverCacheKey('mf-2wTG7v993NsjJ7bL6OeFIz', 240),
    );
    expect(
      coverCacheKey('al-7uXoMlwg35hyJgEgXwlniK_265354f2636224', 640),
      coverCacheKey('al-7uXoMlwg35hyJgEgXwlniK', 640),
    );
  });

  test('each size is saved separately', () {
    expect(
      coverCacheKey('mf-abc', 240),
      isNot(coverCacheKey('mf-abc', 640)),
    );
  });

  test('a playlist cover changes with its songs, so its full ID counts', () {
    expect(
      coverCacheKey('pl-abc_65a1b2c3', 240),
      isNot(coverCacheKey('pl-abc_65a1b2c4', 240)),
    );
  });

  test('songs with no cover ID keep their own key', () {
    expect(
      coverCacheKey('missing-Artist-Album-Song_abc123', 240),
      'cover-missing-Artist-Album-Song_abc123-240',
    );
  });

  group('olderCoverKeys', () {
    test('finds covers saved under the other form of an ID', () {
      final found = olderCoverKeys([
        'cover-mf-abc_856ea3607b69e089-240',
        'cover-mf-def-640',
        'cover-pl-xyz_65a1b2c3-240',
      ]);
      expect(found, {
        'cover-mf-abc-240': 'cover-mf-abc_856ea3607b69e089-240',
        'cover-mf-def-640': 'cover-mf-def-640',
        'cover-pl-xyz_65a1b2c3-240': 'cover-pl-xyz_65a1b2c3-240',
      });
    });

    test('ignores anything that isn\'t a cover key', () {
      expect(
        olderCoverKeys([
          'external-https://example.com/a.jpg',
          'http://server/rest/getCoverArt',
          'cover-mf-abc',
        ]),
        isEmpty,
      );
    });
  });
}
