import 'dart:async';
import 'dart:collection';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart';

import 'cover_downloader.dart';
import 'cover_sizes.dart';

/// Many covers are video thumbnails pasted onto a square: the real artwork sits in the
/// middle with flat white, black or grey bars around it. These helpers find the artwork
/// and crop to it, so covers fill their square instead of showing strips.
const int _tolerance = 18; // how much a "flat" bar may vary (JPEG noise)
const double _minBlankFraction = 0.2; // refuse to trim down to almost nothing
const double _worthCroppingBelow =
    0.9; // only crop if bars take at least ~10% of the area
const double _edgeInset = 0.015; // shave a hair more to remove blurry edges
const int _maxOutputSide = 480;

/// How much memory decoded covers may use: about 160 large covers, or 1100 small ones,
/// so scrolling back up Home finds them still there.
const int _maxReadyBytes = 256 * 1024 * 1024;

/// A cover that just failed isn't asked for again this soon, so a wall of covers on a
/// dead connection can't hammer it. Covers on screen retry on their own after this.
const Duration _retryAfter = Duration(seconds: 10);

/// How long to believe the server when it says a cover has no picture.
const Duration _missingFor = Duration(hours: 1);

/// Trimming needs the graphics system, which can be unavailable in the background.
const Duration _trimTimeout = Duration(seconds: 3);

/// Reading a cover already on this device shouldn't take anywhere near this long.
const Duration _warmGiveUpAfter = Duration(seconds: 5);

const Duration _keepCoversFor = Duration(days: 365);

const String _coverStoreName = 'yomi_covers';

/// The shared store that earlier versions saved covers in.
const String _olderCoverStoreName = 'libCachedImageData';

/// Covers get their own store: the shared default keeps only 200 files, far fewer than a
/// library has covers, so older ones kept being deleted and fetched again.
final CacheManager coverCacheManager = CacheManager(
  Config(
    _coverStoreName,
    stalePeriod: _keepCoversFor,
    maxNrOfCacheObjects: 10000,
  ),
);

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

/// Where cover files come from. Separate so the service can be tested without a network.
abstract interface class CoverSource {
  /// Whether any download is running or waiting.
  bool get isBusy;

  /// The keys of covers already in the main store, without reading the files.
  Future<Set<String>> savedKeys();

  /// The file already on this device, or null.
  Future<Uint8List?> saved(String cacheKey);

  /// Fetches and stores the file. Throws [CoverNotAvailable] when the server says there
  /// isn't one, and anything else when it can't be reached.
  Future<Uint8List> download(String url, String cacheKey);

  /// Forgets a stored file, used when it turns out not to be an image.
  Future<void> forget(String cacheKey);

  /// Drops every unfinished download, as they may be stuck on an old address.
  void cancelDownloads();
}

class _DeviceCoverSource implements CoverSource {
  _DeviceCoverSource();

  final CoverDownloader _downloader = CoverDownloader();

  @override
  bool get isBusy => _downloader.isBusy;

  @override
  Future<Set<String>> savedKeys() async {
    final keys = await _savedKeys(_coverStoreName);
    return {
      for (final entry in keys.entries)
        if (entry.key == entry.value) entry.key,
    };
  }

  @override
  Future<Uint8List?> saved(String cacheKey) async {
    final bytes = await _read(coverCacheManager, cacheKey);
    if (bytes != null) return bytes;
    // Covers saved by earlier versions, so they don't all need fetching again.
    for (final (store, keys) in await _olderCovers) {
      final olderKey = keys[cacheKey];
      if (olderKey == null) continue;
      final older = await _read(store, olderKey);
      if (older == null) continue;
      await _store(cacheKey, older, cacheKey);
      return older;
    }
    return null;
  }

  late final Future<List<(CacheManager, Map<String, String>)>> _olderCovers =
      _findOlderCovers();

  Future<List<(CacheManager, Map<String, String>)>> _findOlderCovers() async {
    return [
      (coverCacheManager, await _savedKeys(_coverStoreName)),
      (DefaultCacheManager(), await _savedKeys(_olderCoverStoreName)),
    ];
  }

  /// Lists a store's covers. Opened separately and read-only, so closing it can't affect
  /// the cache manager using the same file.
  Future<Map<String, String>> _savedKeys(String store) async {
    try {
      final folder = await getApplicationSupportDirectory();
      final database = await openDatabase(
        '${folder.path}/$store.db',
        readOnly: true,
        singleInstance: false,
      );
      try {
        final rows = await database.rawQuery(
          "SELECT key FROM cacheObject WHERE key LIKE 'cover-%'",
        );
        return olderCoverKeys([for (final row in rows) row['key']! as String]);
      } finally {
        await database.close();
      }
    } on Object catch (error) {
      debugPrint('Could not list saved covers in $store: $error');
      return const {};
    }
  }

  Future<Uint8List?> _read(CacheManager manager, String cacheKey) async {
    final saved = await manager.getFileFromCache(cacheKey);
    if (saved == null || !await saved.file.exists()) return null;
    return saved.file.readAsBytes();
  }

  /// Failing to save only means fetching it again next time, so it isn't an error here.
  Future<void> _store(String url, Uint8List bytes, String cacheKey) async {
    try {
      await coverCacheManager.putFile(
        url,
        bytes,
        key: cacheKey,
        maxAge: _keepCoversFor,
      );
    } on Object catch (error) {
      debugPrint('Could not save a cover: $error');
    }
  }

  @override
  Future<Uint8List> download(String url, String cacheKey) async {
    final bytes = await _downloader.fetch(url);
    await _store(url, bytes, cacheKey);
    return bytes;
  }

  @override
  Future<void> forget(String cacheKey) async {
    await coverCacheManager.removeFile(cacheKey);
    await DefaultCacheManager().removeFile(cacheKey);
  }

  @override
  void cancelDownloads() => _downloader.cancelAll();
}

/// Loads a cover, from this device when possible, and returns it trimmed to its artwork.
class CoverImageService {
  CoverImageService({CoverSource? source, DateTime Function()? now})
    : _source = source ?? _DeviceCoverSource(),
      _now = now ?? DateTime.now;

  static CoverImageService instance = CoverImageService();

  final CoverSource _source;

  /// Where covers come from, for saving them ahead of time.
  CoverSource get source => _source;
  final DateTime Function() _now;
  final LinkedHashMap<String, ui.Image> _ready = LinkedHashMap();
  final Map<String, Future<ui.Image?>> _loading = {};
  final Map<String, Future<void>> _warming = {};
  final Map<String, DateTime> _failedAt = {};
  final Map<String, DateTime> _missingAt = {};
  final ValueNotifier<int> _retries = ValueNotifier(0);
  int _readyBytes = 0;

  /// Changes when covers that failed are worth trying again.
  ValueListenable<int> get retries => _retries;

  /// Whether the server said there's no picture for this cover, so retrying is pointless.
  bool isMissing(String cacheKey) {
    final at = _missingAt[cacheKey];
    return at != null && _now().difference(at) < _missingFor;
  }

  /// A cover that is already decoded, so screens can show it on the very first frame.
  ui.Image? peek(String cacheKey) {
    final image = _ready.remove(cacheKey);
    if (image != null) _ready[cacheKey] = image; // most recently used goes last
    return image;
  }

  /// Loads a cover, trying [fallbackUrl] when [url] has nothing for it.
  Future<ui.Image?> load(
    String? url,
    String cacheKey, {
    Future<String?> Function()? fallbackUrl,
  }) {
    final ready = peek(cacheKey);
    if (ready != null) return Future.value(ready);
    final warming = _warming[cacheKey];
    if (warming != null) {
      return warming.then((_) => load(url, cacheKey, fallbackUrl: fallbackUrl));
    }
    final loading = _loading[cacheKey];
    if (loading != null) return loading;
    final failedAt = _failedAt[cacheKey];
    if (isMissing(cacheKey) ||
        (failedAt != null && _now().difference(failedAt) < _retryAfter)) {
      return Future.value();
    }
    late final Future<ui.Image?> future;
    future = _fetch(url, cacheKey, fallbackUrl).then((image) {
      if (image != null) {
        _failedAt.remove(cacheKey);
        _missingAt.remove(cacheKey);
        _remember(cacheKey, image);
      }
      // A request that was cancelled says nothing about the retry that replaced it.
      if (identical(_loading[cacheKey], future)) {
        _loading.remove(cacheKey);
        if (image == null) _failedAt[cacheKey] = _now();
      }
      return image;
    });
    _loading[cacheKey] = future;
    return future;
  }

  /// Decodes covers already on this device, waiting at most [limit], so the first screen
  /// can show them straight away. Anything slower carries on behind the scenes.
  Future<void> warm(Iterable<String> cacheKeys, {required Duration limit}) {
    final waits = [
      for (final key in cacheKeys.toSet())
        if (!_ready.containsKey(key) && !_warming.containsKey(key)) _warm(key),
    ];
    return Future.wait(waits).timeout(limit, onTimeout: () => const []);
  }

  Future<void> _warm(String cacheKey) {
    final work = _fromDevice(cacheKey)
        .timeout(_warmGiveUpAfter, onTimeout: () => null)
        .then((image) {
          if (image != null) _remember(cacheKey, image);
        })
        .whenComplete(() {
          _warming.remove(cacheKey);
        });
    return _warming[cacheKey] = work;
  }

  /// Tries failed and unfinished covers again, as the connection has changed and those
  /// requests may be stuck on an address that no longer works.
  void retryFailed() {
    _failedAt.clear();
    _missingAt.clear();
    _loading.clear();
    _source.cancelDownloads();
    _retries.value++;
  }

  /// Lets go of decoded covers when the system is short of memory. Covers on screen keep
  /// their picture, and the rest reload from this device when next needed.
  void releaseMemory() {
    _ready.clear();
    _readyBytes = 0;
  }

  void _remember(String cacheKey, ui.Image image) {
    final previous = _ready.remove(cacheKey);
    if (previous != null) _readyBytes -= _sizeOf(previous);
    _ready[cacheKey] = image;
    _readyBytes += _sizeOf(image);
    while (_readyBytes > _maxReadyBytes && _ready.length > 1) {
      final oldest = _ready.keys.first;
      _readyBytes -= _sizeOf(_ready.remove(oldest)!);
    }
  }

  static int _sizeOf(ui.Image image) => image.width * image.height * 4;

  Future<ui.Image?> _fetch(
    String? url,
    String cacheKey,
    Future<String?> Function()? fallbackUrl,
  ) async {
    final saved = await _fromDevice(cacheKey);
    if (saved != null) return saved;
    if (url != null) {
      try {
        // A dropped connection returns null here and stops: the server still has the
        // cover, so waiting in line for an outside lookup would only hold it back.
        return await _download(url, cacheKey);
      } on CoverNotAvailable catch (error) {
        debugPrint('$error');
      }
    }
    final fallback = await fallbackUrl?.call();
    if (fallback != null) {
      final external = 'external-$fallback';
      final image =
          await _fromDevice(external) ?? await _tryDownload(fallback, external);
      if (image != null) return image;
    }
    _missingAt[cacheKey] = _now();
    return null;
  }

  Future<ui.Image?> _tryDownload(String url, String cacheKey) async {
    try {
      return await _download(url, cacheKey);
    } on CoverNotAvailable catch (error) {
      debugPrint('$error');
      return null;
    }
  }

  Future<ui.Image?> _fromDevice(String cacheKey) async {
    try {
      final bytes = await _source.saved(cacheKey);
      return bytes == null ? null : await _decodeOrForget(bytes, cacheKey);
    } on Object catch (error) {
      debugPrint('Could not read a saved cover: $error');
      return null;
    }
  }

  /// Null when the connection failed. [CoverNotAvailable] carries on to the caller.
  Future<ui.Image?> _download(String url, String cacheKey) async {
    try {
      final bytes = await _source.download(url, cacheKey);
      return await _decodeOrForget(bytes, cacheKey);
    } on CoverNotAvailable {
      rethrow;
    } on Object catch (error) {
      debugPrint('Could not fetch a cover: $error');
      return null;
    }
  }

  /// A saved file that isn't a picture, such as an error message saved by an earlier
  /// version, would leave the cover blank for good, so it's thrown away. A real picture
  /// that won't decode right now is kept: the phone may just be short of memory.
  Future<ui.Image?> _decodeOrForget(Uint8List bytes, String cacheKey) async {
    try {
      return await _decodeAndTrim(bytes);
    } on Object catch (error) {
      debugPrint('Could not decode a cover: $error');
      if (!looksLikeImage(bytes)) await _source.forget(cacheKey);
      return null;
    }
  }

  Future<ui.Image> _decodeAndTrim(Uint8List bytes) async {
    final codec = await ui.instantiateImageCodec(bytes);
    final original = (await codec.getNextFrame()).image;
    try {
      return await _trim(original).timeout(_trimTimeout);
    } on Object catch (error) {
      // The picture itself is fine, so show it with its bars rather than not at all.
      debugPrint('Showing a cover untrimmed: $error');
      return original;
    }
  }

  Future<ui.Image> _trim(ui.Image original) async {
    final data = await original.toByteData(format: ui.ImageByteFormat.rawRgba);
    if (data == null) return original;
    final artwork = findArtwork(
      data.buffer.asUint8List(),
      original.width,
      original.height,
    );
    if (artwork == null) return original;
    return _crop(original, squareInside(artwork));
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
