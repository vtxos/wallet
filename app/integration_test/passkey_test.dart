// The app's passkey through Credential Manager, on an emulator whose passkey provider is
// testpasskey (app/android/testpasskey): create, sign, and the PRF the wallet's seed comes from.
// No enclave — the options are made here — so this is the Android half alone.

import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:app/passkey/platform_passkey.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

/// The checked-in debug keystore's origin, as `platform_passkey.dart` and the image publish it.
const debugOrigin = 'android:apk-key-hash:Lf1QIwQnlPBYPwDFhloUkYC-0tYAKSpKCQbEiyz118s';

final _random = Random.secure();
String _b64u(List<int> bytes) => base64Url.encode(bytes).replaceAll('=', '');
String _nonce() => _b64u(List<int>.generate(32, (_) => _random.nextInt(256)));
Map<String, dynamic> _clientData(Map<String, dynamic> credential) {
  final encoded = credential['response']['clientDataJSON'] as String;
  return jsonDecode(utf8.decode(base64Url.decode(base64Url.normalize(encoded)))) as Map<String, dynamic>;
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('a passkey through Credential Manager: created, signs, and gives the same seed', (_) async {
    const rpId = 'vtxos.com';
    final passkey = PlatformPasskey(rpId: rpId);

    final challenge = _nonce();
    final created = await passkey.createCredential({
      'challenge': challenge,
      'rp': {'id': rpId, 'name': 'vtxos'},
      'user': {'id': _nonce(), 'name': 'e2e', 'displayName': 'e2e'},
      'pubKeyCredParams': [
        {'type': 'public-key', 'alg': -7},
      ],
      'timeout': 60000,
      'attestation': 'none',
    }, debugOrigin);
    expect(_clientData(created), containsPair('origin', debugOrigin));
    expect(_clientData(created), containsPair('challenge', challenge));
    expect(created['clientExtensionResults'], isNot(contains('prf')), reason: 'stripped before it is sent');
    passkey.adopt(created['id'] as String);

    Future<(Uint8List, Map<String, dynamic>)> approve() async {
      late Map<String, dynamic> assertion;
      final seed = await passkey.seedSource.seedDuring(() async {
        assertion = await passkey.assertion({
          'challenge': _nonce(),
          'rpId': rpId,
          'allowCredentials': [
            {'type': 'public-key', 'id': passkey.credentialId},
          ],
          'userVerification': 'required',
        }, debugOrigin);
      });
      return (seed, assertion);
    }

    final (first, assertion) = await approve();
    expect(_clientData(assertion), containsPair('origin', debugOrigin));
    expect(_clientData(assertion), containsPair('type', 'webauthn.get'));
    expect(assertion['clientExtensionResults'], isNot(contains('prf')), reason: 'the seed never goes out');
    expect(first, hasLength(32));

    final (second, _) = await approve();
    expect(second, first, reason: 'the same passkey yields the same seed, or no wallet is recoverable');
  });
}
