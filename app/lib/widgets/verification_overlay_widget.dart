import 'package:flutter/material.dart';
import '../core/constants/app_colors.dart';
import '../core/models/verification_result_model.dart';

class VerificationOverlayWidget extends StatelessWidget {
  final VerificationResultModel result;

  const VerificationOverlayWidget({super.key, required this.result});

  bool get _isIdle =>
      result.verdict == VerificationVerdict.idle ||
      result.verdict == VerificationVerdict.silent;

  bool get _isAnalyzing => result.verdict == VerificationVerdict.analyzing;

  bool get _isVerified =>
      result.verdict == VerificationVerdict.verified ||
      result.verdict == VerificationVerdict.verifiedHigh;

  bool get _isMismatch =>
      result.verdict == VerificationVerdict.notVerified ||
      result.verdict == VerificationVerdict.secondaryWarning;

  bool get _isSpoof =>
      result.verdict == VerificationVerdict.spoofDetected ||
      result.verdict == VerificationVerdict.spoofSuspected;

  bool get _isNotEnrolled =>
      result.verdict == VerificationVerdict.notEnrolled;

  Color get _accentColor {
    if (_isVerified) return AppColors.verified;
    if (_isMismatch) return AppColors.warning;
    if (_isSpoof) return AppColors.danger;
    return Colors.white38;
  }

  bool get _isSubtle =>
      _isIdle || _isAnalyzing || result.verdict == VerificationVerdict.uncertain;

  @override
  Widget build(BuildContext context) {
    return AnimatedContainer(
      duration: const Duration(milliseconds: 400),
      curve: Curves.easeInOut,
      width: double.infinity,
      padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 18),
      decoration: BoxDecoration(
        color: _isSubtle
            ? Colors.white.withValues(alpha: 0.04)
            : _accentColor.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(
          color: _isSubtle
              ? Colors.white12
              : _accentColor.withValues(alpha: 0.35),
          width: 1.2,
        ),
      ),
      child: _buildContent(),
    );
  }

  Widget _buildContent() {
    if (_isIdle) return _buildCentered(Icons.graphic_eq, 'Listening for speech…', Colors.white24);
    if (_isAnalyzing) return _buildSpinner();
    if (_isNotEnrolled) return _buildCentered(Icons.mic_off_rounded, 'Contact not enrolled', Colors.white38);
    if (_isSpoof) return _buildSpoof();
    return _buildVerdict();
  }

  Widget _buildCentered(IconData icon, String text, Color color) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Icon(icon, color: color, size: 16),
        const SizedBox(width: 8),
        Text(text, style: TextStyle(color: color, fontSize: 13, fontWeight: FontWeight.w500)),
      ],
    );
  }

  Widget _buildSpinner() {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        SizedBox(
          width: 15,
          height: 15,
          child: CircularProgressIndicator(strokeWidth: 2, color: AppColors.primary),
        ),
        const SizedBox(width: 10),
        const Text(
          'Analyzing voice…',
          style: TextStyle(color: AppColors.primary, fontSize: 13, fontWeight: FontWeight.w600),
        ),
      ],
    );
  }

  Widget _buildSpoof() {
    return Row(
      children: [
        _iconCircle(Icons.gpp_bad_rounded, AppColors.danger),
        const SizedBox(width: 14),
        const Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Suspicious voice',
                style: TextStyle(
                  color: AppColors.danger,
                  fontSize: 16,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 0.1,
                ),
              ),
              SizedBox(height: 3),
              Text(
                'Do not share sensitive information',
                style: TextStyle(color: AppColors.danger, fontSize: 12, fontWeight: FontWeight.w500),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildVerdict() {
    final (IconData icon, String title, bool showBar) = switch (result.verdict) {
      VerificationVerdict.verifiedHigh => (Icons.verified_user_rounded, 'Voice confirmed', true),
      VerificationVerdict.verified     => (Icons.verified_user_rounded, 'Likely confirmed', true),
      VerificationVerdict.notVerified ||
      VerificationVerdict.secondaryWarning => (Icons.warning_amber_rounded, 'Voice mismatch', true),
      _                                => (Icons.graphic_eq, 'Checking…', false),
    };

    final color = _isVerified ? AppColors.verified : _isMismatch ? AppColors.warning : Colors.white38;

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
              if (showBar) ...[
                const SizedBox(height: 8),
                Row(
                  children: [
                    Expanded(
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(3),
                        child: LinearProgressIndicator(
                          value: result.confidence.clamp(0.0, 1.0),
                          minHeight: 4,
                          backgroundColor: Colors.white10,
                          valueColor: AlwaysStoppedAnimation<Color>(color),
                        ),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Text(
                      '${result.confidencePercent}%',
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
