import 'package:flutter/material.dart';
import 'package:hive_flutter/hive_flutter.dart';

/// Persisted, reactive application settings.
///
/// Stored in the existing Hive `settings` box.
/// Call [SettingsService.init()] once at startup before using [instance].
class SettingsService extends ChangeNotifier {
  static SettingsService? _instance;
  static SettingsService get instance {
    assert(_instance != null,
        'SettingsService.init() must be called before accessing instance');
    return _instance!;
  }

  static Future<void> init() async {
    _instance ??= SettingsService._();
    await _instance!._load();
  }

  SettingsService._();

  // ── Defaults ───────────────────────────────────────────────────────────────
  static const String _defaultSignalingUrl = 'http://192.168.1.10:8000';
  static const String _defaultAiBackendUrl  = 'http://192.168.1.10:8000';
  static const double _defaultThreshold     = 0.55;

  static const String _keySignalingUrl  = 'signalingUrl';
  static const String _keyAiBackendUrl  = 'aiBackendUrl';
  static const String _keyThreshold     = 'verificationThreshold';

  // ── Runtime values ─────────────────────────────────────────────────────────
  String _signalingUrl  = _defaultSignalingUrl;
  String _aiBackendUrl  = _defaultAiBackendUrl;
  double _threshold     = _defaultThreshold;

  String get signalingUrl  => _signalingUrl;
  String get aiBackendUrl  => _aiBackendUrl;
  double get verificationThreshold => _threshold;

  // ── Load from Hive ─────────────────────────────────────────────────────────
  Future<void> _load() async {
    final box = Hive.box('settings');
    _signalingUrl = box.get(_keySignalingUrl, defaultValue: _defaultSignalingUrl) as String;
    _aiBackendUrl = box.get(_keyAiBackendUrl, defaultValue: _defaultAiBackendUrl) as String;
    _threshold    = (box.get(_keyThreshold,   defaultValue: _defaultThreshold) as num).toDouble();
  }

  // ── Save to Hive + notify ──────────────────────────────────────────────────
  Future<void> saveSignalingUrl(String url) async {
    _signalingUrl = url.trim();
    await Hive.box('settings').put(_keySignalingUrl, _signalingUrl);
    notifyListeners();
  }

  Future<void> saveAiBackendUrl(String url) async {
    _aiBackendUrl = url.trim();
    await Hive.box('settings').put(_keyAiBackendUrl, _aiBackendUrl);
    notifyListeners();
  }

  Future<void> saveVerificationThreshold(double value) async {
    _threshold = value;
    await Hive.box('settings').put(_keyThreshold, value);
    notifyListeners();
  }

  /// Convenience label for the current sensitivity level.
  String get sensitivityLabel {
    if (_threshold >= 0.65) return 'High (strict)';
    if (_threshold >= 0.50) return 'Medium (recommended)';
    return 'Low (lenient)';
  }

  /// Reset all settings to defaults.
  Future<void> resetToDefaults() async {
    await saveSignalingUrl(_defaultSignalingUrl);
    await saveAiBackendUrl(_defaultAiBackendUrl);
    await saveVerificationThreshold(_defaultThreshold);
  }
}
