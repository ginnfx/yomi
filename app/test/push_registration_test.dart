import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yomi/core/notifications/push_registration.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('yomi/push');
  final sent = <({String token, String kind})>[];
  var isServerHappy = true;

  PushRegistration build() => PushRegistration(
    channel: channel,
    isSupported: true,
    register: ({required token, required kind}) async {
      if (!isServerHappy) return false;
      sent.add((token: token, kind: kind));
      return true;
    },
  )..start();

  Future<void> phoneGivesToken(String token, String environment) =>
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .handlePlatformMessage(
            channel.name,
            channel.codec.encodeMethodCall(
              MethodCall('token', {'token': token, 'environment': environment}),
            ),
            (_) {},
          );

  setUp(() {
    sent.clear();
    isServerHappy = true;
  });

  test(
    'waits for the server before sending the token, then sends once',
    () async {
      final push = build();

      await phoneGivesToken('abc', 'sandbox');
      expect(sent, isEmpty);
      await push.serverReady();
      await push.serverReady();

      expect(sent, [(token: 'abc', kind: 'apns-sandbox')]);
    },
  );

  test('production phones are registered as apns', () async {
    final push = build();
    await push.serverReady();

    await phoneGivesToken('def', 'production');

    expect(sent.single.kind, 'apns');
  });

  test('a failed registration is tried again later', () async {
    final push = build();
    await push.serverReady();
    isServerHappy = false;
    await phoneGivesToken('abc', 'sandbox');
    expect(sent, isEmpty);

    isServerHappy = true;
    await push.serverReady();

    expect(sent.single.token, 'abc');
  });

  test('does nothing where push is unsupported', () async {
    final push = PushRegistration(
      register: ({required token, required kind}) async => fail('sent'),
      isSupported: false,
    )..start();

    await push.activate();
    await push.serverReady();
  });
}
