import 'dart:typed_data';
import 'package:convert/convert.dart';
import 'package:ffi/ffi.dart';
import 'package:core/threshold/core/share.dart';
import 'package:core/threshold/core/utils.dart';
import 'package:core/threshold/src/bindings.dart';
import 'package:core/threshold/src/ffi_result.dart';

class Signature {
  /// Compressed point hex for R.
  final String R;
  final BigInt Z;

  Signature(this.R, this.Z);

  factory Signature.fromJson(Map<String, dynamic> json) {
    final R = json['R'] as String;
    final Z = bytesToBigInt(Uint8List.fromList(hex.decode(json['Z'])));
    return Signature(R, Z);
  }

  Map<String, dynamic> toJson() => {
        'R': R,
        'Z': hex.encode(bigIntToBytes(Z)),
      };

  bool get hasEvenY {
    // Compressed point: first byte is 0x02 (even) or 0x03 (odd)
    final firstByte = int.parse(R.substring(0, 2), radix: 16);
    return firstByte == 0x02;
  }

  Signature intoEvenY({bool? isEven}) {
    final currentIsEven = isEven ?? hasEvenY;
    if (!currentIsEven) {
      // Flip prefix byte 02<->03
      final prefix = R.substring(0, 2) == '02' ? '03' : '02';
      return Signature('$prefix${R.substring(2)}', Z);
    }
    return this;
  }

  /// BIP-340 signature serialization: 64 bytes (32-byte R x-only + 32-byte s).
  Uint8List serialize() {
    final rBytes = Uint8List.fromList(hex.decode(R));
    final zBytes = bigIntToBytes(Z);

    final out = Uint8List(64);

    // R bytes: skip first byte (0x02 or 0x03)
    out.setRange(0, 32, rBytes.sublist(1));

    // Z bytes: big endian, padded to 32 bytes
    final zOffset = 32 + (32 - zBytes.length);
    out.setRange(zOffset, 64, zBytes);

    return out;
  }

  /// Verify signature against public key P and message m.
  Signature verify(VerifyingKey pk, Uint8List message) {
    // Delegate to Rust via verifySchnorrSignature
    final pkHex = pk.E;
    final sigBytes = serialize();
    final sigHex = hex.encode(sigBytes);
    final msgBytes = toNativeBytes(message);
    final pkPtr = pkHex.toNativeUtf8();
    final sigPtr = sigHex.toNativeUtf8();
    try {
      final result = callFfiData(
        verifySchnorrFfi(pkPtr, msgBytes, message.length, sigPtr),
      );
      if (result != 'true') {
        throw Exception("Invalid signature");
      }
      return intoEvenY();
    } finally {
      calloc.free(pkPtr);
      calloc.free(sigPtr);
      calloc.free(msgBytes);
    }
  }
}

BigInt computeChallenge(String rHex, VerifyingKey vk, Uint8List message) {
  // BIP-340: e = hash_BIP0340/challenge(bytes(R) || bytes(P) || m)
  // bytes(R) and bytes(P) are x-only (32 bytes)
  final rBytes = hex.decode(rHex).sublist(1);
  final pBytes = hex.decode(vk.E).sublist(1);

  final builder = BytesBuilder();
  builder.add(rBytes);
  builder.add(pBytes);
  builder.add(message);

  return taggedHash("BIP0340/challenge", builder.toBytes());
}
