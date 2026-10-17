import 'dart:typed_data';
import 'package:convert/convert.dart';
import 'package:core/threshold/core/commitment.dart';
import 'package:core/threshold/core/errors.dart';
import 'package:core/threshold/core/identifier.dart';
import 'package:core/threshold/core/utils.dart';
import 'package:core/threshold/core/dkg.dart';

typedef SecretShare = BigInt;

/// Compressed point hex string (66 chars for 33 bytes).
typedef VerifyingShareHex = String;

class VerifyingKey {
  /// Compressed point hex (e.g. "02abcd...").
  final String E;
  VerifyingKey({required this.E});

  bool verify(Uint8List message, DKGSignature signature) {
    // In the FFI version, signature verification is handled by Rust.
    throw UnimplementedError(
      'VerifyingKey.verify is not available in FFI version. '
      'Use Signature.verify or verifySchnorrSignature instead.',
    );
  }

  bool get hasEvenY {
    // Compressed point: first byte is 0x02 (even) or 0x03 (odd)
    final firstByte = int.parse(E.substring(0, 2), radix: 16);
    return firstByte == 0x02;
  }

  VerifyingKey intoEvenY({bool? isEven}) {
    final currentIsEven = isEven ?? hasEvenY;
    if (!currentIsEven) {
      // Negate the point: flip the prefix byte and negate x (handled by Rust)
      // For compressed points, negation flips 02<->03
      final prefix = E.substring(0, 2) == '02' ? '03' : '02';
      return VerifyingKey(E: '$prefix${E.substring(2)}');
    }
    return this;
  }

  factory VerifyingKey.fromJson(Map<String, dynamic> json) {
    if (json['E'] is List) {
      // Old format: list of byte ints
      final bytes =
          Uint8List.fromList((json['E'] as List).map((e) => e as int).toList());
      return VerifyingKey(E: hex.encode(bytes));
    }
    // New format: hex string
    return VerifyingKey(E: json['E'] as String);
  }

  Map<String, dynamic> toJson() => {
        'E': hex.decode(E).toList(),
      };
}

class ThresholdShare {
  final Identifier identifier;
  final SecretShare secretShare;
  final String verifyingShare; // compressed hex
  final VerifiableSecretSharingCommitment commitment;

  ThresholdShare(
    this.identifier,
    this.secretShare,
    this.verifyingShare,
    this.commitment,
  );

  (String, VerifyingKey) verify() {
    final left = elemBaseMul(secretShare);
    final right = commitment.getVerifyingShare(identifier);

    if (left != right) {
      throw InvalidSecretShareException("invalid secret share");
    }

    final groupVK = commitment.toVerifyingKey();
    return (right, groupVK);
  }
}

SecretKey reconstruct(
  int minParticipants,
  Map<Identifier, SecretShare> participants,
) {
  if (participants.isEmpty) {
    throw IncorrectNumberOfSharesException("incorrect number of shares");
  }
  if (participants.length < minParticipants) {
    throw IncorrectNumberOfSharesException("incorrect number of shares");
  }

  final ids = participants.keys.toList();
  var secret = modNZero();

  for (final entry in participants.entries) {
    final i = entry.key;
    final k = entry.value;

    final l = lagrangeCoeffAtZero(i, ids);
    final part = (l * k) % secp256k1Curve.n;
    secret = (secret + part) % secp256k1Curve.n;
  }

  return SecretKey(secret);
}
