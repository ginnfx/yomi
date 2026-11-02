/// Cover art is requested in two fixed sizes so the on-disk image cache gets hits
/// and downloaded songs can have both sizes ready for offline use.
const int smallCoverPx = 240;
const int largeCoverPx = 640;
const double _smallCoverMaxLogical = 120;

int coverPixelsFor(double logicalSize) =>
    logicalSize <= _smallCoverMaxLogical ? smallCoverPx : largeCoverPx;

String coverCacheKey(String coverArtId, int pixels) =>
    'cover-$coverArtId-$pixels';
