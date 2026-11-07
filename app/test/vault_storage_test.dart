import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yomi/core/vault_storage.dart';

const _legacy = ['username', 'password', 'server_url'];

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  VaultStorage vault({bool isOn = true}) => VaultStorage(
    const FlutterSecureStorage(),
    legacyKeys: _legacy,
    isVaultOn: isOn,
  );

  test('moves one-item-per-setting storage into a single item', () async {
    FlutterSecureStorage.setMockInitialValues({
      'username': 'sam',
      'password': 'secret',
    });
    const raw = FlutterSecureStorage();

    final value = await vault().read(key: 'password');

    expect(value, 'secret');
    expect(await raw.read(key: 'password'), isNull);
    expect(await raw.read(key: 'username'), isNull);
    expect(await raw.read(key: 'yomi.vault.v1'), contains('sam'));
  });

  test('keeps everything in one item as values are written', () async {
    FlutterSecureStorage.setMockInitialValues({});
    final store = vault();

    await store.write(key: 'username', value: 'sam');
    await store.write(key: 'server_url', value: 'http://a');
    await store.write(key: 'username', value: 'kit');

    final all = await const FlutterSecureStorage().readAll();
    expect(all.keys, ['yomi.vault.v1']);
    expect(await vault().read(key: 'username'), 'kit');
    expect(await vault().read(key: 'server_url'), 'http://a');
  });

  test('writing null removes a value', () async {
    FlutterSecureStorage.setMockInitialValues({});
    final store = vault();
    await store.write(key: 'username', value: 'sam');

    await store.write(key: 'username', value: null);

    expect(await vault().read(key: 'username'), isNull);
  });

  test('deleteAll forgets everything, including after a reopen', () async {
    FlutterSecureStorage.setMockInitialValues({'username': 'sam'});
    final store = vault();
    await store.read(key: 'username');

    await store.deleteAll();

    expect(await store.read(key: 'username'), isNull);
    expect(await vault().read(key: 'username'), isNull);
  });

  test('a damaged vault opens empty instead of crashing', () async {
    FlutterSecureStorage.setMockInitialValues({'yomi.vault.v1': '{nope'});

    expect(await vault().read(key: 'username'), isNull);
  });

  test('with the vault off, values go straight to the platform', () async {
    FlutterSecureStorage.setMockInitialValues({});

    await vault(isOn: false).write(key: 'username', value: 'sam');

    expect(await const FlutterSecureStorage().read(key: 'username'), 'sam');
  });
}
