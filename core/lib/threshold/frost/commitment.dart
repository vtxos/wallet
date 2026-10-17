import 'dart:convert';
import 'dart:ffi';
import 'dart:typed_data';
import 'package:ffi/ffi.dart';
import 'package:core/threshold/core/identifier.dart';
import 'package:core/threshold/core/share.dart';
import 'package:core/threshold/src/bindings.dart';
import 'package:core/threshold/src/ffi_result.dart';

class SigningNonce {
  final BigInt hiding;
  final BigInt binding;
  final SigningCommitments commitments;
  /// Opaque FFI handle for the Rust-side nonce.
  final Pointer<Void>? _handle;

  SigningNonce(this.hiding, this.binding, this.commitments, [this._handle]);

  Pointer<Void> get handle {
    final h = _handle;
    if (h == null || h.address == 0) {
      throw StateError('SigningNonce has no FFI handle');
    }
    return h;
  }
}

class SigningCommitments {
  /// Compressed point hex.
  final String binding;
  /// Compressed point hex.
  final String hiding;

  SigningCommitments(this.binding, this.hiding);
}

class GroupCommitmentShare {
  final String elem; // compressed hex
  GroupCommitmentShare(this.elem);
}

class GroupCommitment {
  final String elem; // compressed hex
  GroupCommitment(this.elem);
}

/// Generates a new nonce pair and returns the SigningNonce struct.
SigningNonce newNonce(SecretShare secret) {
  final secretHex = _bigIntToHex64(secret);
  final ptr = secretHex.toNativeUtf8();
  try {
    final (data, handle) = callFfi(newNonceFfi(ptr));
    final parsed = jsonDecode(data) as Map<String, dynamic>;

    final hidingHex = parsed['hiding'] as String;
    final bindingHex = parsed['binding'] as String;

    final commitments = SigningCommitments(bindingHex, hidingHex);

    // The actual hiding/binding scalars are inside the Rust handle.
    // We store zero here since they're not needed on the Dart side.
    return SigningNonce(BigInt.zero, BigInt.zero, commitments, handle);
  } finally {
    calloc.free(ptr);
  }
}

extension SigningCommitmentsExt on SigningCommitments {
  GroupCommitmentShare toGroupCommitmentShare(BigInt bindingScalar) {
    // Point arithmetic done in Rust during signing.
    throw UnimplementedError(
      'toGroupCommitmentShare is handled internally by Rust FFI.',
    );
  }
}

class SigningPackage {
  final Map<Identifier, SigningCommitments> commitments;
  final Uint8List message;

  SigningPackage(this.commitments, this.message);

  SigningCommitments? signingCommitment(Identifier id) {
    return commitments[id];
  }

  /// Serialize to JSON format expected by FFI.
  String toJson() {
    final commsMap = <String, dynamic>{};
    for (final entry in commitments.entries) {
      final idHex = _identifierToHex(entry.key);
      commsMap[idHex] = {
        'hiding': entry.value.hiding,
        'binding': entry.value.binding,
      };
    }
    return jsonEncode({
      'commitments': commsMap,
      'message': _bytesToHex(message),
    });
  }
}

/// Compute the group commitment (handled by Rust internally during aggregate).
GroupCommitment computeGroupCommitment(SigningPackage s, dynamic bfl) {
  throw UnimplementedError(
    'computeGroupCommitment is handled internally by Rust FFI.',
  );
}

// ---------------------------------------------------------------------------
// Internal helpers
// ---------------------------------------------------------------------------

String _bigIntToHex64(BigInt v) {
  var h = v.toRadixString(16);
  while (h.length < 64) {
    h = '0$h';
  }
  return h;
}

String _identifierToHex(Identifier id) {
  final bytes = id.serialize();
  return bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
}

String _bytesToHex(Uint8List bytes) {
  return bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
}
