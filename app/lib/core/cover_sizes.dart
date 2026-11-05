/// Cover art is requested in two fixed sizes so the on-disk image cache gets hits
/// and downloaded songs can have both sizes ready for offline use.
const int smallCoverPx = 240;
const int largeCoverPx = 640;
const double _smallCoverMaxLogical = 120;

int coverPixelsFor(double logicalSize) =>
    logicalSize <= _smallCoverMaxLogical ? smallCoverPx : largeCoverPx;

/// The server sometimes adds a suffix to a song's or album's cover ID and sometimes
/// doesn't, for the same picture. Playlists are left out, as their cover really does
/// change with their songs.
final RegExp _suffixedCoverId = RegExp(r'^((?:mf|al)-[A-Za-z0-9]+)_[0-9a-f]+$');

final RegExp _savedCoverKey = RegExp(r'^cover-(.+)-(\d+)$');

/// Ignores that suffix, so a cover saved once is found whichever ID the server sends.
String coverCacheKey(String coverArtId, int pixels) {
  final id = _suffixedCoverId.firstMatch(coverArtId)?.group(1) ?? coverArtId;
  return 'cover-$id-$pixels';
}

/// Maps today's key for each cover to the key it was saved under, so covers saved by
/// earlier versions don't need downloading again.
Map<String, String> olderCoverKeys(Iterable<String> savedKeys) => {
  for (final key in savedKeys)
    if (_savedCoverKey.firstMatch(key) case final match?)
      coverCacheKey(match.group(1)!, int.parse(match.group(2)!)): key,
};
