import 'dart:async';
import 'dart:collection';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter_cache_manager/flutter_cache_manager.dart';

/// Many covers are video thumbnails pasted onto a square: the real artwork sits in the
/// middle with flat white, black or grey bars around it. These helpers find the artwork
/// and crop to it, so covers fill their square instead of showing strips.
const int _tolerance = 18; // how much a "flat" bar may vary (JPEG noise)
const double _minBlankFraction = 0.2; // refuse to trim down to almost nothing
const double _worthCroppingBelow =
    0.9; // only crop if bars take at least ~10% of the area
const double _edgeInset = 0.015; // shave a hair more to remove blurry edges
const int _maxOutputSide = 480;
const int _cacheLimit = 400;

class PixelRect {
  const PixelRect(this.left, this.top, this.right, this.bottom);

  final int left;
  final int top;
  final int right;
  final int bottom;

  int get width => right - left;
  int get height => bottom - top;

  @override
  bool operator ==(Object other) =>
      other is PixelRect &&
      other.left == left &&
      other.top == top &&
      other.right == right &&
      other.bottom == bottom;

  @override
  int get hashCode => Object.hash(left, top, right, bottom);

  @override
  String toString() => 'PixelRect($left, $top, $right, $bottom)';
}

/// The area of an RGBA image that is not flat border, or null when there is nothing to trim.
PixelRect? findArtwork(Uint8List rgba, int width, int height) {
  bool isFlat(int count, int Function(int) pixelIndex) {
    final lo = [255, 255, 255];
    final hi = [0, 0, 0];
    for (var i = 0; i < count; i++) {
      final p = pixelIndex(i) * 4;
      for (var c = 0; c < 3; c++) {
        final v = rgba[p + c];
        if (v < lo[c]) lo[c] = v;
        if (v > hi[c]) hi[c] = v;
      }
    }
    return hi[0] - lo[0] <= _tolerance &&
        hi[1] - lo[1] <= _tolerance &&
        hi[2] - lo[2] <= _tolerance;
  }

  bool rowFlat(int y) => isFlat(width, (x) => y * width + x);

  var top = 0;
  while (top < height && rowFlat(top)) {
    top++;
  }
  var bottom = height;
  while (bottom > top && rowFlat(bottom - 1)) {
    bottom--;
  }
  if (bottom - top < height * _minBlankFraction) return null;

  bool columnFlat(int x) => isFlat(bottom - top, (i) => (top + i) * width + x);

  var left = 0;
  while (left < width && columnFlat(left)) {
    left++;
  }
  var right = width;
  while (right > left && columnFlat(right - 1)) {
    right--;
  }
  if (right - left < width * _minBlankFraction) return null;

  final found = PixelRect(left, top, right, bottom);
  final coverage = (found.width * found.height) / (width * height);
  return coverage >= _worthCroppingBelow ? null : found;
}

/// The largest centred square inside [artwork], slightly inset.
PixelRect squareInside(PixelRect artwork) {
  final side = artwork.width < artwork.height ? artwork.width : artwork.height;
  final inset = (side * _edgeInset).round();
  final size = side - 2 * inset;
  final left = artwork.left + (artwork.width - size) ~/ 2;
  final top = artwork.top + (artwork.height - size) ~/ 2;
  return PixelRect(left, top, left + size, top + size);
}

/// Loads a cover, from the on-disk cache when possible, and returns it trimmed to its artwork.
class CoverImageService {
  CoverImageService._();

  static final CoverImageService instance = CoverImageService._();

  final LinkedHashMap<String, Future<ui.Image?>> _images = LinkedHashMap();
  final Map<String, ui.Image> _ready = {};

  /// A cover that is already decoded, so screens can show it on the very first frame.
  ui.Image? peek(String cacheKey) => _ready[cacheKey];

  Future<ui.Image?> load(String url, String cacheKey) {
    final existing = _images.remove(cacheKey);
    if (existing != null) {
      _images[cacheKey] = existing; // most recently used goes last
      return existing;
    }
    final future = _loadAndTrim(url, cacheKey);
    _images[cacheKey] = future;
    future.then((image) {
      if (image != null) _ready[cacheKey] = image;
    });
    if (_images.length > _cacheLimit) {
      final oldest = _images.keys.first;
      _images.remove(oldest);
      _ready.remove(oldest);
    }
    return future;
  }

  Future<ui.Image?> _loadAndTrim(String url, String cacheKey) async {
    try {
      final file = await DefaultCacheManager().getSingleFile(
        url,
        key: cacheKey,
      );
      final codec = await ui.instantiateImageCodec(await file.readAsBytes());
      final original = (await codec.getNextFrame()).image;
      final data = await original.toByteData(
        format: ui.ImageByteFormat.rawRgba,
      );
      if (data == null) return original;
      final artwork = findArtwork(
        data.buffer.asUint8List(),
        original.width,
        original.height,
      );
      if (artwork == null) return original;
      return await _crop(original, squareInside(artwork));
    } on Object {
      return null;
    }
  }

  Future<ui.Image> _crop(ui.Image source, PixelRect area) async {
    final side = area.width > _maxOutputSide ? _maxOutputSide : area.width;
    final recorder = ui.PictureRecorder();
    ui.Canvas(recorder).drawImageRect(
      source,
      ui.Rect.fromLTRB(
        area.left.toDouble(),
        area.top.toDouble(),
        area.right.toDouble(),
        area.bottom.toDouble(),
      ),
      ui.Rect.fromLTWH(0, 0, side.toDouble(), side.toDouble()),
      ui.Paint()..filterQuality = ui.FilterQuality.high,
    );
    return await recorder.endRecording().toImage(side, side);
  }
}
