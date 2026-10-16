/// Native library loader for enclave_ffi shared library.
library;

import 'dart:ffi';
import 'dart:io';

DynamicLibrary? _cachedLib;

DynamicLibrary get nativeLib {
  _cachedLib ??= _loadLibrary();
  return _cachedLib!;
}

DynamicLibrary _loadLibrary() {
  // Check environment variable first.
  final envPath = Platform.environment['ENCLAVE_FFI_LIB'];
  if (envPath != null && envPath.isNotEmpty) {
    return DynamicLibrary.open(envPath);
  }

  final libName = Platform.isMacOS
      ? 'libmpcwallet_ffi.dylib'
      : 'libmpcwallet_ffi.so';

  if (Platform.isAndroid) {
    return DynamicLibrary.open(libName);
  }

  if (!Platform.isLinux && !Platform.isMacOS) {
    throw UnsupportedError('Unsupported platform: ${Platform.operatingSystem}');
  }

  // Try system/LD_LIBRARY_PATH first.
  try {
    return DynamicLibrary.open(libName);
  } catch (_) {}

  // Walk up from cwd looking for ffi/target/release/.
  var dir = Directory.current;
  for (var i = 0; i < 5; i++) {
    final candidate = '${dir.path}/ffi/target/release/$libName';
    if (File(candidate).existsSync()) {
      return DynamicLibrary.open(candidate);
    }
    final parent = dir.parent;
    if (parent.path == dir.path) break;
    dir = parent;
  }

  throw StateError(
    'Could not find $libName. '
    'Build it with: cd ffi && cargo build --release\n'
    'Or set ENCLAVE_FFI_LIB environment variable.',
  );
}
