import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:segmeris/src/app/credential_store.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('legacy credentials move to the vault and leave preferences', () async {
    SharedPreferences.setMockInitialValues(
        {'authContext': 'session', 'apiToken': 'token'});
    expect(await CredentialStore.read('authContext'), 'session');
    expect(await CredentialStore.read('apiToken'), 'token');
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.containsKey('authContext'), isFalse);
    expect(prefs.containsKey('apiToken'), isFalse);
    expect(await const FlutterSecureStorage().read(key: 'apiToken'), 'token');
  });

  test('a saved vault credential wins over a stale plaintext value', () async {
    SharedPreferences.setMockInitialValues({'apiToken': 'stale'});
    FlutterSecureStorage.setMockInitialValues({'apiToken': 'current'});
    expect(await CredentialStore.read('apiToken'), 'current');
    expect((await SharedPreferences.getInstance()).containsKey('apiToken'),
        isFalse);
  });

  test('clear ordered after save cannot resurrect a session', () async {
    SharedPreferences.setMockInitialValues({});
    final save = CredentialStore.write('authContext', 'session');
    final clear = CredentialStore.write('authContext', null);
    await Future.wait([save, clear]);
    expect(await CredentialStore.read('authContext'), isNull);
  });
}
