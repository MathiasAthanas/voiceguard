import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'vad_processor.dart';

/// Bridges the ADB-based shell audio capture (running as Android UID 2000)
/// into the VoiceGuard enrollment / verification pipeline.
///
/// During a cellular call on Android 12+, the OS hardware-mutes all normal
/// [AudioRecord] sources.  [ShellAudioSession] (Kotlin) bypasses this by
/// launching [AudioCaptureMain] via ADB shell as UID 2000, which can use
/// [VOICE_DOWNLINK] — the remote caller's receive audio path — without
/// CAPTURE_AUDIO_OUTPUT permission.  PCM is streamed over a loopback TCP
/// socket and written to 5-second WAV segments.
///
/// This service listens to the [EventChannel] for those WAV paths, runs
/// [VadProcessor.extract] on each one (to drop silence and keep voiced frames),
/// and fires [onSegmentReady] with the filtered file — exactly what
/// [CallAudioRecorder] would have provided.
class ShellAudioService {
  static const _channel = MethodChannel('com.voiceguard/calls');
  static const _events  = EventChannel('com.voiceguard/shell_audio');

  static final ShellAudioService instance = ShellAudioService._();
  ShellAudioService._();

  StreamSubscription<dynamic>? _sub;

  Function(String path)? onSegmentReady;
  Function()? onBlocked;

  // ── Setup status ──────────────────────────────────────────────────────────

  /// Returns `true` when a pairing and a main port have both been saved.
  Future<bool> isReady() async {
    try {
      final s = await _channel.invokeMethod<Map<dynamic, dynamic>>('adbSetupStatus');
      return s?['isPaired'] == true && s?['hasPort'] == true;
    } catch (_) {
      return false;
    }
  }

  Future<Map<String, dynamic>> setupStatus() async {
    try {
      final s = await _channel.invokeMethod<Map<dynamic, dynamic>>('adbSetupStatus');
      return Map<String, dynamic>.from(s ?? {});
    } catch (_) {
      return {};
    }
  }

  // ── ADB management (called from AdbAudioSetupScreen) ─────────────────────

  Future<bool> pair(int pairingPort, String code) async {
    try {
      return await _channel.invokeMethod<bool>('adbStartPairing', {
            'pairingPort': pairingPort,
            'code': code,
          }) ??
          false;
    } catch (_) {
      return false;
    }
  }

  Future<void> setMainPort(int port) async {
    try {
      await _channel.invokeMethod<void>('adbSetMainPort', {'port': port});
    } catch (_) {}
  }

  Future<bool> testConnection() async {
    try {
      return await _channel.invokeMethod<bool>('adbTestConnection') ?? false;
    } catch (_) {
      return false;
    }
  }

  Future<void> reset() async {
    try {
      await _channel.invokeMethod<void>('adbReset');
    } catch (_) {}
  }

  Future<bool> isAccessibilityEnabled() async {
    try {
      return await _channel.invokeMethod<bool>('adbIsAccessibilityEnabled') ?? false;
    } catch (_) {
      return false;
    }
  }

  Future<void> openAccessibilitySettings() async {
    try {
      await _channel.invokeMethod<void>('openAccessibilitySettings');
    } catch (_) {}
  }

  /// Discovers the ADB pairing port via mDNS. Returns the port, or null on
  /// timeout (60 s). Only broadcasts while the "Pair device with pairing code"
  /// dialog is open in Android Developer Options.
  Future<int?> discoverPairingPort() async {
    try {
      return await _channel.invokeMethod<int>('adbDiscoverPairingPort');
    } catch (_) {
      return null;
    }
  }

  /// Discovers the persistent ADB connection port via mDNS. Returns the port,
  /// or null on timeout (15 s). Always broadcasts when Wireless Debugging is on.
  Future<int?> discoverMainPort() async {
    try {
      return await _channel.invokeMethod<int>('adbDiscoverMainPort');
    } catch (_) {
      return null;
    }
  }

  // ── Capture lifecycle ─────────────────────────────────────────────────────

  Future<bool> startCapture() async {
    // Subscribe to the event channel before starting capture so no events
    // are lost in the brief window between the two calls.
    _sub = _events.receiveBroadcastStream().listen(
      _onEvent,
      onError: (_) {},
    );
    try {
      final ok =
          await _channel.invokeMethod<bool>('startShellAudioCapture') ?? false;
      if (!ok) _cleanupSub();
      return ok;
    } catch (e) {
      debugPrint('ShellAudioService: startCapture failed: $e');
      _cleanupSub();
      return false;
    }
  }

  Future<void> stopCapture() async {
    _cleanupSub();
    onSegmentReady = null;
    onBlocked = null;
    try {
      await _channel.invokeMethod<void>('stopShellAudioCapture');
    } catch (_) {}
  }

  // ── Event handling ────────────────────────────────────────────────────────

  void _onEvent(dynamic raw) {
    final event = Map<String, dynamic>.from(raw as Map<dynamic, dynamic>);
    switch (event['type'] as String?) {
      case 'segment':
        final path = event['path'] as String?;
        if (path != null) _processSegment(path);
        break;
      case 'blocked':
        onBlocked?.call();
        break;
    }
  }

  Future<void> _processSegment(String rawPath) async {
    try {
      // VOICE_DOWNLINK is the caller's receive path — use speech mode to keep
      // voiced frames and drop silence, same as speakerphone enrollment.
      final result = await VadProcessor.extract(rawPath, mode: VadMode.speech);
      _safeDelete(rawPath);
      if (result.kept) {
        onSegmentReady?.call(result.path!);
      }
    } catch (e) {
      debugPrint('ShellAudioService: VAD error: $e');
      _safeDelete(rawPath);
    }
  }

  void _safeDelete(String path) {
    try {
      File(path).deleteSync();
    } catch (_) {}
  }

  void _cleanupSub() {
    _sub?.cancel();
    _sub = null;
  }
}
