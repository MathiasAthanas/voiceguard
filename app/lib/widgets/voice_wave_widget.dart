import 'dart:math';
import 'package:flutter/material.dart';
import '../core/constants/app_colors.dart';

class VoiceWaveWidget extends StatefulWidget {
  final bool isActive;
  final Color color;

  const VoiceWaveWidget({
    super.key,
    this.isActive = true,
    this.color = AppColors.primary,
  });

  @override
  State<VoiceWaveWidget> createState() => _VoiceWaveWidgetState();
}

class _VoiceWaveWidgetState extends State<VoiceWaveWidget>
    with TickerProviderStateMixin {
  late List<AnimationController> _controllers;
  late List<Animation<double>> _animations;
  final int _barCount = 20;
  final Random _random = Random();

  @override
  void initState() {
    super.initState();
    _controllers = List.generate(_barCount, (i) {
      return AnimationController(
        vsync: this,
        duration: Duration(milliseconds: 400 + _random.nextInt(400)),
      )..repeat(reverse: true);
    });

    _animations = _controllers.map((ctrl) {
      return Tween<double>(
        begin: 4,
        end: 30 + _random.nextDouble() * 20,
      ).animate(CurvedAnimation(parent: ctrl, curve: Curves.easeInOut));
    }).toList();
  }

  @override
  void dispose() {
    for (final ctrl in _controllers) {
      ctrl.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 60,
      child: AnimatedBuilder(
        animation: _controllers.first,
        builder: (context, _) {
          return Row(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.center,
            children: List.generate(_barCount, (i) {
              final height = widget.isActive ? _animations[i].value : 4.0;
              return AnimatedContainer(
                duration: const Duration(milliseconds: 100),
                margin: const EdgeInsets.symmetric(horizontal: 2),
                width: 4,
                height: height,
                decoration: BoxDecoration(
                  color: widget.color.withValues(alpha: 0.7 + (i % 3) * 0.1),
                  borderRadius: BorderRadius.circular(2),
                ),
              );
            }),
          );
        },
      ),
    );
  }
}
