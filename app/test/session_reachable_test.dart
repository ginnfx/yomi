import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yomi/state/session.dart';

void main() {
  test('goes to offline mode when the server does not answer', () async {
    FlutterSecureStorage.setMockInitialValues({
      'server_url': 'http://127.0.0.1:1',
      'username': 'u',
      'password': 'p',
    });
    final session = SessionController();
    await session.restore();
    expect(
      session.isServerReachable,
      isTrue,
    ); // optimistic until the check finishes

    // restore() started the check itself; wait for it to finish.
    for (
      var i = 0;
      i < 50 && (session.isChecking || session.isServerReachable);
      i++
    ) {
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }

    expect(session.isServerReachable, isFalse);
    session.dispose();
  });
}
