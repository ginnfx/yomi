import 'dart:async';

import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yomi/core/notifications/push_registration.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('yomi/push');
  final sent = <({String token, String kind})>[];
  var isServerHappy = true;
  final removed = <String>[];

  PushRegistration build() => PushRegistration(
    channel: channel,
    isSupported: true,
    unregister: ({required token, required kind}) async {
      removed.add(token);
      return true;
    },
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
    removed.clear();
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

  test(
    'opting out unregisters and prevents token refresh registration',
    () async {
      final push = build();
      await push.serverReady();
      await phoneGivesToken('abc', 'production');
      await push.setEnabled(false);
      expect(removed, ['abc']);
      expect(push.isRegistered, isFalse);
      await phoneGivesToken('def', 'production');
      await push.serverReady();
      expect(sent.map((d) => d.token), ['abc']);
      await push.setEnabled(true);
      expect(sent.map((d) => d.token), ['abc', 'def']);
    },
  );

  test(
    'failed opt-out is retried after restart while notifications stay disabled',
    () async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      final push = PushRegistration(
        channel: channel,
        isSupported: true,
        prefs: prefs,
        register: ({required token, required kind}) async => true,
        unregister: ({required token, required kind}) async => false,
      )..start();
      await push.serverReady();
      await phoneGivesToken('saved', 'production');
      await push.deactivate();
      final restarted = PushRegistration(
        channel: channel,
        isSupported: true,
        prefs: prefs,
        isEnabled: false,
        register: ({required token, required kind}) async => fail('registered'),
        unregister: ({required token, required kind}) async {
          removed.add(token);
          return true;
        },
      )..start();
      await restarted.serverReady();
      expect(removed, ['saved']);
    },
  );

  test('opt-out waits for in-flight registration then removes it', () async {
    final gate = Completer<bool>();
    final push = PushRegistration(
      channel: channel,
      isSupported: true,
      register: ({required token, required kind}) => gate.future,
      unregister: ({required token, required kind}) async {
        removed.add(token);
        return true;
      },
    )..start();
    await push.serverReady();
    final tokenEvent = phoneGivesToken('late', 'production');
    await Future<void>.delayed(Duration.zero);
    final disabled = push.deactivate();
    gate.complete(true);
    await tokenEvent;
    await disabled;
    expect(removed, ['late']);
    expect(push.isRegistered, isFalse);
  });

  test('renewing a token removes the old registration first', () async {
    final push = build();
    await push.serverReady();
    await phoneGivesToken('old', 'production');
    await phoneGivesToken('new', 'production');
    expect(removed, ['old']);
    expect(sent.map((d) => d.token), ['old', 'new']);
  });

  test('does nothing where push is unsupported', () async {
    final push = PushRegistration(
      register: ({required token, required kind}) async => fail('sent'),
      unregister: ({required token, required kind}) async =>
          fail('unregistered'),
      isSupported: false,
    )..start();

    await push.activate();
    await push.serverReady();
  });
}
