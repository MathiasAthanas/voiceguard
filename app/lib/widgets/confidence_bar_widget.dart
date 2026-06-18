import 'package:flutter/material.dart';
import '../core/constants/app_colors.dart';

class ConfidenceBarWidget extends StatelessWidget {
  final double confidence;
  final Color? color;
  final double height;
  final bool showLabel;

  const ConfidenceBarWidget({
    super.key,
    required this.confidence,
    this.color,
    this.height = 8,
    this.showLabel = false,
  });

  Color get _barColor {
    if (color != null) return color!;
    if (confidence >= 0.85) return AppColors.verified;
    if (confidence >= 0.65) return AppColors.warning;
    return AppColors.danger;
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (showLabel) ...[
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Text('Confidence', style: TextStyle(color: Colors.white54, fontSize: 11)),
              Text(
                '${(confidence * 100).round()}%',
                style: TextStyle(color: _barColor, fontSize: 11, fontWeight: FontWeight.bold),
              ),
            ],
          ),
          const SizedBox(height: 4),
        ],
        ClipRRect(
          borderRadius: BorderRadius.circular(height / 2),
          child: TweenAnimationBuilder<double>(
            tween: Tween(begin: 0, end: confidence.clamp(0.0, 1.0)),
            duration: const Duration(milliseconds: 600),
            curve: Curves.easeOut,
            builder: (context, value, _) {
              return LinearProgressIndicator(
                value: value,
                minHeight: height,
                backgroundColor: Colors.white10,
                valueColor: AlwaysStoppedAnimation<Color>(_barColor),
              );
            },
          ),
        ),
      ],
    );
  }
}
