import 'package:flutter_test/flutter_test.dart';
import 'package:voiceguard/core/models/verification_result_model.dart';

/// Unit tests for the rolling-average logic inside VerificationService.
///
/// Because VerificationService talks to a live HTTP backend, we extract the
/// logic we want to test into pure functions and test those directly.
/// Integration tests (real HTTP) belong in test/integration/.

// ── Helper: build a synthetic result ────────────────────────────────────────

VerificationResultModel _makeResult({
  required VerificationVerdict verdict,
  required double confidence,
  double similarity = 0.0,
}) {
  return VerificationResultModel(
    contactId: 'test_contact',
    verdict: verdict,
    confidence: confidence,
    similarityScore: similarity,
    spoofProbability: 0.0,
    isVerified: verdict == VerificationVerdict.verified ||
        verdict == VerificationVerdict.verifiedHigh,
    isSpoof: verdict == VerificationVerdict.spoofDetected,
    label: verdict.name,
    message: verdict.name,
    timestamp: DateTime.now(),
    segmentsAnalyzed: 1,
  );
}

// ── Simulated rolling-average logic (mirrors VerificationService._smoothedResult)

const _windowSize = 3;

VerificationResultModel smoothedResult(
  List<VerificationResultModel> window,
  VerificationResultModel latest,
) {
  if (window.isEmpty) return latest;

  final avgConfidence = window.map((r) => r.confidence).reduce((a, b) => a + b) / window.length;
  final simItems = window.where((r) => r.similarityScore != null).toList();
  final avgSim = simItems.isEmpty
      ? latest.similarityScore
      : simItems.map((r) => r.similarityScore!).reduce((a, b) => a + b) / simItems.length;

  // A definitive spoof result always wins.
  if (window.any((r) => r.verdict == VerificationVerdict.spoofDetected)) {
    return VerificationResultModel(
      contactId: latest.contactId,
      verdict: VerificationVerdict.spoofDetected,
      confidence: avgConfidence,
      similarityScore: avgSim,
      spoofProbability: latest.spoofProbability,
      isVerified: false,
      isSpoof: true,
      label: latest.label,
      message: latest.message,
      timestamp: latest.timestamp,
      segmentsAnalyzed: window.fold(0, (s, r) => s + r.segmentsAnalyzed),
    );
  }

  final suspectedCount =
      window.where((r) => r.verdict == VerificationVerdict.spoofSuspected).length;
  if (window.length >= _windowSize && suspectedCount == _windowSize) {
    return VerificationResultModel(
      contactId: latest.contactId,
      verdict: VerificationVerdict.spoofDetected,
      confidence: avgConfidence,
      similarityScore: avgSim,
      spoofProbability: latest.spoofProbability,
      isVerified: false,
      isSpoof: true,
      label: 'Cloned voice detected',
      message: 'Repeated anti-spoofing evidence indicates a cloned voice',
      timestamp: latest.timestamp,
      segmentsAnalyzed: window.fold(0, (s, r) => s + r.segmentsAnalyzed),
    );
  }
  if (suspectedCount > 0) {
    return VerificationResultModel(
      contactId: latest.contactId,
      verdict: VerificationVerdict.spoofSuspected,
      confidence: avgConfidence,
      similarityScore: avgSim,
      spoofProbability: latest.spoofProbability,
      isVerified: false,
      isSpoof: false,
      label: 'Possible cloned voice',
      message: 'Possible cloned voice - gathering more evidence',
      timestamp: latest.timestamp,
      segmentsAnalyzed: window.fold(0, (s, r) => s + r.segmentsAnalyzed),
    );
  }

  final counts = <VerificationVerdict, int>{};
  for (final r in window) counts[r.verdict] = (counts[r.verdict] ?? 0) + 1;
  final top = counts.entries.reduce((a, b) => a.value >= b.value ? a : b);
  final majority = top.value > window.length / 2;
  final smoothedVerdict = majority ? top.key : VerificationVerdict.uncertain;

  return VerificationResultModel(
    contactId: latest.contactId,
    verdict: smoothedVerdict,
    confidence: avgConfidence,
    similarityScore: avgSim,
    spoofProbability: latest.spoofProbability,
    isVerified: smoothedVerdict == VerificationVerdict.verified ||
        smoothedVerdict == VerificationVerdict.verifiedHigh,
    isSpoof: false,
    label: latest.label,
    message: latest.message,
    timestamp: latest.timestamp,
    segmentsAnalyzed: window.fold(0, (s, r) => s + r.segmentsAnalyzed),
  );
}

// ── Tests ────────────────────────────────────────────────────────────────────

void main() {
  group('Rolling verification average', () {
    test('single result passes through unchanged', () {
      final r = _makeResult(verdict: VerificationVerdict.verified, confidence: 0.8);
      final window = [r];
      final out = smoothedResult(window, r);

      expect(out.verdict, VerificationVerdict.verified);
      expect(out.confidence, closeTo(0.8, 0.001));
    });

    test('averages confidence over window', () {
      final results = [
        _makeResult(verdict: VerificationVerdict.verified, confidence: 0.6),
        _makeResult(verdict: VerificationVerdict.verified, confidence: 0.8),
        _makeResult(verdict: VerificationVerdict.verified, confidence: 0.7),
      ];
      final out = smoothedResult(results, results.last);

      expect(out.confidence, closeTo(0.7, 0.001));
    });

    test('majority vote: 2 verified + 1 not_verified → verified', () {
      final window = [
        _makeResult(verdict: VerificationVerdict.verified,    confidence: 0.7),
        _makeResult(verdict: VerificationVerdict.verified,    confidence: 0.65),
        _makeResult(verdict: VerificationVerdict.notVerified, confidence: 0.3),
      ];
      final out = smoothedResult(window, window.last);
      expect(out.verdict, VerificationVerdict.verified);
    });

    test('no majority → uncertain', () {
      final window = [
        _makeResult(verdict: VerificationVerdict.verified,    confidence: 0.65),
        _makeResult(verdict: VerificationVerdict.notVerified, confidence: 0.35),
      ];
      final out = smoothedResult(window, window.last);
      // Tied (1:1) → uncertain
      expect(out.verdict, VerificationVerdict.uncertain);
    });

    test('single spoof result triggers spoof verdict regardless of others', () {
      final window = [
        _makeResult(verdict: VerificationVerdict.verified,      confidence: 0.75),
        _makeResult(verdict: VerificationVerdict.verified,      confidence: 0.80),
        _makeResult(verdict: VerificationVerdict.spoofDetected, confidence: 0.92),
      ];
      final out = smoothedResult(window, window.last);
      expect(out.verdict, VerificationVerdict.spoofDetected);
      expect(out.isSpoof, isTrue);
      expect(out.isVerified, isFalse);
    });

    test('one suspected result remains a warning, not a spoof verdict', () {
      final window = [
        _makeResult(verdict: VerificationVerdict.verified, confidence: 0.75),
        _makeResult(verdict: VerificationVerdict.spoofSuspected, confidence: 0.80),
      ];
      final out = smoothedResult(window, window.last);
      expect(out.verdict, VerificationVerdict.spoofSuspected);
      expect(out.isSpoof, isFalse);
      expect(out.label, 'Possible cloned voice');
    });

    test('three consecutive suspected results escalate to spoof detected', () {
      final window = [
        _makeResult(verdict: VerificationVerdict.spoofSuspected, confidence: 0.80),
        _makeResult(verdict: VerificationVerdict.spoofSuspected, confidence: 0.85),
        _makeResult(verdict: VerificationVerdict.spoofSuspected, confidence: 0.90),
      ];
      final out = smoothedResult(window, window.last);
      expect(out.verdict, VerificationVerdict.spoofDetected);
      expect(out.isSpoof, isTrue);
      expect(out.label, 'Cloned voice detected');
    });

    test('full window counts segments correctly', () {
      final window = [
        _makeResult(verdict: VerificationVerdict.verified, confidence: 0.7),
        _makeResult(verdict: VerificationVerdict.verified, confidence: 0.7),
        _makeResult(verdict: VerificationVerdict.verified, confidence: 0.7),
      ];
      final out = smoothedResult(window, window.last);
      expect(out.segmentsAnalyzed, 3);
    });
  });

  group('VerificationResultModel factories', () {
    test('idle() has idle verdict', () {
      final idle = VerificationResultModel.idle();
      expect(idle.verdict, VerificationVerdict.idle);
      expect(idle.isVerified, isFalse);
    });

    test('analyzing() has analyzing verdict', () {
      final analyzing = VerificationResultModel.analyzing();
      expect(analyzing.verdict, VerificationVerdict.analyzing);
    });

    test('notEnrolled() references contactId', () {
      final r = VerificationResultModel.notEnrolled('alice');
      expect(r.contactId, 'alice');
      expect(r.verdict, VerificationVerdict.notEnrolled);
    });

    test('fromJson maps verified_high correctly', () {
      final json = {
        'verdict': 'verified_high',
        'confidence': 0.91,
        'similarity_score': 0.82,
        'spoof_probability': 0.0,
        'is_verified': true,
        'is_spoof': false,
        'label': 'Verified',
        'message': 'Verified',
        'contact_id': 'bob',
        'segments_analyzed': 2,
      };
      final r = VerificationResultModel.fromJson(json);
      expect(r.verdict, VerificationVerdict.verifiedHigh);
      expect(r.isVerified, isTrue);
      expect(r.confidence, closeTo(0.91, 0.001));
    });

    test('fromJson maps spoof_suspected as a non-definitive warning', () {
      final r = VerificationResultModel.fromJson({
        'verdict': 'spoof_suspected',
        'confidence': 0.71,
        'spoof_probability': 0.92,
        'is_verified': false,
        'is_spoof': false,
        'label': 'Possible cloned voice',
        'message': 'Gathering more evidence',
        'contact_id': 'bob',
        'segments_analyzed': 1,
      });
      expect(r.verdict, VerificationVerdict.spoofSuspected);
      expect(r.isSpoof, isFalse);
    });

    test('fromJson handles unknown verdict gracefully', () {
      final json = {
        'verdict': 'totally_unknown_verdict',
        'confidence': 0.5,
        'spoof_probability': 0.0,
        'is_verified': false,
        'is_spoof': false,
        'label': '?',
        'message': '?',
        'contact_id': 'x',
        'segments_analyzed': 1,
      };
      final r = VerificationResultModel.fromJson(json);
      expect(r.verdict, VerificationVerdict.uncertain);
    });
  });
}
