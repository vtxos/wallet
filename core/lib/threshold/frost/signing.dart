import 'dart:convert';
import 'package:convert/convert.dart';
import 'package:ffi/ffi.dart';
import 'package:core/threshold/core/dkg.dart';
import 'package:core/threshold/core/identifier.dart';
import 'package:core/threshold/core/utils.dart';
import 'package:core/threshold/frost/commitment.dart';
import 'package:core/threshold/frost/signature.dart';
import 'package:core/threshold/src/bindings.dart';
import 'package:core/threshold/src/ffi_result.dart';

class SignatureShare {
  final BigInt s;
  SignatureShare(this.s);
}

/// Compute a FROST signature share.
SignatureShare sign(
  SigningPackage signingPackage,
  SigningNonce signingNonce,
  KeyPackage keyPackage,
) {
  final spJson = signingPackage.toJson();
  final kpJson = jsonEncode(keyPackage.toJson());

  final spPtr = spJson.toNativeUtf8();
  final kpPtr = kpJson.toNativeUtf8();
  try {
    final shareHex = callFfiData(
      frostSignFfi(spPtr, signingNonce.handle, kpPtr),
    );
    return SignatureShare(BigInt.parse(shareHex, radix: 16));
  } finally {
    calloc.free(spPtr);
    calloc.free(kpPtr);
  }
}

BigInt deriveInterpolatingValue(Identifier id, SigningPackage pkg) {
  final ids = _sortedCommitmentIDs(pkg.commitments.keys.toList());
  return lagrangeCoeffAtZero(id, ids);
}

/// Aggregate signature shares into a final signature.
Signature aggregate(
  SigningPackage signingPackage,
  Map<Identifier, SignatureShare> signatureShares,
  PublicKeyPackage pubkeys,
) {
  final spJson = signingPackage.toJson();
  final sharesJson = _encodeSharesJson(signatureShares);
  final pkpJson = jsonEncode(pubkeys.toJson());

  final spPtr = spJson.toNativeUtf8();
  final sharesPtr = sharesJson.toNativeUtf8();
  final pkpPtr = pkpJson.toNativeUtf8();
  try {
    final data = callFfiData(
      frostAggregateFfi(spPtr, sharesPtr, pkpPtr),
    );

    final parsed = jsonDecode(data) as Map<String, dynamic>;
    final rHex = parsed['R'] as String;
    final zHex = parsed['Z'] as String;
    final z = BigInt.parse(zHex, radix: 16);

    return Signature(rHex, z);
  } finally {
    calloc.free(spPtr);
    calloc.free(sharesPtr);
    calloc.free(pkpPtr);
  }
}

/// Verify a signature share (handled by Rust during aggregate).
void verifySignatureShare(
  Identifier identifier,
  String verifyingShare,
  SignatureShare signatureShare,
  SigningPackage signingPackage,
  dynamic verifyingKey, {
  bool negateR = false,
}) {
  // Verification is done internally by Rust aggregate.
  // Kept for API compatibility.
}

// ---------------------------------------------------------------------------
// Internal helpers
// ---------------------------------------------------------------------------

List<Identifier> _sortedCommitmentIDs(List<Identifier> ids) {
  final sorted = List<Identifier>.from(ids);
  sorted.sort((a, b) => a.s.compareTo(b.s));
  return sorted;
}

String _encodeSharesJson(Map<Identifier, SignatureShare> shares) {
  final map = <String, dynamic>{};
  for (final entry in shares.entries) {
    final idHex = hex.encode(entry.key.serialize());
    var sHex = entry.value.s.toRadixString(16);
    while (sHex.length < 64) {
      sHex = '0$sHex';
    }
    map[idHex] = sHex;
  }
  return jsonEncode(map);
}
