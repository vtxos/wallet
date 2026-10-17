/// FfiResult struct mapping and helpers for calling FFI functions.
library;

import 'dart:ffi';
import 'package:ffi/ffi.dart';

import 'native_library.dart';

/// Mirrors the C FfiResult struct.
final class FfiResult extends Struct {
  @Bool()
  external bool success;

  external Pointer<Utf8> data;
  external Pointer<Utf8> error;
  external Pointer<Void> handle;
}

/// Typedef for the free function.
typedef _FreeResultNative = Void Function(Pointer<FfiResult>);
typedef _FreeResultDart = void Function(Pointer<FfiResult>);

typedef _FreeHandleNative = Void Function(Pointer<Void>, Uint32);
typedef _FreeHandleDart = void Function(Pointer<Void>, int);

final _freeResult = nativeLib
    .lookupFunction<_FreeResultNative, _FreeResultDart>('threshold_free_result');

final freeHandle = nativeLib
    .lookupFunction<_FreeHandleNative, _FreeHandleDart>('threshold_free_handle');

/// Handle type IDs (must match Rust constants).
const int handleRound1Secret = 1;
const int handleRound2Secret = 2;
const int handleSigningNonce = 3;
const int handleAuthSigner = 4;

/// Call an FFI function, extract result, and free the FfiResult.
///
/// Returns (data_string, handle_pointer) on success.
/// Throws on failure.
(String, Pointer<Void>) callFfi(Pointer<FfiResult> resultPtr) {
  try {
    final result = resultPtr.ref;
    if (!result.success) {
      final errorMsg = result.error.address != 0
          ? result.error.toDartString()
          : 'unknown FFI error';
      throw Exception('FFI error: $errorMsg');
    }
    final data =
        result.data.address != 0 ? result.data.toDartString() : '';
    final handle = result.handle;
    return (data, handle);
  } finally {
    _freeResult(resultPtr);
  }
}

/// Call an FFI function and return just the data string.
String callFfiData(Pointer<FfiResult> resultPtr) {
  final (data, _) = callFfi(resultPtr);
  return data;
}
