import '../cover_crop.dart';
import '../cover_sizes.dart';
import '../models.dart';
import '../subsonic_client.dart';

/// Pre-stores a downloaded song's cover art in both sizes so it still shows with no connection.
Future<void> warmCovers(SubsonicClient client, Song song) async {
  final id = song.coverArtId;
  if (id == null) return;
  for (final pixels in const [smallCoverPx, largeCoverPx]) {
    try {
      await coverCacheManager.getSingleFile(
        client.coverArtUri(id, size: pixels).toString(),
        key: coverCacheKey(id, pixels),
      );
    } on Object {
      // cover art is a nicety; the song itself is already saved
    }
  }
}
