import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';

/// How [VadProcessor] decides which frames to keep.
enum VadMode {
  /// **Verification (held-to-ear cellular).**  The remote caller is the *quiet*
  /// earpiece bleed; the loud frames are the phone owner.  Keep the frames
  /// BELOW the adaptive threshold (local user silent → remote leaking through).
  remoteBleed,

  /// **Enrollment / speakerphone.**  Act as a true voice-activity detector:
  /// keep every VOICED frame (above the silence floor) and drop pure silence.
  /// On speakerphone the remote caller is loud, so "low-energy = remote" is
  /// wrong — we just want clean speech to build the profile from.
  speech,
}

/// Result of a VAD pass — either a written WAV path, or a [skipReason]
/// explaining why nothing usable was produced (for diagnostics / UX).
class VadResult {
  final String? path;
  final String? skipReason;
  const VadResult.kept(this.path) : skipReason = null;
  const VadResult.skipped(this.skipReason) : path = null;
  bool get kept => path != null;
}

/// Voice Activity Detection — extracts usable speech windows from a raw
/// microphone recording made during a phone call.
///
/// ── Why this exists ───────────────────────────────────────────────────────
/// During any phone call the microphone captures two things:
///   1. User B (phone owner) speaking directly into the mic  →  HIGH energy
///   2. User A (caller) leaking from the earpiece/speaker
///
/// In [VadMode.remoteBleed] (held-to-ear verification) the caller is the LOW
/// energy bleed, so we keep the quiet windows.  In [VadMode.speech]
/// (enrollment, usually on speakerphone) the caller is loud, so we keep every
/// voiced frame and drop silence.
///
/// ── Platform reality ──────────────────────────────────────────────────────
/// Android does NOT let a normal app record the downlink of a cellular call,
/// and in earpiece mode the acoustic bleed of the remote caller is extremely
/// faint.  Reliable call-time capture of the caller therefore requires
/// SPEAKERPHONE.  The recorders surface this to the UI when capture keeps
/// failing.
class VadProcessor {
  // ── Tuneable parameters (remoteBleed / earpiece verification) ───────────

  /// Frames below (peak × _silenceRatio) are kept as remote-speaker bleed.
  static const double _silenceRatio = 0.12;

  /// Absolute RMS floor for the remoteBleed "quiet" threshold.
  static const double _absoluteFloor = 700.0;

  /// Minimum peak for earpiece bleed — if quieter, the recording is silence.
  static const double _minPeak = 180.0;

  // ── Tuneable parameters (speech / speakerphone enrollment) ───────────────

  /// Minimum peak for speakerphone enrollment — the mic sees WebRTC-compressed
  /// audio which is naturally quieter than a clean recording. 80 still rejects
  /// DC-offset / pure noise while allowing realistic caller levels.
  static const double _speechMinPeak = 80.0;

  /// Absolute RMS floor for voiced frames in speech mode. Lowered from 320 to
  /// 150 because WebRTC AEC reduces the caller's level significantly; raising
  /// _voicedRatio to 0.25 compensates by being more selective relative to peak.
  static const double _speechVoicedFloor = 150.0;

  /// Fraction of peak RMS that counts as "voiced" in speech mode. Higher ratio
  /// (0.25 vs 0.18) keeps only the louder frames — speech not background hiss.
  static const double _speechVoicedRatio = 0.25;

  /// A contiguous kept run must be at least this long.
  static const int _minSegMs = 200;

  /// Minimum total kept audio before the result is considered useful.
  ///
  /// Kept ≥ the backend's call-time minimum duration (1.2 s, see
  /// enrollment_service.py) so any segment that passes VAD is also long enough
  /// for the backend to accept — otherwise the counter would advance only for
  /// the backend to reject every sample as `too_short`.
  static const int _minTotalMs = 1300;

  // ── Internal constants ───────────────────────────────────────────────────

  static const int _sampleRate = 16000;
  static const int _frameMs = 200;
  static const int _frameSamples = _sampleRate * _frameMs ~/ 1000; // 3 200
  static const int _wavHeader = 44;

  // ── Public API ───────────────────────────────────────────────────────────

  /// Backwards-compatible helper — returns just the path (or null).
  static Future<String?> extractRemoteSpeakerAudio(
    String wavPath, {
    VadMode mode = VadMode.remoteBleed,
  }) async {
    final r = await extract(wavPath, mode: mode);
    return r.path;
  }

  /// Extract usable speech windows from [wavPath] using [mode].
  ///
  /// Runs in a separate isolate so it never janks the UI.  Returns a
  /// [VadResult] carrying either the filtered WAV path or a skip reason.
  static Future<VadResult> extract(
    String wavPath, {
    VadMode mode = VadMode.remoteBleed,
  }) async {
    try {
      return await compute(_processWavEntryPoint, <String, dynamic>{
        'path': wavPath,
        'mode': mode.index,
      });
    } catch (e) {
      debugPrint('VadProcessor: error processing $wavPath: $e');
      return const VadResult.skipped('processing_error');
    }
  }

  // ── Isolate worker ────────────────────────────────────────────────────────

  static Future<VadResult> _processWavEntryPoint(
      Map<String, dynamic> args) async {
    final wavPath = args['path'] as String;
    final mode = VadMode.values[args['mode'] as int];
    return _processWav(wavPath, mode);
  }

  static Future<VadResult> _processWav(String wavPath, VadMode mode) async {
    final tag = 'VAD[${mode.name}]';
    final file = File(wavPath);
    if (!file.existsSync()) {
      debugPrint('$tag: source file missing → skip');
      return const VadResult.skipped('capture_missing');
    }

    final bytes = await file.readAsBytes();
    if (bytes.length <= _wavHeader) {
      debugPrint('$tag: empty capture (${bytes.length} bytes) → skip');
      return const VadResult.skipped('empty_capture');
    }

    // ── Parse PCM (16-bit signed little-endian, mono) ─────────────────────
    final pcm = bytes.buffer.asInt16List(_wavHeader);
    if (pcm.isEmpty) {
      debugPrint('$tag: no PCM samples → skip');
      return const VadResult.skipped('empty_capture');
    }

    final frameCount = pcm.length ~/ _frameSamples;
    if (frameCount < 2) {
      debugPrint('$tag: clip too short ($frameCount frames) → skip');
      return const VadResult.skipped('too_short');
    }

    // ── Per-frame RMS ─────────────────────────────────────────────────────
    final rms = List<double>.filled(frameCount, 0.0);
    double peak = 0.0;

    for (int f = 0; f < frameCount; f++) {
      final start = f * _frameSamples;
      final end = min(start + _frameSamples, pcm.length);
      double sq = 0.0;
      for (int i = start; i < end; i++) sq += pcm[i].toDouble() * pcm[i];
      final v = sqrt(sq / (end - start));
      rms[f] = v;
      if (v > peak) peak = v;
    }

    // ── Dead-capture guard ────────────────────────────────────────────────
    // peak == 0.0 exactly means ALL PCM samples are zero — the OS is silencing
    // the mic at the HAL level (Pixel 6 / Android 12+ during MODE_IN_CALL).
    // No source or retry will help; surface a distinct reason so callers can
    // stop immediately without wasting time on fallback sources.
    if (peak == 0.0) {
      debugPrint('$tag: hardware muted (all PCM samples zero) → skip');
      return const VadResult.skipped('hardware_muted');
    }
    // speech mode uses a lower threshold because WebRTC AEC suppresses the
    // caller's level; earpiece bleed (remoteBleed) needs more signal to be
    // distinguishable from noise.
    final effectiveMinPeak =
        mode == VadMode.speech ? _speechMinPeak : _minPeak;
    if (peak < effectiveMinPeak) {
      debugPrint('$tag: silent capture (peak ${peak.toStringAsFixed(0)} '
          '< $effectiveMinPeak) → skip');
      return const VadResult.skipped('silent_capture');
    }

    // ── Classify frames per mode ──────────────────────────────────────────
    late final List<bool> keep;
    if (mode == VadMode.remoteBleed) {
      final threshold = max(peak * _silenceRatio, _absoluteFloor);
      keep = List<bool>.generate(frameCount, (f) => rms[f] < threshold);
    } else {
      // speech / speakerphone enrollment: use mode-specific thresholds so that
      // WebRTC-compressed caller audio (typically 150–700 RMS peak) passes.
      final threshold = max(peak * _speechVoicedRatio, _speechVoicedFloor);
      keep = List<bool>.generate(frameCount, (f) => rms[f] >= threshold);
    }

    // ── Group into segments ───────────────────────────────────────────────
    final minFrames = (_minSegMs / _frameMs).ceil();
    final segs = <(int, int)>[]; // (startFrame inclusive, endFrame inclusive)
    int? runStart;

    for (int f = 0; f <= frameCount; f++) {
      final k = f < frameCount && keep[f];
      if (k && runStart == null) {
        runStart = f;
      } else if (!k && runStart != null) {
        final start = runStart;
        if (f - start >= minFrames) segs.add((start, f - 1));
        runStart = null;
      }
    }

    // ── Minimum-total check ───────────────────────────────────────────────
    final totalFrames = segs.fold(0, (s, e) => s + (e.$2 - e.$1 + 1));
    final totalMs = totalFrames * _frameMs;
    if (totalMs < _minTotalMs) {
      debugPrint('$tag: only $totalMs ms kept (peak ${peak.toStringAsFixed(0)}, '
          '$frameCount frames) → skip');
      return const VadResult.skipped('insufficient_speech');
    }

    // ── Build output PCM ──────────────────────────────────────────────────
    final outLen = totalFrames * _frameSamples;
    final outSamples = Int16List(outLen);
    int outOff = 0;

    for (final seg in segs) {
      for (int f = seg.$1; f <= seg.$2; f++) {
        final start = f * _frameSamples;
        final end = min(start + _frameSamples, pcm.length);
        final len = end - start;
        outSamples.setRange(outOff, outOff + len, pcm, start);
        outOff += len;
      }
    }

    // ── Write WAV ─────────────────────────────────────────────────────────
    // Derive the output path from the input file's directory so we avoid
    // calling getTemporaryDirectory() (a MethodChannel) from inside the
    // compute() isolate — that would throw BackgroundIsolateBinaryMessenger.
    final outPath =
        '${File(wavPath).parent.path}/vg_remote_${DateTime.now().millisecondsSinceEpoch}.wav';
    await File(outPath).writeAsBytes(_buildWav(outSamples));

    final pct = (100 * outSamples.length / pcm.length).round();
    debugPrint('$tag: kept $pct% ($totalMs ms / ${pcm.length ~/ _sampleRate}s, '
        'peak ${peak.toStringAsFixed(0)})');
    return VadResult.kept(outPath);
  }

  // ── WAV builder ───────────────────────────────────────────────────────────

  static Uint8List _buildWav(Int16List pcm) {
    final dataBytes = pcm.length * 2;
    final buf = ByteData(_wavHeader + dataBytes);

    // RIFF
    _ascii(buf, 0, 'RIFF');
    buf.setInt32(4, buf.lengthInBytes - 8, Endian.little);
    _ascii(buf, 8, 'WAVE');
    // fmt
    _ascii(buf, 12, 'fmt ');
    buf.setInt32(16, 16, Endian.little); // chunk size
    buf.setInt16(20, 1, Endian.little); // PCM
    buf.setInt16(22, 1, Endian.little); // mono
    buf.setInt32(24, _sampleRate, Endian.little);
    buf.setInt32(28, _sampleRate * 2, Endian.little); // byte rate
    buf.setInt16(32, 2, Endian.little); // block align
    buf.setInt16(34, 16, Endian.little); // bits per sample
    // data
    _ascii(buf, 36, 'data');
    buf.setInt32(40, dataBytes, Endian.little);

    for (int i = 0; i < pcm.length; i++) {
      buf.setInt16(_wavHeader + i * 2, pcm[i], Endian.little);
    }
    return buf.buffer.asUint8List();
  }

  static void _ascii(ByteData b, int off, String s) {
    for (int i = 0; i < s.length; i++) b.setUint8(off + i, s.codeUnitAt(i));
  }
}
