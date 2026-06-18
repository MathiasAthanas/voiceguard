import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

import 'vad_processor.dart';

/// Records call audio using Android's VOICE_RECOGNITION audio source, which
/// has AEC / AGC / NS disabled, and therefore retains the earpiece bleed of
/// the remote caller's voice in the mic signal.
///
/// Each segment is post-processed by [VadProcessor], which extracts the usable
/// speech windows.  Only those are forwarded to [onSegmentReady].
///
/// ── Platform reality ────────────────────────────────────────────────────────
/// Android does NOT allow a normal app to record the downlink of a cellular
/// call.  VOICE_RECOGNITION captures the local mic plus whatever acoustic bleed
/// of the remote caller leaks in.  Held to the ear that bleed is faint, so
/// reliable capture of the caller needs SPEAKERPHONE.  When VAD keeps skipping
/// segments [onCaptureIssue] fires so the UI can prompt the user.
///
/// ── Usage ─────────────────────────────────────────────────────────────────
/// ```dart
/// final rec = CallAudioRecorder();
/// rec.onSegmentReady = (path) async { /* verify / enroll */ };
/// rec.onCaptureIssue = (reason) { /* prompt for speakerphone */ };
/// await rec.startMonitoring(segmentSeconds: 5, vadMode: VadMode.speech);
/// // ... call ends ...
/// await rec.stopMonitoring();
/// rec.dispose();
/// ```
class CallAudioRecorder {
  static const _channel = MethodChannel('com.voiceguard/calls');

  /// Android MediaRecorder.AudioSource constants passed to Kotlin.
  static const int audioSourceVoiceRecognition = 6; // no AEC/AGC/NS
  static const int audioSourceMic = 1;              // standard mic with AEC

  /// Number of consecutive skipped segments before [onCaptureIssue] fires.
  static const int _issueThreshold = 3;

  bool _isRecording = false;
  bool _isDisposed = false;
  VadMode _vadMode = VadMode.remoteBleed;
  int _audioSource = audioSourceVoiceRecognition;
  int _segmentSeconds = 5;
  int _consecutiveSkips = 0;
  bool _issueReported = false;

  final List<String> _tempFiles = [];

  /// Fires with every VAD-filtered WAV segment.
  /// The file is deleted automatically after the callback returns.
  Function(String filePath)? onSegmentReady;

  /// Fires (once) when several consecutive segments are skipped — i.e. the mic
  /// isn't picking up usable remote-caller audio.  [reason] is the VAD skip
  /// reason (e.g. `silent_capture`, `insufficient_speech`).  Use it to prompt
  /// the user to switch to speakerphone.
  Function(String reason)? onCaptureIssue;

  bool get isRecording => _isRecording;

  // ── Public API ─────────────────────────────────────────────────────────

  Future<void> startMonitoring({
    int segmentSeconds = 5,
    VadMode vadMode = VadMode.remoteBleed,
    int audioSource = audioSourceVoiceRecognition,
  }) async {
    if (_isDisposed || _isRecording) return;
    _isRecording = true;
    _vadMode = vadMode;
    _audioSource = audioSource;
    _segmentSeconds = segmentSeconds;
    _consecutiveSkips = 0;
    _issueReported = false;
    debugPrint('CallAudioRecorder: START monitoring '
        '(cellular, ${segmentSeconds}s segments, vad=${vadMode.name}, source=$audioSource)');
    unawaited(_segmentLoop(segmentSeconds));
  }

  /// Stop recording and restart with a different audio source (e.g. MIC=1
  /// when VOICE_RECOGNITION returns silence on Android 12–13). Preserves
  /// [onSegmentReady] and [onCaptureIssue] callbacks.
  Future<void> restartWithAudioSource(int audioSource,
      {VadMode? vadMode}) async {
    if (_isDisposed) return;
    _isRecording = false;
    _consecutiveSkips = 0;
    _issueReported = false;
    _audioSource = audioSource;
    if (vadMode != null) _vadMode = vadMode;
    try {
      await _channel.invokeMethod('stopCallSegmentRecording');
    } catch (_) {}
    await Future.delayed(const Duration(milliseconds: 300));
    if (_isDisposed) return;
    _isRecording = true;
    debugPrint('CallAudioRecorder: RESTART with source=$audioSource '
        'vad=${_vadMode.name}');
    unawaited(_segmentLoop(_segmentSeconds));
  }

  Future<void> stopMonitoring() async {
    if (_isDisposed) return;
    _isRecording = false;
    onSegmentReady = null;
    onCaptureIssue = null;

    // Ask the native layer to stop (ignore errors — might already be stopped)
    try {
      await _channel.invokeMethod('stopCallSegmentRecording');
    } catch (_) {}

    await Future.delayed(const Duration(milliseconds: 300));
    _cleanupAllTemp();
  }

  void dispose() {
    _isDisposed = true;
    _isRecording = false;
    onSegmentReady = null;
    onCaptureIssue = null;
    try {
      _channel.invokeMethod('stopCallSegmentRecording');
    } catch (_) {}
    _cleanupAllTemp();
  }

  // ── Segment loop ────────────────────────────────────────────────────────

  Future<void> _segmentLoop(int segmentSeconds) async {
    while (!_isDisposed && _isRecording) {
      final rawPath = await _uniqueTempPath('vg_raw');

      // ── Start native recording (preferred: VOICE_RECOGNITION, auto-falls back in Kotlin) ─
      try {
        await _channel.invokeMethod(
          'startCallSegmentRecording',
          {'path': rawPath, 'audioSource': _audioSource},
        );
        _tempFiles.add(rawPath);
      } on PlatformException catch (e) {
        debugPrint('CallAudioRecorder: native start failed: ${e.message}');
        // Native recording not available — surface it and stop gracefully.
        _reportIssue('recorder_unavailable');
        _isRecording = false;
        break;
      }

      // ── Record for segmentSeconds ─────────────────────────────────────
      await Future.delayed(Duration(seconds: segmentSeconds));

      if (_isDisposed || !_isRecording) {
        try {
          await _channel.invokeMethod('stopCallSegmentRecording');
        } catch (_) {}
        _deleteFile(rawPath);
        break;
      }

      // ── Stop and finalise the WAV ─────────────────────────────────────
      try {
        await _channel.invokeMethod('stopCallSegmentRecording');
      } catch (e) {
        debugPrint('CallAudioRecorder: native stop error: $e');
        _deleteFile(rawPath);
        continue;
      }

      final rawFile = File(rawPath);
      if (!rawFile.existsSync()) {
        debugPrint('CallAudioRecorder: native produced no file');
        _tempFiles.remove(rawPath);
        _onSkip('capture_missing');
        continue;
      }
      debugPrint(
          'CallAudioRecorder: segment captured (${rawFile.lengthSync()} bytes)');

      // ── VAD filter ────────────────────────────────────────────────────
      final result =
          await VadProcessor.extract(rawPath, mode: _vadMode);
      _deleteFile(rawPath);

      if (!result.kept) {
        debugPrint('CallAudioRecorder: skipped segment '
            '(${result.skipReason ?? 'no clean remote speech'})');
        _onSkip(result.skipReason ?? 'insufficient_speech');
        continue;
      }

      _consecutiveSkips = 0;
      _tempFiles.add(result.path!);
      await _fireCallback(result.path!);
    }
  }

  // ── Helpers ──────────────────────────────────────────────────────────────

  void _onSkip(String reason) {
    _consecutiveSkips++;
    if (_consecutiveSkips >= _issueThreshold) {
      _reportIssue(reason);
    }
  }

  void _reportIssue(String reason) {
    if (_issueReported) return;
    _issueReported = true;
    debugPrint('CallAudioRecorder: capture issue → $reason');
    onCaptureIssue?.call(reason);
  }

  Future<void> _fireCallback(String path) async {
    if (_isDisposed || onSegmentReady == null) {
      _deleteFile(path);
      return;
    }
    try {
      await onSegmentReady!.call(path);
    } finally {
      _deleteFile(path);
    }
  }

  Future<String> _uniqueTempPath(String prefix) async {
    final dir = await getTemporaryDirectory();
    return '${dir.path}/${prefix}_${DateTime.now().millisecondsSinceEpoch}.wav';
  }

  void _deleteFile(String path) {
    _tempFiles.remove(path);
    try {
      final f = File(path);
      if (f.existsSync()) f.deleteSync();
    } catch (e) {
      debugPrint('CallAudioRecorder: delete error $path: $e');
    }
  }

  void _cleanupAllTemp() {
    for (final p in List<String>.from(_tempFiles)) {
      _deleteFile(p);
    }
  }
}
