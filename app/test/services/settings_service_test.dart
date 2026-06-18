import 'package:flutter_test/flutter_test.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:voiceguard/core/services/settings_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    // Use in-memory Hive for tests
    Hive.init('test_hive');
    await Hive.openBox('settings');
  });

  tearDownAll(() async {
    await Hive.deleteBoxFromDisk('settings');
  });

  setUp(() async {
    await Hive.box('settings').clear();
  });

  group('SettingsService', () {
    test('initialises with defaults', () async {
      await SettingsService.init();
      final s = SettingsService.instance;

      expect(s.signalingUrl, contains('8000'));
      expect(s.aiBackendUrl,  contains('8000'));
      expect(s.verificationThreshold, closeTo(0.55, 0.01));
    });

    test('saves and retrieves signaling URL', () async {
      await SettingsService.init();
      await SettingsService.instance.saveSignalingUrl('http://10.0.0.2:3000');
      expect(SettingsService.instance.signalingUrl, 'http://10.0.0.2:3000');
    });

    test('saves and retrieves AI backend URL', () async {
      await SettingsService.init();
      await SettingsService.instance.saveAiBackendUrl('http://10.0.0.2:8000');
      expect(SettingsService.instance.aiBackendUrl, 'http://10.0.0.2:8000');
    });

    test('saves and retrieves threshold', () async {
      await SettingsService.init();
      await SettingsService.instance.saveVerificationThreshold(0.70);
      expect(SettingsService.instance.verificationThreshold, closeTo(0.70, 0.001));
    });

    test('sensitivity label reflects threshold', () async {
      await SettingsService.init();

      await SettingsService.instance.saveVerificationThreshold(0.70);
      expect(SettingsService.instance.sensitivityLabel, contains('High'));

      await SettingsService.instance.saveVerificationThreshold(0.55);
      expect(SettingsService.instance.sensitivityLabel, contains('Medium'));

      await SettingsService.instance.saveVerificationThreshold(0.35);
      expect(SettingsService.instance.sensitivityLabel, contains('Low'));
    });

    test('resetToDefaults restores all values', () async {
      await SettingsService.init();
      await SettingsService.instance.saveSignalingUrl('http://evil.example.com');
      await SettingsService.instance.saveVerificationThreshold(0.99);

      await SettingsService.instance.resetToDefaults();

      expect(SettingsService.instance.signalingUrl,
          isNot('http://evil.example.com'));
      expect(SettingsService.instance.verificationThreshold,
          lessThan(0.80));
    });

    test('notifies listeners on change', () async {
      await SettingsService.init();
      int notifyCount = 0;
      SettingsService.instance.addListener(() => notifyCount++);

      await SettingsService.instance.saveSignalingUrl('http://new.server:3000');
      await SettingsService.instance.saveAiBackendUrl('http://new.server:8000');

      expect(notifyCount, greaterThanOrEqualTo(2));
    });
  });
}
