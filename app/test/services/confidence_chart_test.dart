import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voiceguard/core/models/verification_result_model.dart';
import 'package:voiceguard/widgets/confidence_chart_widget.dart';

void main() {
  group('ConfidenceChartWidget', () {
    testWidgets('renders "no data" placeholder when empty', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: ConfidenceChartWidget(points: []),
          ),
        ),
      );
      expect(find.text('No verification data yet'), findsOneWidget);
    });

    testWidgets('renders chart when points are provided', (tester) async {
      final points = [
        ConfidencePoint(
          time: DateTime.now(),
          confidence: 0.7,
          verdict: VerificationVerdict.verified,
        ),
        ConfidencePoint(
          time: DateTime.now().add(const Duration(seconds: 5)),
          confidence: 0.8,
          verdict: VerificationVerdict.verifiedHigh,
        ),
      ];

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ConfidenceChartWidget(points: points),
          ),
        ),
      );

      // No "no data" placeholder
      expect(find.text('No verification data yet'), findsNothing);
    });

    test('maxPoints constant is reasonable', () {
      expect(ConfidenceChartWidget.maxPoints, greaterThanOrEqualTo(10));
      expect(ConfidenceChartWidget.maxPoints, lessThanOrEqualTo(30));
    });
  });
}
