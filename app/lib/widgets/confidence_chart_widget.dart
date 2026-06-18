import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import '../core/constants/app_colors.dart';
import '../core/models/verification_result_model.dart';

/// A data point on the confidence timeline.
class ConfidencePoint {
  final DateTime time;
  final double confidence;
  final VerificationVerdict verdict;

  const ConfidencePoint({
    required this.time,
    required this.confidence,
    required this.verdict,
  });
}

/// Small line chart showing confidence score history during a call.
///
/// Pass a list of [ConfidencePoint]s (last N readings). The chart updates
/// whenever the list changes (rebuild triggers re-paint).
class ConfidenceChartWidget extends StatelessWidget {
  final List<ConfidencePoint> points;
  static const int maxPoints = 12; // ~60 s of history at 5 s/segment

  const ConfidenceChartWidget({super.key, required this.points});

  Color _colorFor(VerificationVerdict v) {
    switch (v) {
      case VerificationVerdict.verifiedHigh:
      case VerificationVerdict.verified:
        return AppColors.verified;
      case VerificationVerdict.notVerified:
      case VerificationVerdict.secondaryWarning:
        return AppColors.danger;
      case VerificationVerdict.spoofDetected:
        return AppColors.danger;
      case VerificationVerdict.spoofSuspected:
        return AppColors.warning;
      case VerificationVerdict.uncertain:
        return AppColors.warning;
      default:
        return Colors.white24;
    }
  }

  @override
  Widget build(BuildContext context) {
    if (points.isEmpty) {
      return const SizedBox(
        height: 72,
        child: Center(
          child: Text(
            'No verification data yet',
            style: TextStyle(color: Colors.white24, fontSize: 11),
          ),
        ),
      );
    }

    // Build colored spot list
    final spots = <FlSpot>[];
    for (int i = 0; i < points.length; i++) {
      spots.add(FlSpot(i.toDouble(), points[i].confidence));
    }

    return SizedBox(
      height: 80,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4),
        child: LineChart(
          duration: const Duration(milliseconds: 200),
          LineChartData(
            minY: 0,
            maxY: 1,
            gridData: FlGridData(
              show: true,
              drawVerticalLine: false,
              horizontalInterval: 0.25,
              getDrawingHorizontalLine: (_) =>
                  FlLine(color: Colors.white10, strokeWidth: 1),
            ),
            titlesData: FlTitlesData(
              leftTitles: AxisTitles(
                sideTitles: SideTitles(
                  showTitles: true,
                  interval: 0.5,
                  reservedSize: 28,
                  getTitlesWidget: (value, _) => Text(
                    '${(value * 100).round()}%',
                    style:
                        const TextStyle(color: Colors.white24, fontSize: 9),
                  ),
                ),
              ),
              rightTitles:
                  const AxisTitles(sideTitles: SideTitles(showTitles: false)),
              topTitles:
                  const AxisTitles(sideTitles: SideTitles(showTitles: false)),
              bottomTitles:
                  const AxisTitles(sideTitles: SideTitles(showTitles: false)),
            ),
            borderData: FlBorderData(show: false),
            lineBarsData: [
              LineChartBarData(
                spots: spots,
                isCurved: true,
                curveSmoothness: 0.3,
                color: _colorFor(points.last.verdict),
                barWidth: 2,
                dotData: FlDotData(
                  show: true,
                  getDotPainter: (spot, _, __, index) {
                    final v = points[index].verdict;
                    return FlDotCirclePainter(
                      radius: 3,
                      color: _colorFor(v),
                      strokeWidth: 1,
                      strokeColor: Colors.black26,
                    );
                  },
                ),
                belowBarData: BarAreaData(
                  show: true,
                  color: _colorFor(points.last.verdict).withValues(alpha: 0.08),
                ),
              ),
            ],
            // Reference line at current threshold (~55%)
            extraLinesData: ExtraLinesData(
              horizontalLines: [
                HorizontalLine(
                  y: 0.55,
                  color: Colors.white24,
                  strokeWidth: 1,
                  dashArray: [4, 4],
                  label: HorizontalLineLabel(
                    show: true,
                    alignment: Alignment.topRight,
                    style: const TextStyle(color: Colors.white24, fontSize: 8),
                    labelResolver: (_) => 'threshold',
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
