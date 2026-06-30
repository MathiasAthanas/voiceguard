import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:dio/dio.dart';
import '../constants/app_constants.dart';
import '../models/verification_result_model.dart';

class VerificationService extends ChangeNotifier {
  Dio _dio = _buildDio();
  static Dio _buildDio() => Dio(BaseOptions(
        baseUrl: AppConstants.aiBackendUrl,
        connectTimeout: const Duration(seconds: 10),
        receiveTimeout: const Duration(seconds: 45),
        // Prevent stale keep-alive connections — on Android the OS-level TCP
        // keep-alive can be closed server-side between the initial GET requests
        // (health/enroll-status) and the first verify POST during a call,
        // causing a DioExceptionType.connectionError with null message that
        // never reaches the backend. Connection: close ensures each request
        // opens a fresh TCP connection.
        headers: {'Connection': 'close'},
      ));

  VerificationResultModel _latestResult = VerificationResultModel.idle();
  bool _isVerifying = false;
  // Incremented by resetResult() so results from a previous call session are
  // discarded if they arrive after the next call has already started.
  int _sessionId = 0;

  // ── Rolling average window ─────────────────────────────────────────────────
  // We keep the last [_windowSize] non-trivial results and smooth the verdict.
  // This prevents a single noisy 5-second segment from flipping the display.
  static const int _windowSize = 3;
  // Both gates must pass before the smoothed verdict can say "verified".
  // Similarity guards against environment/acoustic false matches (the secondary
  // model can hit 90%+ on the wrong speaker). Confidence guards against the
  // backend's own threshold being too loose on noisy cellular audio.
  static const double _minSimilarityForVerified = 0.45;
  static const double _minConfidenceForVerified = 0.65;
  final List<VerificationResultModel> _resultWindow = [];

  // ── Sticky verdict (display only) ──────────────────────────────────────────
  // Once a confident Real/Not-real verdict is established, hold it on screen
  // through uncertain (cross-talk / noisy) patches instead of blanking to
  // "Checking". After more than one consecutive uncertain segment we also flag
  // [analysing] so the UI can show an "Analysing — multiple voices" sub-line:
  // the user sees we still know who they are, but we're re-checking the current
  // audio. Cleared on a new call. Does NOT affect detection or saved records.
  VerificationResultModel? _heldResult;
  int _uncertainStreak = 0;

  VerificationResultModel get latestResult => _latestResult;
  bool get isVerifying => _isVerifying;

  bool get _isUncertainNow =>
      _latestResult.verdict == VerificationVerdict.uncertain ||
      _latestResult.verdict == VerificationVerdict.secondaryWarning;

  /// What the overlay should show: the held verdict during uncertain patches,
  /// otherwise the live result (idle/Checking at call start, Real/Not real once
  /// committed).
  VerificationResultModel get displayResult =>
      (_isUncertainNow && _heldResult != null) ? _heldResult! : _latestResult;

  /// True while holding a verdict through a sustained (>1 segment) uncertain
  /// patch — the UI shows the "Analysing…" sub-line.
  bool get analysing =>
      _isUncertainNow && _heldResult != null && _uncertainStreak >= 2;

  void _notifySafely() {
    final phase = SchedulerBinding.instance.schedulerPhase;
    if (phase == SchedulerPhase.idle ||
        phase == SchedulerPhase.postFrameCallbacks) {
      notifyListeners();
      return;
    }
    SchedulerBinding.instance.addPostFrameCallback((_) {
      if (hasListeners) notifyListeners();
    });
  }

  void showCaptureIssue(String message) {
    _latestResult = VerificationResultModel(
      contactId: '',
      verdict: VerificationVerdict.uncertain,
      confidence: 0,
      spoofProbability: 0,
      isVerified: false,
      isSpoof: false,
      label: 'Audio not clear yet',
      message: message,
      timestamp: DateTime.now(),
    );
    _notifySafely();
  }

  void applyRemoteResult(Map<String, dynamic> json) {
    final result = VerificationResultModel.fromJson(json);
    _latestResult = result;
    _notifySafely();
  }

  // ── Enroll ─────────────────────────────────────────────────────────────────

  Future<bool> enrollContact({
    required String contactId,
    required List<String> audioPaths,

    /// 'high' = clean EnrollScreen recording
    /// 'low'  = VAD-extracted call audio
    String sourceQuality = 'high',
  }) async {
    _refreshDioIfNeeded();
    try {
      final formData = FormData();
      formData.fields.add(MapEntry('contact_id', contactId));
      formData.fields.add(MapEntry('source_quality', sourceQuality));
      for (final path in audioPaths) {
        formData.files.add(MapEntry(
          'audio_files',
          await MultipartFile.fromFile(path,
              filename: '${contactId}_sample.wav'),
        ));
      }
      final response = await _dio.post('/enroll/', data: formData);
      return response.statusCode == 200 && (response.data['success'] == true);
    } catch (e) {
      debugPrint('Enrollment error: $e');
      return false;
    }
  }

  // ── Verify ─────────────────────────────────────────────────────────────────

  Future<VerificationResultModel?> verifyAudioFile({
    required String contactId,
    required String audioFilePath,

    /// 'high' = manual enrollment / clean recording
    /// 'low'  = VAD-extracted call audio (earpiece bleed, lower SNR)
    String sourceQuality = 'high',
    String audioRole = 'remote_speaker',
    String mediaSource = 'unknown',
  }) async {
    final sessionAtStart = _sessionId;
    final raw = await verifyAudioFileRaw(
      contactId: contactId,
      audioFilePath: audioFilePath,
      sourceQuality: sourceQuality,
      audioRole: audioRole,
      mediaSource: mediaSource,
    );
    // Discard result if a new call started (resetResult was called) while
    // the HTTP request was in-flight — prevents stale results bleeding into
    // the next call's verification overlay.
    if (raw == null || _sessionId != sessionAtStart) return null;
    _pushToWindow(raw);
    return _latestResult;
  }

  Future<VerificationResultModel?> verifyAudioFileRaw({
    required String contactId,
    required String audioFilePath,
    String sourceQuality = 'high',
    String audioRole = 'remote_speaker',
    String mediaSource = 'unknown',
    bool updateUi = true,
  }) async {
    _refreshDioIfNeeded();

    final sessionAtStart = _sessionId;

    _isVerifying = true;
    if (updateUi) {
      _latestResult = VerificationResultModel.analyzing();
      _notifySafely();
    }

    try {
      final formData = FormData.fromMap({
        'contact_id': contactId,
        'audio_file': await MultipartFile.fromFile(audioFilePath,
            filename: 'segment.wav'),
        'source_quality': sourceQuality,
        'audio_role': audioRole,
        'media_source': mediaSource,
      });

      final response = await _dio.post('/verify/', data: formData);

      if (_sessionId != sessionAtStart) return null;

      if (response.statusCode == 200) {
        return VerificationResultModel.fromJson(
            Map<String, dynamic>.from(response.data));
      }
    } on DioException catch (e) {
      if (_sessionId != sessionAtStart) return null;
      if (e.response?.statusCode == 404) {
        final notEnrolled = VerificationResultModel.notEnrolled(contactId);
        if (updateUi) {
          _latestResult = notEnrolled;
        }
        return notEnrolled;
      } else {
        debugPrint('Verification error [${e.type}]: ${e.message ?? e.error}');
        if (updateUi) {
          _latestResult =
              VerificationResultModel.error('AI backend did not respond in time');
        }
      }
    } catch (e) {
      if (_sessionId != sessionAtStart) return null;
      debugPrint('Verification error: $e');
      if (updateUi) {
        _latestResult = VerificationResultModel.error('Verification failed');
      }
    } finally {
      _isVerifying = false;
      if (updateUi && _sessionId == sessionAtStart) _notifySafely();
    }

    return null;
  }

  // ── Rolling average ────────────────────────────────────────────────────────

  /// Add [result] to the sliding window and recompute [_latestResult].
  void _pushToWindow(VerificationResultModel result) {
    // Ignore transient states — they don't carry meaningful signal.
    if (result.verdict == VerificationVerdict.silent ||
        result.verdict == VerificationVerdict.idle ||
        result.verdict == VerificationVerdict.analyzing) {
      _latestResult = result;
      return;
    }

    _resultWindow.add(result);
    if (_resultWindow.length > _windowSize) _resultWindow.removeAt(0);

    _latestResult = _smoothedResult(result);

    // Sticky verdict bookkeeping: remember the last confident verdict; count
    // consecutive uncertain segments since then (for the "Analysing" sub-line).
    switch (_latestResult.verdict) {
      case VerificationVerdict.verified:
      case VerificationVerdict.verifiedHigh:
      case VerificationVerdict.notVerified:
        _heldResult = _latestResult;
        _uncertainStreak = 0;
        break;
      case VerificationVerdict.uncertain:
      case VerificationVerdict.secondaryWarning:
        _uncertainStreak++;
        break;
      default:
        break;
    }
  }

  VerificationResultModel _smoothedResult(VerificationResultModel latest) {
    if (_resultWindow.isEmpty) return latest;

    // ── Average numeric scores ─────────────────────────────────────────────
    final avgConfidence =
        _resultWindow.map((r) => r.confidence).reduce((a, b) => a + b) /
            _resultWindow.length;

    final scoreItems =
        _resultWindow.where((r) => r.similarityScore != null).toList();
    final avgSimilarity = scoreItems.isEmpty
        ? latest.similarityScore
        : scoreItems.map((r) => r.similarityScore!).reduce((a, b) => a + b) /
            scoreItems.length;

    // Presentational confidence (backend-computed, threshold-anchored) — smooth
    // it the same way so the displayed % tracks the windowed result.
    final displayItems =
        _resultWindow.where((r) => r.displayConfidence != null).toList();
    final avgDisplay = displayItems.isEmpty
        ? latest.displayConfidence
        : displayItems.map((r) => r.displayConfidence!).reduce((a, b) => a + b) /
            displayItems.length;

    // ── Majority-vote verdict ──────────────────────────────────────────────
    // A categorical spoof alert requires repeated evidence. The current
    // anti-spoofing model is useful as a risk signal but has a meaningful
    // false-positive rate on legitimate voices.
    // Demo/test build: anti-spoofing is kept as a risk score from the backend,
    // but it no longer overrides speaker verification in the live call UI.
    // The trained spoof model currently false-flags too many real callers.

    // For other verdicts, require a majority (>50 %) before committing.
    final counts = <VerificationVerdict, int>{};
    for (final r in _resultWindow) {
      counts[r.verdict] = (counts[r.verdict] ?? 0) + 1;
    }
    final topEntry =
        counts.entries.reduce((a, b) => a.value >= b.value ? a : b);
    final majority = topEntry.value > _resultWindow.length / 2;
    var smoothedVerdict =
        majority ? topEntry.key : VerificationVerdict.uncertain;

    // Both gates must pass to report verified. Either being too low downgrades
    // to uncertain — primary similarity catches acoustic environment matches,
    // confidence catches cases where the backend's own threshold is too loose.
    if (smoothedVerdict == VerificationVerdict.verified ||
        smoothedVerdict == VerificationVerdict.verifiedHigh) {
      final simTooLow = avgSimilarity != null && avgSimilarity < _minSimilarityForVerified;
      final confTooLow = avgConfidence < _minConfidenceForVerified;
      if (simTooLow || confTooLow) {
        smoothedVerdict = VerificationVerdict.uncertain;
      }
    }

    return _withSmoothed(latest,
        verdict: smoothedVerdict,
        confidence: avgConfidence,
        similarity: avgSimilarity,
        display: avgDisplay,
        isVerified: smoothedVerdict == VerificationVerdict.verified ||
            smoothedVerdict == VerificationVerdict.verifiedHigh,
        isSpoof: false);
  }

  VerificationResultModel _withSmoothed(
    VerificationResultModel base, {
    required VerificationVerdict verdict,
    required double confidence,
    double? similarity,
    double? display,
    required bool isVerified,
    required bool isSpoof,
  }) {
    final label = switch (verdict) {
      VerificationVerdict.spoofDetected => 'Cloned voice detected',
      VerificationVerdict.spoofSuspected => 'Possible cloned voice',
      _ => base.label,
    };
    final message = switch (verdict) {
      VerificationVerdict.spoofDetected =>
        'Repeated anti-spoofing evidence indicates a cloned voice',
      VerificationVerdict.spoofSuspected =>
        'Possible cloned voice - gathering more evidence',
      _ => base.message,
    };

    return VerificationResultModel(
      contactId: base.contactId,
      verdict: verdict,
      confidence: confidence,
      similarityScore: similarity,
      displayConfidence: display,
      spoofProbability: base.spoofProbability,
      isVerified: isVerified,
      isSpoof: isSpoof,
      label: label,
      message: message,
      timestamp: base.timestamp,
      segmentsAnalyzed:
          _resultWindow.fold(0, (sum, r) => sum + r.segmentsAnalyzed),
      secondarySimilarityScore: base.secondarySimilarityScore,
      secondaryAvailable: base.secondaryAvailable,
      secondaryMatched: base.secondaryMatched,
      audioRole: base.audioRole,
      mediaSource: base.mediaSource,
    );
  }

  // ── Status / delete ────────────────────────────────────────────────────────

  Future<bool> isEnrolled(String contactId) async {
    _refreshDioIfNeeded();
    try {
      final response = await _dio.get('/enroll/status/$contactId');
      return response.data['is_enrolled'] == true;
    } catch (e) {
      // Network error: assume enrolled to avoid overwriting an existing
      // voiceprint on a transient connectivity failure. A false-negative here
      // (wrongly triggering auto-enrollment for an unenrolled contact) would
      // silently capture the wrong speaker's voice as the enrolled identity —
      // a much worse outcome than skipping enrollment on a bad connection.
      return true;
    }
  }

  Future<bool> deleteVoiceprint(String contactId) async {
    _refreshDioIfNeeded();
    try {
      final response = await _dio.delete('/enroll/$contactId');
      return response.statusCode == 200;
    } catch (e) {
      return false;
    }
  }

  Future<bool> isBackendReachable() async {
    try {
      // Refresh URL before health check
      _dio = _buildDio();
      final response = await _dio.get('/health/');
      return response.statusCode == 200;
    } catch (e) {
      return false;
    }
  }

  void resetResult() {
    _sessionId++;
    _resultWindow.clear();
    _heldResult = null;
    _uncertainStreak = 0;
    _latestResult = VerificationResultModel.idle();
    _isVerifying = false;
    _notifySafely();
  }

  void _refreshDioIfNeeded() {
    if (_dio.options.baseUrl != AppConstants.aiBackendUrl) {
      _dio = _buildDio();
    }
  }
}
