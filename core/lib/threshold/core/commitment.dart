import 'package:core/threshold/core/errors.dart';
import 'package:core/threshold/core/identifier.dart';
import 'package:core/threshold/core/share.dart';

/// Compressed point hex string.
typedef CoefficientCommitment = String;
typedef VerifyingShare = String;

class VerifiableSecretSharingCommitment {
  /// List of compressed point hex strings.
  final List<CoefficientCommitment> coeffs;

  VerifiableSecretSharingCommitment(this.coeffs);

  factory VerifiableSecretSharingCommitment.fromJson(dynamic jsonData) {
    List<String> hexStrings;

    if (jsonData is List) {
      hexStrings = List<String>.from(jsonData.map((item) => item.toString()));
    } else if (jsonData is Map && jsonData.containsKey('coeffs')) {
      hexStrings =
          List<String>.from(jsonData['coeffs'].map((item) => item.toString()));
    } else {
      throw FormatException(
          'Invalid JSON structure for VerifiableSecretSharingCommitment');
    }

    return VerifiableSecretSharingCommitment(hexStrings);
  }

  List<String> toJson() {
    return coeffs.toList();
  }

  VerifyingShare getVerifyingShare(Identifier id) {
    // This requires polynomial evaluation on points — delegate to Rust
    // by evaluating using the identifier and commitment coefficients.
    // For the FFI version, this is only called for share verification
    // which happens on the Rust side. If called directly, we need
    // the point arithmetic.
    //
    // We can compute this via: sum of coeffs[k] * x^k
    // Using elemBaseMul for scalar*G doesn't help here (we need scalar*Point).
    // Since all callers that need this (dkgPart3, ThresholdShare.verify)
    // now go through Rust, this shouldn't be called in practice.
    throw UnimplementedError(
      'getVerifyingShare requires point arithmetic — handled by Rust FFI.',
    );
  }

  VerifyingKey toVerifyingKey() {
    if (coeffs.isEmpty) {
      throw InvalidCommitVectorException(
          "Cannot create verifying key from empty commitment vector.");
    }
    return VerifyingKey(E: coeffs[0]);
  }
}

VerifiableSecretSharingCommitment sumCommitments(
    List<VerifiableSecretSharingCommitment> commitments) {
  if (commitments.isEmpty) {
    throw IncorrectNumberOfCommitmentsException(
        "Commitment list cannot be empty.");
  }

  // Summing commitments requires point addition — handled by Rust in all
  // DKG paths. This function is kept for API compatibility.
  throw UnimplementedError(
    'sumCommitments requires point arithmetic — handled by Rust FFI.',
  );
}
