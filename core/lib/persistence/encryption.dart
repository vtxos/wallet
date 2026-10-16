import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:hive/hive.dart';

/// Abstract interface for providing encryption keys.
///
/// Implementations can use platform-specific secure storage:
/// - iOS: Keychain
/// - Android: EncryptedSharedPreferences or Android Keystore
/// - Desktop: OS-specific keychain or secure storage
abstract class SecureKeyProvider {
  /// Returns a 32-byte encryption key.
  Future<Uint8List> getOrCreateKey();

  /// Clears any cached key material (for logout/reset scenarios).
  Future<void> clearKey();
}

/// Derives a 32-byte key from a password using Argon2id.
///
/// The [salt] must be stable for the lifetime of the encrypted store
/// (persist it in a plaintext sibling location). Callers cache the derived
/// key for the session — re-deriving on every Hive op would be prohibitively
/// slow (Argon2id is intentionally expensive).
class Argon2PasswordKeyProvider implements SecureKeyProvider {
  final String _password;
  final List<int> _salt;
  final int _memoryKib;
  final int _iterations;
  final int _parallelism;
  Uint8List? _cachedKey;

  Argon2PasswordKeyProvider({
    required String password,
    required List<int> salt,
    int memoryKib = 64 * 1024,
    int iterations = 3,
    int parallelism = 4,
  })  : _password = password,
        _salt = salt,
        _memoryKib = memoryKib,
        _iterations = iterations,
        _parallelism = parallelism;

  @override
  Future<Uint8List> getOrCreateKey() async {
    if (_cachedKey != null) return _cachedKey!;
    final kdf = Argon2id(
      parallelism: _parallelism,
      memory: _memoryKib,
      iterations: _iterations,
      hashLength: 32,
    );
    final derived = await kdf.deriveKey(
      secretKey: SecretKey(utf8.encode(_password)),
      nonce: _salt,
    );
    final bytes = await derived.extractBytes();
    _cachedKey = Uint8List.fromList(bytes);
    return _cachedKey!;
  }

  @override
  Future<void> clearKey() async {
    if (_cachedKey != null) {
      _cachedKey!.fillRange(0, _cachedKey!.length, 0);
    }
    _cachedKey = null;
  }
}

/// Creates a HiveAesCipher from a 32-byte key.
HiveCipher createCipherFromKey(Uint8List key) {
  if (key.length != 32) {
    throw ArgumentError('Encryption key must be exactly 32 bytes');
  }
  return HiveAesCipher(key);
}

/// Creates a HiveAesCipher from a key provider.
Future<HiveCipher> createCipher(SecureKeyProvider keyProvider) async {
  final key = await keyProvider.getOrCreateKey();
  return createCipherFromKey(key);
}

/// Convenience: derive a Hive cipher directly from a password + salt.
Future<HiveCipher> createCipherFromPassword({
  required String password,
  required List<int> salt,
}) async {
  final provider = Argon2PasswordKeyProvider(password: password, salt: salt);
  final key = await provider.getOrCreateKey();
  return createCipherFromKey(key);
}
