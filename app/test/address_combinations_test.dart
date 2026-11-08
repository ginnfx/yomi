import 'package:flutter_test/flutter_test.dart';
import 'package:yomi/core/address_combinations.dart';

void main() {
  test('mixes every known host with every known port', () {
    final result = addressCombinations([
      'http://192.168.1.18:4533',
      'http://100.88.180.104:4533',
      'http://my-mac:4000',
    ]);
    expect(
      result,
      containsAll([
        'http://192.168.1.18:4000',
        'http://100.88.180.104:4000',
        'http://my-mac:4533',
      ]),
    );
    expect(result, hasLength(3));
  });

  test('leaves out addresses that are already known', () {
    final result = addressCombinations(['http://a:4533', 'http://b:4533']);
    expect(result, isEmpty);
  });

  test('adds extra bare hosts with the known ports and schemes', () {
    final result = addressCombinations(
      ['http://a:4533'],
      extraHosts: ['100.64.0.2', ' my-mac ', ''],
    );
    expect(result, ['http://100.64.0.2:4533', 'http://my-mac:4533']);
  });

  test('an address without a scheme or port means http on 4533', () {
    final result = addressCombinations(['a'], extraHosts: ['b']);
    expect(result, ['http://b:4533']);
  });

  test('keeps https as its own scheme and its own default port', () {
    final result = addressCombinations(['http://a:4533', 'https://b.example']);
    expect(
      result,
      containsAll([
        'https://a:4533',
        'http://a',
        'https://a',
        'http://b.example:4533',
        'http://b.example',
      ]),
    );
  });

  test('is capped and stable', () {
    final many = addressCombinations(
      ['http://a:4533', 'http://a:1', 'http://a:2', 'https://a'],
      extraHosts: [for (var i = 0; i < 20; i++) 'h$i'],
      max: 5,
    );
    expect(many, hasLength(5));
    expect(
      many,
      addressCombinations(
        ['http://a:4533', 'http://a:1', 'http://a:2', 'https://a'],
        extraHosts: [for (var i = 0; i < 20; i++) 'h$i'],
        max: 5,
      ),
    );
  });

  test('ignores unreadable addresses', () {
    expect(addressCombinations(['://', ''], extraHosts: ['b']), [
      'http://b:4533',
    ]);
  });
}
