import 'package:flutter/material.dart';
import '../core/constants/app_colors.dart';
import '../core/models/verification_result_model.dart';

class VerificationOverlayWidget extends StatelessWidget {
  final VerificationResultModel result;

  const VerificationOverlayWidget({super.key, required this.result});

  // ── Listening states — shown before any real result arrives ───────────────
  bool get _isListeningState =>
      result.verdict == VerificationVerdict.idle ||
      result.verdict == VerificationVerdict.silent;

  Color get _bgColor {
    switch (result.verdict) {
      case VerificationVerdict.verifiedHigh:
      case VerificationVerdict.verified:
        return AppColors.verified.withValues(alpha: 0.12);
      case VerificationVerdict.spoofDetected:
        return AppColors.danger.withValues(alpha: 0.12);
      case VerificationVerdict.spoofSuspected:
        return AppColors.warning.withValues(alpha: 0.12);
      case VerificationVerdict.notVerified:
      case VerificationVerdict.secondaryWarning:
        return AppColors.warning.withValues(alpha: 0.12);
      case VerificationVerdict.uncertain:
        return AppColors.uncertain.withValues(alpha: 0.10);
      case VerificationVerdict.analyzing:
        return AppColors.primary.withValues(alpha: 0.10);
      case VerificationVerdict.silent:
      case VerificationVerdict.idle:
        return Colors.white.withValues(alpha: 0.04);
      default:
        return AppColors.surface;
    }
  }

  Color get _borderColor {
    switch (result.verdict) {
      case VerificationVerdict.verifiedHigh:
      case VerificationVerdict.verified:
        return AppColors.verified.withValues(alpha: 0.4);
      case VerificationVerdict.spoofDetected:
        return AppColors.danger.withValues(alpha: 0.4);
      case VerificationVerdict.spoofSuspected:
        return AppColors.warning.withValues(alpha: 0.4);
      case VerificationVerdict.notVerified:
      case VerificationVerdict.secondaryWarning:
        return AppColors.warning.withValues(alpha: 0.4);
      case VerificationVerdict.uncertain:
        return AppColors.uncertain.withValues(alpha: 0.3);
      default:
        return Colors.white12;
    }
  }

  Color get _textColor {
    switch (result.verdict) {
      case VerificationVerdict.verifiedHigh:
      case VerificationVerdict.verified:
        return AppColors.verified;
      case VerificationVerdict.spoofDetected:
        return AppColors.danger;
      case VerificationVerdict.spoofSuspected:
        return AppColors.warning;
      case VerificationVerdict.notVerified:
      case VerificationVerdict.secondaryWarning:
        return AppColors.warning;
      case VerificationVerdict.uncertain:
        return AppColors.uncertain;
      case VerificationVerdict.analyzing:
        return AppColors.primary;
      case VerificationVerdict.silent:
      case VerificationVerdict.idle:
        return Colors.white38;
      default:
        return Colors.white38;
    }
  }

  /// Human-readable label — overrides backend text for listening states.
  String get _displayLabel {
    if (result.verdict == VerificationVerdict.idle ||
        result.verdict == VerificationVerdict.silent) {
      return 'Listening for speech…';
    }
    return result.label;
  }

  IconData get _statusIcon {
    switch (result.verdict) {
      case VerificationVerdict.verifiedHigh:
      case VerificationVerdict.verified:
        return Icons.verified_user;
      case VerificationVerdict.spoofDetected:
        return Icons.gpp_bad;
      case VerificationVerdict.spoofSuspected:
        return Icons.gpp_maybe;
      case VerificationVerdict.notVerified:
      case VerificationVerdict.secondaryWarning:
        return Icons.warning_amber_rounded;
      case VerificationVerdict.analyzing:
        return Icons.manage_search;
      default:
        return Icons.graphic_eq;
    }
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedContainer(
      duration: const Duration(milliseconds: 400),
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: _bgColor,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: _borderColor),
      ),
      child: Column(
        children: [
          // ── Listening indicator (idle / silent) ──────────────────────────
          if (_isListeningState) ...[
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(Icons.graphic_eq, color: Colors.white24, size: 18),
                const SizedBox(width: 8),
                Text(
                  _displayLabel,
                  style: const TextStyle(
                    color: Colors.white38,
                    fontSize: 13,
                    fontWeight: FontWeight.w500,
                    letterSpacing: 0.3,
                  ),
                ),
              ],
            ),
          ] else ...[
            // ── Main result label ─────────────────────────────────────────
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(_statusIcon, color: _textColor, size: 22),
                const SizedBox(width: 8),
                Flexible(
                  child: Text(
                    _displayLabel,
                    style: TextStyle(
                      color: _textColor,
                      fontSize: 15,
                      fontWeight: FontWeight.w700,
                    ),
                    textAlign: TextAlign.center,
                  ),
                ),
              ],
            ),

            // Analysing progress bar
            if (result.verdict == VerificationVerdict.analyzing) ...[
              const SizedBox(height: 8),
              SizedBox(
                height: 2,
                child: LinearProgressIndicator(
                  backgroundColor: AppColors.primary.withValues(alpha: 0.1),
                  color: AppColors.primary,
                ),
              ),
            ],

            // Confidence bar (skip for analyzing)
            if (result.verdict != VerificationVerdict.analyzing) ...[
              const SizedBox(height: 12),
              ConfidenceBarWidget(
                confidence: result.confidence,
                color: _textColor,
              ),
              const SizedBox(height: 4),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  const Text(
                    'Confidence',
                    style: TextStyle(color: Colors.white38, fontSize: 11),
                  ),
                  Text(
                    '${result.confidencePercent}%',
                    style: TextStyle(
                      color: _textColor,
                      fontSize: 12,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  Expanded(
                    child: _MetricPill(
                      label: 'Match',
                      value: result.similarityScore == null
                          ? '-'
                          : '${(result.similarityScore! * 100).round()}%',
                      color: _textColor,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: _MetricPill(
                      label: 'Spoof risk',
                      value: '${(result.spoofProbability * 100).round()}%',
                      color: result.isSpoof ? AppColors.danger : Colors.white60,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: _MetricPill(
                      label: 'Scans',
                      value: '${result.segmentsAnalyzed}',
                      color: Colors.white60,
                    ),
                  ),
                ],
              ),
              if (result.secondaryAvailable) ...[
                const SizedBox(height: 8),
                Row(
                  children: [
                    Expanded(
                      child: _MetricPill(
                        label: 'Secondary',
                        value: result.secondarySimilarityScore == null
                            ? '-'
                            : '${(result.secondarySimilarityScore! * 100).round()}%',
                        color: result.secondaryMatched == true
                            ? AppColors.verified
                            : AppColors.warning,
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: _MetricPill(
                        label: 'Media',
                        value: result.mediaSource == null
                            ? 'remote'
                            : result.mediaSource!.replaceAll('_', ' '),
                        color: Colors.white60,
                      ),
                    ),
                  ],
                ),
              ],
              if (result.message.isNotEmpty) ...[
                const SizedBox(height: 8),
                Text(
                  result.message,
                  style: const TextStyle(color: Colors.white54, fontSize: 11),
                  textAlign: TextAlign.center,
                ),
              ],
            ],

            // Spoof warning
            if (result.isSpoof) ...[
              const SizedBox(height: 8),
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                decoration: BoxDecoration(
                  color: AppColors.danger.withValues(alpha: 0.2),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: const Text(
                  '⚠️ AI-generated voice detected — do not share sensitive information',
                  style: TextStyle(color: AppColors.danger, fontSize: 11),
                  textAlign: TextAlign.center,
                ),
              ),
            ],
          ],
        ],
      ),
    );
  }
}

class ConfidenceBarWidget extends StatelessWidget {
  final double confidence;
  final Color color;

  const ConfidenceBarWidget({
    super.key,
    required this.confidence,
    required this.color,
  });

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

class _MetricPill extends StatelessWidget {
  final String label;
  final String value;
  final Color color;

  const _MetricPill({
    required this.label,
    required this.value,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.16),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        children: [
          Text(label,
              style: const TextStyle(color: Colors.white38, fontSize: 10)),
          const SizedBox(height: 2),
          Text(
            value,
            style: TextStyle(
              color: color,
              fontSize: 12,
              fontWeight: FontWeight.bold,
            ),
          ),
        ],
      ),
    );
  }
}
