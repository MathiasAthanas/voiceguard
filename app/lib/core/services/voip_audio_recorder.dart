import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:path_provider/path_provider.dart';

/// Records the **remote caller's decoded audio** during a VoIP call by tapping
/// WebRTC's OUTPUT playback buffer instead of the microphone.
///
/// ── Why this works ────────────────────────────────────────────────────────
/// flutter_webrtc's [MediaRecorder] supports [RecorderAudioChannel.OUTPUT],
/// which intercepts audio samples from [OutputAudioSamplesInterceptor] — the
/// same decoded PCM that plays through the earpiece or speaker — before any
/// OS-level audio routing.  This means:
///
///  • No mic competition with WebRTC.
///  • No AEC/AGC/NS distortion — the signal is the raw decoded remote stream.
///  • Works whether the call is on earpiece OR speakerphone.
///  • No VAD needed on device — the backend's Silero VAD validates speech.
///
/// ── Output format ─────────────────────────────────────────────────────────
/// Segments are written as MP4/AAC (flutter_webrtc's [AudioFileRenderer] uses
/// Android MediaCodec AAC wrapped in MP4).  The backend's audio_utils.py
/// decodes these via torchaudio before ML inference.
///
/// ── Usage ─────────────────────────────────────────────────────────────────
/// ```dart
/// final rec = VoipAudioRecorder();
/// rec.onSegmentReady = (mp4Path) async { /* enroll / verify */ };
/// rec.onCaptureIssue = (reason) { /* show error */ };
/// await rec.startMonitoring(segmentSeconds: 5);
/// // ... call ends ...
/// await rec.stopMonitoring();
/// rec.dispose();
/// ```
class VoipAudioRecorder {
  /// Consecutive empty/failed segments before [onCaptureIssue] fires.
  static const int _issueThreshold = 3;

  /// Minimum file size that counts as a real segment (MP4 container overhead
  /// is ~500 bytes; anything smaller is a no-audio stub).
  static const int _minSegmentBytes = 1000;

  bool _isRecording = false;
  bool _isDisposed = false;
  int _consecutiveEmpty = 0;
  bool _issueReported = false;

  final List<String> _tempFiles = [];

  /// Fires for each recorded segment (MP4 file).
  /// The file is deleted automatically after this callback returns.
  Function(String filePath)? onSegmentReady;

  /// Fires (once) when the OUTPUT recorder repeatedly produces empty segments
  /// — usually because the WebRTC connection isn't fully up yet or the peer
  /// connection was torn down.
  Function(String reason)? onCaptureIssue;

  bool get isRecording => _isRecording;

  // ── Public API ─────────────────────────────────────────────────────────────

  Future<void> startMonitoring({int segmentSeconds = 5}) async {
    if (_isDisposed || _isRecording) return;
    _isRecording = true;
    _consecutiveEmpty = 0;
    _issueReported = false;
    debugPrint(
        'VoipOutput: START monitoring (${segmentSeconds}s segments, OUTPUT channel)');
    unawaited(_segmentLoop(segmentSeconds));
  }

  Future<void> stopMonitoring() async {
    if (_isDisposed) return;
    _isRecording = false;
    onSegmentReady = null;
    onCaptureIssue = null;
    await Future.delayed(const Duration(milliseconds: 300));
    _cleanupAllTemp();
  }

  void dispose() {
    _isDisposed = true;
    _isRecording = false;
    onSegmentReady = null;
    onCaptureIssue = null;
    _cleanupAllTemp();
  }

  // ── Segment loop ───────────────────────────────────────────────────────────

  Future<void> _segmentLoop(int segmentSeconds) async {
    while (!_isDisposed && _isRecording) {
      final dir = await getTemporaryDirectory();
      final ts = DateTime.now().millisecondsSinceEpoch;
      final path = '${dir.path}/vg_voip_$ts.mp4';
      _tempFiles.add(path);

      // Each segment gets a fresh MediaRecorder instance — the native layer
      // ties state to the recorderId generated in the constructor, so reusing
      // the same instance after stop() can cause spurious "not started" throws.
      final recorder = MediaRecorder();

      try {
        await recorder.start(path, audioChannel: RecorderAudioChannel.OUTPUT);
      } catch (e) {
        debugPrint('VoipOutput: start error: $e');
        _tempFiles.remove(path);
        _reportIssue('recorder_unavailable');
        _isRecording = false;
        break;
      }

      await Future.delayed(Duration(seconds: segmentSeconds));

      if (_isDisposed || !_isRecording) {
        try {
          await recorder.stop();
        } catch (_) {}
        _deleteFile(path);
        break;
      }

      try {
        await recorder.stop();
      } catch (e) {
        debugPrint('VoipOutput: stop error: $e');
        _deleteFile(path);
        _onEmpty('stop_error');
        continue;
      }

      final file = File(path);
      final size = file.existsSync() ? file.lengthSync() : 0;
      debugPrint('VoipOutput: segment captured ($size bytes)');

      if (size < _minSegmentBytes) {
        // OUTPUT channel might not be ready yet (WebRTC not fully connected)
        // or the peer hung up mid-segment. Wait briefly and retry.
        _deleteFile(path);
        _onEmpty('empty_segment');
        await Future.delayed(const Duration(milliseconds: 500));
        continue;
      }

      _consecutiveEmpty = 0;
      if (_isDisposed || !_isRecording) {
        _deleteFile(path);
        break;
      }

      try {
        await onSegmentReady?.call(path);
      } finally {
        _deleteFile(path);
      }
    }
  }

  // ── Helpers ────────────────────────────────────────────────────────────────

  void _onEmpty(String reason) {
    _consecutiveEmpty++;
    if (_consecutiveEmpty >= _issueThreshold) _reportIssue(reason);
  }

  void _reportIssue(String reason) {
    if (_issueReported) return;
    _issueReported = true;
    debugPrint('VoipOutput: capture issue → $reason');
    onCaptureIssue?.call(reason);
  }

  void _deleteFile(String path) {
    _tempFiles.remove(path);
    try {
      final f = File(path);
      if (f.existsSync()) f.deleteSync();
    } catch (e) {
      debugPrint('VoipOutput: delete error $path: $e');
    }
  }

  void _cleanupAllTemp() {
    for (final p in List<String>.from(_tempFiles)) {
      _deleteFile(p);
    }
  }
}
