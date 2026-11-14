export 'src/api/errors.dart';
export 'src/api/haptics.dart';
export 'src/api/types.dart';
export 'src/platform/haptic_service.dart'
    show HapticServiceFactory, HapticServiceBase;

/// Dart-only plugin registrant placeholder.
class CoreHapticsPlugin {
  /// Flutter calls this while registering plugins. Core Haptics needs no registrar.
  static void registerWith() {}
}
