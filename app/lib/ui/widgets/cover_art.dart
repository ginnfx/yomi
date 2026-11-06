import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/cover_crop.dart';
import '../../core/artwork_lookup.dart';
import '../../core/cover_sizes.dart';
import '../../state/catalog_controller.dart';
import '../../state/session.dart';
import '../theme.dart';

/// Cover art with a disk cache (so it also shows offline), a soft fade-in, and a
/// colourful fallback that is stable per song instead of a grey box.
class CoverArt extends StatelessWidget {
  const CoverArt({
    super.key,
    required this.coverArtId,
    this.size = 56,
    this.radius = 12,
    this.elevated = false,
    this.heroTag,
    this.seed,
    this.artist,
    this.album,
    this.title,
  });

  final String? coverArtId;
  final double size;
  final double radius;
  final bool elevated;
  final Object? heroTag;

  /// Used to pick the fallback colours when there is no artwork.
  final String? seed;
  final String? artist, album, title;

  @override
  Widget build(BuildContext context) {
    final fallback = _Fallback(size: size, seedText: seed ?? coverArtId ?? '');
    final hasCover = coverArtId != null || artist != null;
    final Widget image = !hasCover
        ? fallback
        : _CoverImage(
            coverArtId: coverArtId,
            pixels: coverPixelsFor(size),
            artist: artist,
            album: album,
            title: title,
            fallback: fallback,
          );
    Widget result = SizedBox.square(
      dimension: size,
      child: DecoratedBox(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(radius),
          boxShadow: elevated
              ? [
                  BoxShadow(
                    color: Colors.black.withValues(
                      alpha: YomiColors.isLight ? 0.18 : 0.45,
                    ),
                    blurRadius: 24,
                    offset: const Offset(0, 10),
                  ),
                ]
              : null,
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(radius),
          child: image,
        ),
      ),
    );
    if (heroTag != null) result = Hero(tag: heroTag!, child: result);
    return result;
  }
}

/// Shows a cover trimmed to its real artwork.
///
/// A cover already in memory shows immediately. When this widget is reused for another
/// song, the previous song's cover goes at once rather than staying until the new one
/// has loaded. If loading fails, it tries again when the connection changes.
class _CoverImage extends StatefulWidget {
  const _CoverImage({
    required this.coverArtId,
    required this.pixels,
    required this.artist,
    required this.album,
    required this.title,
    required this.fallback,
  });

  final String? coverArtId;
  final int pixels;
  final String? artist, album, title;
  final Widget fallback;

  String get cacheKey => coverCacheKey(
    coverArtId ?? 'missing-${artist ?? ''}-${album ?? ''}-${title ?? ''}',
    pixels,
  );

  @override
  State<_CoverImage> createState() => _CoverImageState();
}

class _CoverImageState extends State<_CoverImage> {
  static const _fade = Duration(milliseconds: 160);
  static const _loadingColor = Color(0x14FFFFFF);

  /// The first retry after a failure. Each one after waits twice as long, up to the limit.
  static const _firstRetry = Duration(seconds: 15);
  static const _longestRetry = Duration(minutes: 2);
  static const _smallVersionLimit = Duration(seconds: 2);

  final CoverImageService _service = CoverImageService.instance;
  ui.Image? _image;
  bool _hasExactImage = false;
  bool _isLoading = false;
  int _generation = 0;
  int _failures = 0;
  Timer? _retryTimer;

  @override
  void initState() {
    super.initState();
    _service.retries.addListener(_retry);
    _start();
  }

  @override
  void didUpdateWidget(_CoverImage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.cacheKey != widget.cacheKey) {
      _failures = 0;
      _start();
    }
  }

  @override
  void dispose() {
    _generation++;
    _retryTimer?.cancel();
    _service.retries.removeListener(_retry);
    super.dispose();
  }

  void _retry() {
    if (mounted && !_hasExactImage) setState(_start);
  }

  void _start() {
    final generation = ++_generation;
    _retryTimer?.cancel();
    final exact = _service.peek(widget.cacheKey);
    _hasExactImage = exact != null;
    // While the big version loads, show the small one we already have instead of a blank.
    _image = exact ?? _smallVersion();
    // A retry leaves the fallback up, rather than flickering to blank and back.
    _isLoading = exact == null && _failures == 0;
    if (exact != null) return;
    if (_image == null) unawaited(_showSavedSmallVersion(generation));
    unawaited(
      _load().then((image) {
        if (!mounted || generation != _generation) return;
        setState(() {
          _isLoading = false;
          _hasExactImage = image != null;
          _image = image ?? _image;
        });
        if (image != null) {
          _failures = 0;
        } else if (!_service.isMissing(widget.cacheKey)) {
          _retryLater();
        }
      }),
    );
  }

  /// Reads the small version from this device, so a big cover isn't blank while it
  /// downloads, or at all when there's no connection.
  Future<void> _showSavedSmallVersion(int generation) async {
    final id = widget.coverArtId;
    if (id == null || widget.pixels == smallCoverPx) return;
    final key = coverCacheKey(id, smallCoverPx);
    await _service.warm([key], limit: _smallVersionLimit);
    if (!mounted || generation != _generation || _image != null) return;
    final small = _service.peek(key);
    if (small == null) return;
    setState(() {
      _image = small;
      _isLoading = false;
    });
  }

  /// Keeps trying while this cover is on screen, as nothing else will ask for it again
  /// and the connection may recover without the address changing.
  void _retryLater() {
    final wait = _firstRetry * (1 << _failures.clamp(0, 3));
    _failures++;
    _retryTimer = Timer(wait > _longestRetry ? _longestRetry : wait, _retry);
  }

  ui.Image? _smallVersion() {
    final id = widget.coverArtId;
    return id == null ? null : _service.peek(coverCacheKey(id, smallCoverPx));
  }

  Future<ui.Image?> _load() {
    final id = widget.coverArtId;
    final artist = widget.artist;
    return _service.load(
      id == null
          ? null
          : context
                .read<SessionController>()
                .client
                .coverArtUri(id, size: widget.pixels)
                .toString(),
      widget.cacheKey,
      fallbackUrl: artist == null
          ? null
          : () => ArtworkLookup.instance.find(
              artist,
              widget.album ?? '',
              widget.title ?? '',
            ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final image = _image;
    return AnimatedSwitcher(
      // Keyed by cover, so a reused row never fades through the previous song's cover.
      key: ValueKey(widget.cacheKey),
      duration: _fade,
      child: image != null
          ? RawImage(
              key: ValueKey(image),
              image: image,
              fit: BoxFit.cover,
              filterQuality: FilterQuality.medium,
            )
          : _isLoading
          ? const ColoredBox(
              key: ValueKey('loading'),
              color: _loadingColor,
              child: SizedBox.expand(),
            )
          : KeyedSubtree(
              key: const ValueKey('fallback'),
              child: widget.fallback,
            ),
    );
  }
}

class _Fallback extends StatelessWidget {
  const _Fallback({required this.size, required this.seedText});

  final double size;
  final String seedText;

  @override
  Widget build(BuildContext context) {
    final hue = (seedText.hashCode.abs() % 360).toDouble();
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            HSLColor.fromAHSL(1, hue, 0.45, 0.28).toColor(),
            HSLColor.fromAHSL(1, (hue + 40) % 360, 0.5, 0.16).toColor(),
          ],
        ),
      ),
      child: Icon(
        Icons.music_note_rounded,
        color: Colors.white.withValues(alpha: 0.35),
        size: size * 0.38,
      ),
    );
  }
}

/// Round artist picture: the first album's cover, or a coloured monogram when there is none.
class ArtistAvatar extends StatelessWidget {
  const ArtistAvatar({
    super.key,
    required this.artistId,
    required this.name,
    this.size = 56,
  });

  final String artistId;
  final String name;
  final double size;

  @override
  Widget build(BuildContext context) {
    // The saved library knows this without asking the server once per artist.
    final saved = Provider.of<CatalogController?>(
      context,
      listen: false,
    )?.coverForArtist(name);
    if (saved != null) return _circle(saved);
    final client = context.read<SessionController>().client;
    return FutureBuilder<String?>(
      // Keyed so a reused row can't keep showing another artist's picture.
      key: ValueKey(artistId),
      future: client.artistCoverId(artistId),
      builder: (context, snapshot) => _circle(snapshot.data),
    );
  }

  Widget _circle(String? coverId) => ClipOval(
    child: coverId != null
        ? CoverArt(coverArtId: coverId, size: size, radius: size / 2)
        : _Monogram(name: name, size: size),
  );
}

class _Monogram extends StatelessWidget {
  const _Monogram({required this.name, required this.size});

  final String name;
  final double size;

  @override
  Widget build(BuildContext context) {
    final hue = (name.hashCode.abs() % 360).toDouble();
    final initial = name.trim().isEmpty
        ? '?'
        : name.trim().characters.first.toUpperCase();
    return Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            HSLColor.fromAHSL(1, hue, 0.55, 0.42).toColor(),
            HSLColor.fromAHSL(1, (hue + 50) % 360, 0.6, 0.28).toColor(),
          ],
        ),
      ),
      child: Text(
        initial,
        style: yomiText(size * 0.42, weight: FontWeight.w800),
      ),
    );
  }
}
