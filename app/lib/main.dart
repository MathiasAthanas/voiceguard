import 'package:flutter/material.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:provider/provider.dart';
import 'app.dart';
import 'core/models/hive_adapters.dart';
import 'core/services/settings_service.dart';
import 'core/services/signaling_service.dart';
import 'core/services/webrtc_service.dart';
import 'core/services/verification_service.dart';
import 'core/services/cellular_call_service.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // ── Hive ───────────────────────────────────────────────────────────────────
  await Hive.initFlutter();

  // Register adapters idempotently (safe on hot-restart)
  if (!Hive.isAdapterRegistered(1)) Hive.registerAdapter(ContactModelAdapter());
  if (!Hive.isAdapterRegistered(2)) Hive.registerAdapter(CallTypeAdapter());
  if (!Hive.isAdapterRegistered(3)) Hive.registerAdapter(CallDirectionAdapter());
  if (!Hive.isAdapterRegistered(4)) Hive.registerAdapter(CallRecordModelAdapter());

  // Open boxes — if a box is corrupt, delete and recreate it so the app always starts.
  for (final boxName in [
    'contacts',
    'call_history',
    'detection_history',
    'settings',
  ]) {
    try {
      await Hive.openBox(boxName);
    } catch (e) {
      debugPrint('Hive: box "$boxName" corrupt, deleting and recreating: $e');
      await Hive.deleteBoxFromDisk(boxName);
      await Hive.openBox(boxName);
    }
  }

  // ── Settings (must run before AppConstants is first read) ──────────────────
  await SettingsService.init();

  runApp(
    MultiProvider(
      providers: [
        ChangeNotifierProvider<SettingsService>.value(
            value: SettingsService.instance),
        ChangeNotifierProvider(create: (_) => SignalingService()),
        ChangeNotifierProvider(create: (_) => WebRTCService()),
        ChangeNotifierProvider(create: (_) => VerificationService()),
        ChangeNotifierProvider(create: (_) => CellularCallService()),
      ],
      child: const VoiceGuardApp(),
    ),
  );
}
