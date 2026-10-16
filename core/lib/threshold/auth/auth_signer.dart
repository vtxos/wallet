import 'dart:ffi';
import 'dart:typed_data';
import 'package:convert/convert.dart';
import 'package:ffi/ffi.dart';
import 'package:core/threshold/core/dkg.dart';
import 'package:core/threshold/core/utils.dart';
import 'package:core/threshold/frost/signature.dart';
import 'package:core/threshold/src/bindings.dart';
import 'package:core/threshold/src/ffi_result.dart';
import 'auth_message.dart';

/// Single-key Schnorr signer for authentication.
///
/// This class provides BIP-340 compatible Schnorr signatures using
/// a single private key (not threshold). Used for authenticating
/// gRPC requests before MPC operations.
class AuthSigner {
  final Pointer<Void> _handle;
  final String _publicKeyCompressedHex;

  AuthSigner._(this._handle, this._publicKeyCompressedHex);

  /// Creates an AuthSigner from a secret key scalar.
  factory AuthSigner.fromSecretKey(BigInt secretKey) {
    final secretHex = _bigIntToHex64(secretKey);
    final ptr = secretHex.toNativeUtf8();
    try {
      final (pkHex, handle) = callFfi(authSignerCreateFfi(ptr));
      return AuthSigner._(handle, pkHex);
    } finally {
      calloc.free(ptr);
    }
  }

  /// Creates an AuthSigner from a SecretKey object.
  factory AuthSigner.fromSecret(SecretKey secret) {
    return AuthSigner.fromSecretKey(secret.scalar);
  }

  /// Creates an AuthSigner from private key bytes (32 bytes, big-endian).
  factory AuthSigner.fromBytes(Uint8List privateKeyBytes) {
    if (privateKeyBytes.length != 32) {
      throw ArgumentError('Private key must be exactly 32 bytes');
    }
    final scalar = bytesToBigInt(privateKeyBytes);
    return AuthSigner.fromSecretKey(scalar);
  }

  /// Returns the compressed public key bytes (33 bytes).
  Uint8List get publicKeyCompressed =>
      Uint8List.fromList(hex.decode(_publicKeyCompressedHex));

  /// Returns the x-only public key bytes (32 bytes) for BIP-340.
  Uint8List get publicKeyXOnly =>
      Uint8List.fromList(hex.decode(_publicKeyCompressedHex)).sublist(1);

  /// Signs a message using BIP-340 Schnorr signature scheme.
  ///
  /// Returns a Signature object.
  Signature sign(Uint8List message) {
    final msgPtr = toNativeBytes(message);
    try {
      final sigHex = callFfiData(
        authSignerSignFfi(_handle, msgPtr, message.length),
      );
      // sigHex is 128 chars = 64 bytes (32 R x-only + 32 s)
      final sigBytes = hex.decode(sigHex);

      // Reconstruct R as compressed point with 0x02 prefix (even Y)
      final rXBytes = Uint8List(33);
      rXBytes[0] = 0x02;
      rXBytes.setRange(1, 33, sigBytes.sublist(0, 32));
      final rHex = hex.encode(rXBytes);

      final z = bytesToBigInt(Uint8List.fromList(sigBytes.sublist(32, 64)));
      return Signature(rHex, z);
    } finally {
      calloc.free(msgPtr);
    }
  }

  /// Signs an AuthMessage and returns the serialized signature bytes.
  Uint8List signAuthMessage(AuthMessage authMessage) {
    final signature = sign(authMessage.messageBytes);
    return signature.serialize();
  }

  /// Creates a signature for a specific operation.
  Uint8List signOperation({
    required String operation,
    required String userIdHex,
    int? timestampMs,
  }) {
    final authMessage = AuthMessage(
      operation: operation,
      timestampMs: timestampMs ?? DateTime.now().millisecondsSinceEpoch,
      userIdHex: userIdHex,
    );
    return signAuthMessage(authMessage);
  }
}

/// Verifies a BIP-340 Schnorr signature against a public key.
bool verifySchnorrSignature({
  required Uint8List publicKeyCompressed,
  required Uint8List message,
  required Uint8List signatureBytes,
}) {
  if (signatureBytes.length != 64) return false;
  if (publicKeyCompressed.length != 33) return false;

  final pkHex = hex.encode(publicKeyCompressed);
  final sigHex = hex.encode(signatureBytes);

  final pkPtr = pkHex.toNativeUtf8();
  final msgPtr = toNativeBytes(message);
  final sigPtr = sigHex.toNativeUtf8();
  try {
    final result = callFfiData(
      verifySchnorrFfi(pkPtr, msgPtr, message.length, sigPtr),
    );
    return result == 'true';
  } catch (_) {
    return false;
  } finally {
    calloc.free(pkPtr);
    calloc.free(msgPtr);
    calloc.free(sigPtr);
  }
}

String _bigIntToHex64(BigInt v) {
  var h = v.toRadixString(16);
  while (h.length < 64) {
    h = '0$h';
  }
  return h;
}
