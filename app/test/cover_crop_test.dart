import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:yomi/core/cover_crop.dart';

/// Builds a square RGBA picture: [bar] colour everywhere, with an "artwork" rectangle made
/// of varied pixels (like a photo) at [art].
Uint8List picture(int size, {required List<int> bar, PixelRect? art}) {
  final data = Uint8List(size * size * 4);
  for (var y = 0; y < size; y++) {
    for (var x = 0; x < size; x++) {
      final i = (y * size + x) * 4;
      final inArt =
          art != null &&
          x >= art.left &&
          x < art.right &&
          y >= art.top &&
          y < art.bottom;
      final r = inArt ? (x * 7 + y * 3) % 256 : bar[0];
      final g = inArt ? (x * 3 + y * 11) % 256 : bar[1];
      final b = inArt ? (x * 13 + y * 5) % 256 : bar[2];
      data[i] = r;
      data[i + 1] = g;
      data[i + 2] = b;
      data[i + 3] = 255;
    }
  }
  return data;
}

void main() {
  test('finds artwork sitting on white bars', () {
    const art = PixelRect(10, 30, 90, 70);

    final found = findArtwork(
      picture(100, bar: [255, 255, 255], art: art),
      100,
      100,
    );

    expect(found, art);
  });

  test('finds artwork with grey side bars and white top and bottom, like the NieR cover', () {
    // flat grey pillars beside the artwork must be trimmed too, leaving only the artwork
    const art = PixelRect(20, 25, 80, 75);
    final data = picture(100, bar: [255, 255, 255], art: art);
    // paint grey pillars inside the content band, outside the art
    for (var y = 25; y < 75; y++) {
      for (var x = 10; x < 90; x++) {
        if (x >= 20 && x < 80) continue;
        final i = (y * 100 + x) * 4;
        data[i] = 70;
        data[i + 1] = 70;
        data[i + 2] = 70;
      }
    }

    final found = findArtwork(data, 100, 100);

    expect(found, art);
    final square = squareInside(found!);
    expect(square.width, square.height);
    expect(square.left >= found.left && square.right <= found.right, isTrue);
    expect(square.top >= found.top && square.bottom <= found.bottom, isTrue);
  });

  test('works on black bars too', () {
    const art = PixelRect(0, 20, 100, 80);

    expect(findArtwork(picture(100, bar: [0, 0, 0], art: art), 100, 100), art);
  });

  test('leaves proper full-bleed artwork alone', () {
    const art = PixelRect(0, 0, 100, 100);

    expect(
      findArtwork(picture(100, bar: [255, 255, 255], art: art), 100, 100),
      isNull,
    );
  });

  test('does not bother cropping when the bars are tiny', () {
    const art = PixelRect(2, 2, 98, 98);

    expect(
      findArtwork(picture(100, bar: [255, 255, 255], art: art), 100, 100),
      isNull,
    );
  });

  test('a blank image is not cropped to nothing', () {
    expect(findArtwork(picture(100, bar: [255, 255, 255]), 100, 100), isNull);
  });

  test('the square is centred in the artwork and never larger than it', () {
    final square = squareInside(const PixelRect(10, 20, 90, 60));

    expect(square.width, square.height);
    expect(square.width <= 40, isTrue);
    expect((square.left + square.right) ~/ 2, 50);
    expect((square.top + square.bottom) ~/ 2, 40);
  });
}
