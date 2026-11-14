import 'dart:ffi';
import 'dart:io';

/// Load the Core Haptics library.
DynamicLibrary loadCoreHapticsLibrary() {
  /// Load the Core Haptics library from the process.
  if (Platform.isIOS || Platform.isMacOS) {
    // Symbols are linked directly from the SwiftPM-built dynamic library.
    const symbol = 'chffi_engine_create';
    final process = DynamicLibrary.process();
    if (process.providesSymbol(symbol)) return process;
    final debugDylib = File('${Platform.resolvedExecutable}.debug.dylib');
    if (debugDylib.existsSync()) return DynamicLibrary.open(debugDylib.path);
    return process;
  }
  throw UnsupportedError('Core Haptics is only available on iOS or macOS.');
}
