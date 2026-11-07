import 'package:flutter_test/flutter_test.dart';
import 'package:yomi/core/time_left.dart';

void main() {
  group('estimateTimeLeft', () {
    test('returns null before anything has finished', () {
      expect(
        estimateTimeLeft(
          done: 0,
          remaining: 10,
          elapsed: const Duration(minutes: 1),
        ),
        isNull,
      );
    });

    test('returns null while the sample is too short to trust', () {
      expect(
        estimateTimeLeft(
          done: 1,
          remaining: 10,
          elapsed: const Duration(seconds: 2),
        ),
        isNull,
      );
    });

    test('scales the pace so far to what remains', () {
      final left = estimateTimeLeft(
        done: 10,
        remaining: 30,
        elapsed: const Duration(seconds: 20),
      );
      expect(left, const Duration(seconds: 60));
    });
  });

  group('describeTimeLeft', () {
    test('is empty without an estimate', () {
      expect(describeTimeLeft(null), '');
    });

    test('rounds to minutes and hours in plain words', () {
      expect(
        describeTimeLeft(const Duration(seconds: 20)),
        'less than a minute left',
      );
      expect(describeTimeLeft(const Duration(minutes: 3)), 'about 3 min left');
      expect(describeTimeLeft(const Duration(hours: 2)), 'about 2 h left');
      expect(
        describeTimeLeft(const Duration(hours: 1, minutes: 20)),
        'about 1 h 20 min left',
      );
    });
  });
}
