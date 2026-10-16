import 'dart:typed_data';
import 'package:ffi/ffi.dart';
import 'package:core/threshold/core/errors.dart';
import 'package:core/threshold/core/utils.dart';
import 'package:core/threshold/src/bindings.dart';
import 'package:core/threshold/src/ffi_result.dart';

class Identifier {
  final BigInt s;

  Identifier(this.s) {
    if (s == BigInt.zero) {
      throw InvalidZeroScalarException("identifier cannot be zero");
    }
  }

  BigInt toScalar() => s;

  static Identifier derive(Uint8List msg) {
    final ptr = toNativeBytes(msg);
    try {
      final resultHex = callFfiData(identifierDeriveFfi(ptr, msg.length));
      final scalar = BigInt.parse(resultHex, radix: 16);
      return Identifier(scalar);
    } finally {
      calloc.free(ptr);
    }
  }

  Uint8List serialize() {
    return bigIntToBytes(s);
  }

  static Identifier deserialize(Uint8List b) {
    final scalar = bytesToBigInt(b);
    return Identifier(scalar);
  }

  @override
  String toString() {
    return 'Identifier(${s.toRadixString(16)})';
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is Identifier &&
          runtimeType == other.runtimeType &&
          s == other.s;

  @override
  int get hashCode => s.hashCode;

  int compareTo(Identifier other) {
    return s.compareTo(other.s);
  }

  bool less(Identifier other) {
    return compareTo(other) < 0;
  }
}

Identifier identifierFromUint16(int n) {
  if (n == 0) {
    throw InvalidZeroScalarException("n must be non-zero");
  }
  return Identifier(BigInt.from(n));
}
