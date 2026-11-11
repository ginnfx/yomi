/// Cover art is requested in two fixed sizes so the on-disk image cache gets hits
/// and downloaded songs can have both sizes ready for offline use.
const int smallCoverPx = 240;
const int largeCoverPx = 640;
const double _smallCoverMaxLogical = 120;

int coverPixelsFor(double logicalSize) =>
    logicalSize <= _smallCoverMaxLogical ? smallCoverPx : largeCoverPx;

final RegExp _savedCoverKey = RegExp(r'^cover-(.+)-(\d+)$');
final RegExp _revisionKey = RegExp(
  r'^cover-((?:mf|al)-[A-Za-z0-9]+)_[0-9a-f]+-(\d+)$',
);

/// Legacy artwork may be shown offline while the current revision is fetched,
/// but must never be promoted into the current revision's cache entry.
String? legacyCoverCacheKey(String cacheKey) {
  final match = _revisionKey.firstMatch(cacheKey);
  return match == null ? null : 'cover-${match.group(1)}-${match.group(2)}';
}

/// Preserve the artwork revision: corrected art must not reuse an older picture.
String coverCacheKey(String coverArtId, int pixels) {
  return 'cover-$coverArtId-$pixels';
}

/// Maps today's key for each cover to the key it was saved under, so covers saved by
/// earlier versions don't need downloading again.
Map<String, String> olderCoverKeys(Iterable<String> savedKeys) => {
  for (final key in savedKeys)
    if (_savedCoverKey.firstMatch(key) case final match?)
      coverCacheKey(match.group(1)!, int.parse(match.group(2)!)): key,
};
