/// FfiResult struct mapping and helpers for calling ark FFI functions.
library;

import 'dart:ffi';
import 'package:ffi/ffi.dart';

import 'native_library.dart';

/// Mirrors the C FfiResult struct from ark-ffi.
final class FfiResult extends Struct {
  @Bool()
  external bool success;

  external Pointer<Utf8> data;
  external Pointer<Utf8> error;
}

/// Typedef for the free function.
typedef _FreeResultNative = Void Function(Pointer<FfiResult>);
typedef _FreeResultDart = void Function(Pointer<FfiResult>);

final _freeResult = nativeLib
    .lookupFunction<_FreeResultNative, _FreeResultDart>('ark_free_result');

/// Call an ark FFI function, extract the data string, and free the FfiResult.
///
/// Throws on failure.
String callFfiData(Pointer<FfiResult> resultPtr) {
  try {
    final result = resultPtr.ref;
    if (!result.success) {
      final errorMsg = result.error.address != 0
          ? result.error.toDartString()
          : 'unknown ark FFI error';
      throw Exception('Ark FFI error: $errorMsg');
    }
    return result.data.address != 0 ? result.data.toDartString() : '';
  } finally {
    _freeResult(resultPtr);
  }
}
