import 'package:flutter_test/flutter_test.dart';
import 'package:yomi/core/listening/wrapped_window.dart';

void main() {
  test("this year's Wrapped opens in December", () {
    expect(isWrappedOpen(2026, DateTime(2026, 11, 30)), isFalse);
    expect(isWrappedOpen(2026, DateTime(2026, 12, 1)), isTrue);
    expect(isWrappedOpen(2026, DateTime(2026, 12, 31, 23)), isTrue);
  });

  test("past years' Wrapped stays open, future years never", () {
    expect(isWrappedOpen(2025, DateTime(2026, 3, 1)), isTrue);
    expect(isWrappedOpen(2027, DateTime(2026, 12, 1)), isFalse);
  });
}
