import 'package:flutter/material.dart';
import '../core/constants/app_colors.dart';

class CallButtonWidget extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final Color? color;
  final double size;
  final bool isActive;

  const CallButtonWidget({
    super.key,
    required this.icon,
    required this.label,
    required this.onTap,
    this.color,
    this.size = 56,
    this.isActive = false,
  });

  @override
  Widget build(BuildContext context) {
    final btnColor = color ?? (isActive ? AppColors.primary : AppColors.surface);

    return GestureDetector(
      onTap: onTap,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          AnimatedContainer(
            duration: const Duration(milliseconds: 200),
            width: size,
            height: size,
            decoration: BoxDecoration(
              color: btnColor,
              shape: BoxShape.circle,
              boxShadow: color != null
                  ? [
                      BoxShadow(
                        color: btnColor.withValues(alpha: 0.4),
                        blurRadius: 16,
                        spreadRadius: 2,
                      ),
                    ]
                  : null,
            ),
            child: Icon(
              icon,
              color: Colors.white,
              size: size * 0.45,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            label,
            style: const TextStyle(
              color: Colors.white54,
              fontSize: 11,
            ),
          ),
        ],
      ),
    );
  }
}
