import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:record/record.dart';
import 'package:path_provider/path_provider.dart';

import 'vad_processor.dart';

/// Audio capture service with automatic temp-file cleanup.
///
/// Used for two distinct purposes:
///
///  1. **Enrollment recordings** (outside of calls, via EnrollScreen) — raw mic
///     audio with full noise processing.  [applyVad] = false (default).
///
///  2. **VoIP call monitoring** — mic is shared with WebRTC.  Pass
///     [applyVad] = true so each raw segment is filtered by [VadProcessor]
///     before [onSegmentReady] fires, extracting the remote-speaker windows.
///
/// For cellular call monitoring use [CallAudioRecorder] instead — it uses
/// Android's VOICE_RECOGNITION audio source (no AEC) which preserves more of
/// the earpiece bleed and therefore gives VAD much more to work with.
class AudioCaptureService extends ChangeNotifier {
  /// Number of consecutive skipped segments before [onCaptureIssue] fires.
  static const int _issueThreshold = 3;

  final AudioRecorder _recorder = AudioRecorder();
  bool _isRecording = false;
  bool _isDisposed = false;
  bool _applyVad = false;
  VadMode _vadMode = VadMode.remoteBleed;
  int _consecutiveSkips = 0;
  bool _issueReported = false;

  final List<String> _tempFiles = [];

  /// Fires with every ready segment (VAD-filtered if [applyVad] was set).
  /// The underlying WAV file is deleted automatically after this returns.
  Function(String filePath)? onSegmentReady;

  /// Fires (once) when several consecutive VAD passes are skipped — i.e. the
  /// mic isn't picking up usable remote-caller audio.  Use it to prompt the
  /// user to switch to speakerphone.  Only relevant when [applyVad] is true.
  Function(String reason)? onCaptureIssue;

  bool get isRecording => _isRecording;

  // ── Permission ─────────────────────────────────────────────────────────────

  Future<bool> hasPermission() async => _recorder.hasPermission();

  // ── Monitoring ─────────────────────────────────────────────────────────────

  /// Start the segment loop.
  ///
  /// [applyVad] — when true each segment is passed through [VadProcessor] to
  /// extract remote-speaker windows before [onSegmentReady] is called.  Use
  /// this for VoIP call monitoring so the AI sees the caller's voice rather
  /// than the phone owner's voice.
  Future<void> startMonitoring({
    int segmentSeconds = 5,
    bool applyVad = false,
    VadMode vadMode = VadMode.remoteBleed,
  }) async {
    if (_isDisposed || _isRecording) return;

    if (!await _recorder.hasPermission()) {
      debugPrint('AudioCapture: microphone permission denied');
      return;
    }

    _applyVad = applyVad;
    _vadMode = vadMode;
    _consecutiveSkips = 0;
    _issueReported = false;
    _isRecording = true;
    debugPrint('AudioCapture: START monitoring '
        '(${segmentSeconds}s segments, applyVad=$applyVad, vad=${vadMode.name})');
    _notifyIfActive();
    _loopFuture = _segmentLoop(segmentSeconds);
  }

  // ignore: unused_field
  Future<void>? _loopFuture;

  Future<void> _segmentLoop(int segmentSeconds) async {
    while (!_isDisposed && _isRecording) {
      final path = await _startNewSegment();
      if (path == null) {
        // Couldn't open the mic — usually it's held by another capturer
        // (e.g. WebRTC during a VoIP call). Surface it instead of freezing.
        if (_applyVad) _reportIssue('recorder_unavailable');
        break;
      }

      await Future.delayed(Duration(seconds: segmentSeconds));

      if (_isDisposed || !_isRecording) {
        await _stopRecorderSafely();
        _deleteFile(path);
        break;
      }

      final rawPath = await _stopRecorderSafely();
      if (rawPath == null) continue;

      // ── VAD post-processing (VoIP path) ──────────────────────────────
      if (_applyVad) {
        try {
          final rawLen = File(rawPath).lengthSync();
          debugPrint('AudioCapture: segment captured ($rawLen bytes)');
        } catch (_) {}

        final result = await VadProcessor.extract(rawPath, mode: _vadMode);
        _deleteFile(rawPath);

        if (!result.kept) {
          debugPrint('AudioCapture: skipped segment '
              '(${result.skipReason ?? 'no clean remote speech'})');
          _onSkip(result.skipReason ?? 'insufficient_speech');
          continue;
        }

        _consecutiveSkips = 0;
        final filteredPath = result.path!;
        _tempFiles.add(filteredPath);
        try {
          await onSegmentReady?.call(filteredPath);
        } finally {
          _deleteFile(filteredPath);
        }
        continue;
      }

      // ── Standard path (enrollment, no VAD) ───────────────────────────
      if (!_isDisposed && _isRecording) {
        try {
          await onSegmentReady?.call(rawPath);
        } finally {
          _deleteFile(rawPath);
        }
      } else {
        _deleteFile(rawPath);
      }
    }
  }

  Future<String?> _startNewSegment() async {
    if (_isDisposed || !_isRecording) return null;
    try {
      final dir = await getTemporaryDirectory();
      final ts = DateTime.now().millisecondsSinceEpoch;
      final path = '${dir.path}/vg_seg_$ts.wav';
      _tempFiles.add(path);

      await _recorder.start(
        const RecordConfig(
          encoder: AudioEncoder.wav,
          sampleRate: 16000,
          numChannels: 1,
          bitRate: 256000,
        ),
        path: path,
      );
      return path;
    } catch (e) {
      debugPrint('AudioCapture: segment start error: $e');
      return null;
    }
  }

  // ── Enrollment (single clip) ───────────────────────────────────────────────

  /// Record a single clean clip for manual enrollment (EnrollScreen).
  ///
  /// Uses the default noise-processed audio source — appropriate for a
  /// dedicated quiet recording session, NOT for use during an active call.
  Future<String?> recordSingleClip({int durationSeconds = 10}) async {
    if (_isDisposed) return null;
    if (!await _recorder.hasPermission()) return null;

    final dir = await getTemporaryDirectory();
    final path =
        '${dir.path}/vg_enroll_${DateTime.now().millisecondsSinceEpoch}.wav';
    _tempFiles.add(path);

    await _recorder.start(
      const RecordConfig(
        encoder: AudioEncoder.wav,
        sampleRate: 16000,
        numChannels: 1,
      ),
      path: path,
    );

    await Future.delayed(Duration(seconds: durationSeconds));
    if (_isDisposed) return null;
    return await _recorder.stop();
  }

  /// Delete a file previously created by this service (e.g. after enrollment).
  void deleteFile(String path) => _deleteFile(path);

  // ── Stop ──────────────────────────────────────────────────────────────────

  Future<void> stopMonitoring() async {
    if (_isDisposed) return;
    _isRecording = false;
    onSegmentReady = null;
    onCaptureIssue = null;

    await Future.delayed(const Duration(milliseconds: 150));
    if (await _recorder.isRecording()) await _stopRecorderSafely();

    await _deleteAllTempFiles();
    _notifyIfActive();
  }

  // ── Capture-issue tracking ─────────────────────────────────────────────────

  void _onSkip(String reason) {
    _consecutiveSkips++;
    if (_consecutiveSkips >= _issueThreshold) _reportIssue(reason);
  }

  void _reportIssue(String reason) {
    if (_issueReported) return;
    _issueReported = true;
    debugPrint('AudioCapture: capture issue → $reason');
    onCaptureIssue?.call(reason);
  }

  // ── File helpers ───────────────────────────────────────────────────────────

  void _deleteFile(String path) {
    _tempFiles.remove(path);
    try {
      final f = File(path);
      if (f.existsSync()) f.deleteSync();
    } catch (e) {
      debugPrint('AudioCapture: could not delete $path: $e');
    }
  }

  Future<void> _deleteAllTempFiles() async {
    for (final p in List<String>.from(_tempFiles)) {
      _deleteFile(p);
    }
  }

  void _notifyIfActive() {
    if (!_isDisposed) notifyListeners();
  }

  // ── Dispose ────────────────────────────────────────────────────────────────

  @override
  void dispose() {
    _isDisposed = true;
    _isRecording = false;
    onSegmentReady = null;
    onCaptureIssue = null;
    unawaited(_disposeRecorder());
    super.dispose();
  }

  Future<String?> _stopRecorderSafely() async {
    try {
      return await _recorder.stop();
    } catch (e) {
      debugPrint('AudioCapture: stop error: $e');
      return null;
    }
  }

  Future<void> _disposeRecorder() async {
    await _stopRecorderSafely();
    await _deleteAllTempFiles();
    await _recorder.dispose();
  }
}
