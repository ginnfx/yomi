import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yomi/state/session.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'account login uses the working home server without requiring Tailscale',
    () async {
      FlutterSecureStorage.setMockInitialValues({});
      final session = SessionController(
        probe: (url, user, password) async {
          expect(url, 'http://192.168.1.18:4533');
          expect(user, 'listener');
          expect(password, 'account-password');
          return true;
        },
      );
      await session.signIn(
        'http://127.0.0.1:1',
        ' listener ',
        'account-password',
        homeInput: '192.168.1.18',
      );
      expect(session.isSignedIn, true);
      expect(session.serverUrl, 'http://192.168.1.18:4533');
      expect(session.route, ActiveRoute.home);
      session.dispose();
    },
  );
}
