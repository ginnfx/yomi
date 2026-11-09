/// Cover art is requested in two fixed sizes so the on-disk image cache gets hits
/// and downloaded songs can have both sizes ready for offline use.
const int smallCoverPx = 240;
const int largeCoverPx = 640;
const double _smallCoverMaxLogical = 120;

int coverPixelsFor(double logicalSize) =>
    logicalSize <= _smallCoverMaxLogical ? smallCoverPx : largeCoverPx;

/// Artwork IDs include a content version. Keep it so repaired covers replace old art.
/// A new namespace also avoids reusing images saved with the old stripped-ID keys.
String coverCacheKey(String coverArtId, int pixels) =>
    'cover-v2-$coverArtId-$pixels';

final RegExp _savedCoverKey = RegExp(r'^cover-(.+)-(\d+)$');
final RegExp _versionedCoverId = RegExp(r'^(?:mf|al|pl)-.+_[0-9a-f]+$');

/// Only migrate legacy keys that still identify their exact artwork version.
/// Unversioned legacy entries may contain an arbitrary old cover and are refetched.
Map<String, String> olderCoverKeys(Iterable<String> savedKeys) => {
  for (final key in savedKeys)
    if (_savedCoverKey.firstMatch(key) case final match?)
      if (match.group(1)!.startsWith('v2-'))
        key: key
      else if (_versionedCoverId.hasMatch(match.group(1)!))
        coverCacheKey(match.group(1)!, int.parse(match.group(2)!)): key,
};
