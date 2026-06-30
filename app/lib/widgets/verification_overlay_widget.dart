import 'package:flutter/material.dart';
import '../core/constants/app_colors.dart';
import '../core/models/verification_result_model.dart';
import '../core/services/verification_service.dart';

/// Live in-call verdict card. Presents the robust per-segment result as one of
/// two committed flags — **Real speaker** (green) / **Not real speaker** (red) —
/// or a neutral **Checking…** state before the first verdict.
///
/// Sticky behaviour (via [VerificationService.displayResult]): once a verdict is
/// committed, it's HELD through uncertain/noisy patches instead of blanking to
/// Checking. During a sustained ambiguous patch ([VerificationService.analysing])
/// a small "Analysing — multiple voices" sub-line appears under the held verdict,
/// so the user sees we still know who they are but are re-checking the audio.
class VerificationOverlayWidget extends StatelessWidget {
  final VerificationService service;

  const VerificationOverlayWidget({super.key, required this.service});

  @override
  Widget build(BuildContext context) {
    final result = service.displayResult;
    final analysing = service.analysing;

    final bool real = result.verdict == VerificationVerdict.verified ||
        result.verdict == VerificationVerdict.verifiedHigh;
    final bool notReal = result.verdict == VerificationVerdict.notVerified ||
        result.verdict == VerificationVerdict.spoofDetected;
    final bool subtle = !real && !notReal;
    final Color accent =
        real ? AppColors.verified : (notReal ? AppColors.danger : Colors.white54);

    return AnimatedContainer(
      duration: const Duration(milliseconds: 400),
      curve: Curves.easeInOut,
      width: double.infinity,
      padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 18),
      decoration: BoxDecoration(
        color: subtle
            ? Colors.white.withValues(alpha: 0.04)
            : accent.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(
          color: subtle ? Colors.white12 : accent.withValues(alpha: 0.35),
          width: 1.2,
        ),
      ),
      child: _content(result, real, notReal, accent, analysing),
    );
  }

  Widget _content(VerificationResultModel result, bool real, bool notReal,
      Color accent, bool analysing) {
    if (result.verdict == VerificationVerdict.notEnrolled) {
      return _centered(
          Icons.mic_off_rounded, 'Contact not enrolled', Colors.white38);
    }
    if (real) {
      return _verdictRow(
          result, Icons.verified_user_rounded, 'Real speaker', accent, analysing);
    }
    if (notReal) {
      return _verdictRow(
          result, Icons.gpp_bad_rounded, 'Not real speaker', accent, analysing);
    }
    // No committed verdict yet (start of call) — gathering audio.
    return _buildSpinner('Checking caller…');
  }

  // ── Committed verdict (optionally with the "Analysing" sub-line) ─────────────

  Widget _verdictRow(VerificationResultModel result, IconData icon, String title,
      Color color, bool analysing) {
    // Threshold-anchored display confidence (falls back to raw similarity);
    // always agrees with the flag and reads sensibly regardless of model scale.
    final double? shown = result.displayConfidence ?? result.similarityScore;
    final bool showBar = shown != null;
    final int percent = shown == null ? 0 : (shown * 100).round();

    return Row(
      children: [
        _iconCircle(icon, color),
        const SizedBox(width: 14),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                style: TextStyle(
                  color: color,
                  fontSize: 16,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 0.1,
                ),
              ),
              // Re-checking signal during a sustained ambiguous (cross-talk)
              // patch — verdict is held, we're working the current audio.
              if (analysing) ...[
                const SizedBox(height: 4),
                Row(
                  children: [
                    SizedBox(
                      width: 11,
                      height: 11,
                      child: CircularProgressIndicator(
                        strokeWidth: 1.6,
                        color: color.withValues(alpha: 0.8),
                      ),
                    ),
                    const SizedBox(width: 7),
                    Text(
                      'Analysing — multiple voices',
                      style: TextStyle(
                        color: color.withValues(alpha: 0.85),
                        fontSize: 11.5,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ],
                ),
              ],
              if (showBar) ...[
                const SizedBox(height: 8),
                Row(
                  children: [
                    Expanded(
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(3),
                        child: LinearProgressIndicator(
                          value: shown.clamp(0.0, 1.0),
                          minHeight: 4,
                          backgroundColor: Colors.white10,
                          valueColor: AlwaysStoppedAnimation<Color>(color),
                        ),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Text(
                      '$percent%',
                      style: TextStyle(
                        color: color,
                        fontSize: 13,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ],
                ),
              ],
            ],
          ),
        ),
      ],
    );
  }

  // ── Helpers ─────────────────────────────────────────────────────────────────

  Widget _centered(IconData icon, String text, Color color) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Icon(icon, color: color, size: 16),
        const SizedBox(width: 8),
        Text(
          text,
          style: TextStyle(
            color: color,
            fontSize: 13,
            fontWeight: FontWeight.w500,
          ),
        ),
      ],
    );
  }

  Widget _buildSpinner(String text) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        const SizedBox(
          width: 15,
          height: 15,
          child: CircularProgressIndicator(
            strokeWidth: 2,
            color: AppColors.primary,
          ),
        ),
        const SizedBox(width: 10),
        Text(
          text,
          style: const TextStyle(
            color: AppColors.primary,
            fontSize: 13,
            fontWeight: FontWeight.w600,
          ),
        ),
      ],
    );
  }

  Widget _iconCircle(IconData icon, Color color) {
    return Container(
      width: 46,
      height: 46,
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.15),
        shape: BoxShape.circle,
      ),
      child: Icon(icon, color: color, size: 24),
    );
  }
}

// Kept for use in other screens (call history, etc.)
class ConfidenceBarWidget extends StatelessWidget {
  final double confidence;
  final Color color;

  const ConfidenceBarWidget({super.key, required this.confidence, required this.color});

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(4),
      child: LinearProgressIndicator(
        value: confidence.clamp(0.0, 1.0),
        minHeight: 6,
        backgroundColor: Colors.white10,
        valueColor: AlwaysStoppedAnimation<Color>(color),
      ),
    );
  }
}
