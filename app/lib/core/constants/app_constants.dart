import '../services/settings_service.dart';

/// App-wide constants.
///
/// URL/threshold fields are dynamic — they read from [SettingsService] so
/// users can change them on the Settings screen without recompiling.
class AppConstants {
  // ── Dynamic (user-configurable via Settings screen) ────────────────────────
  static String get signalingServerUrl => SettingsService.instance.signalingUrl;
  static String get aiBackendUrl       => SettingsService.instance.aiBackendUrl;

  // ── Verification thresholds ────────────────────────────────────────────────
  /// Primary matching threshold — reads from user-facing sensitivity setting.
  static double get verifiedThreshold => SettingsService.instance.verificationThreshold;
  static const double highConfidenceThreshold = 0.65;
  static const double spoofThreshold          = 0.5;

  // ── Audio settings ─────────────────────────────────────────────────────────
  static const int sampleRate                  = 16000;
  static const int segmentDurationSeconds      = 3;
  static const int verificationIntervalSeconds = 5;

  // ── Enrollment ─────────────────────────────────────────────────────────────
  static const int minEnrollmentSamples         = 1;
  static const int recommendedEnrollmentSamples = 3;
  static const int enrollmentDurationSeconds    = 10;

  // ── App info ───────────────────────────────────────────────────────────────
  static const String appName    = 'VoiceGuard';
  static const String appVersion = '1.0.0';
}
