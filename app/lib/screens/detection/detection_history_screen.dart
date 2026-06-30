import 'package:flutter/material.dart';
import 'package:hive_flutter/hive_flutter.dart';
import '../../core/constants/app_colors.dart';

class DetectionHistoryScreen extends StatelessWidget {
  const DetectionHistoryScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final detectionBox = Hive.box('detection_history');
    final contactsBox = Hive.box('contacts');

    return ValueListenableBuilder(
      valueListenable: detectionBox.listenable(),
      builder: (context, Box box, _) {
        final detections = box.values
            .map((e) => Map<String, dynamic>.from(e as Map))
            .toList()
          ..sort((a, b) => DateTime.parse(b['timestamp'] as String)
              .compareTo(DateTime.parse(a['timestamp'] as String)));

        return ValueListenableBuilder(
          valueListenable: contactsBox.listenable(),
          builder: (context, Box contacts, _) {
            final enrollments = contacts.values
                .map((e) => Map<String, dynamic>.from(e as Map))
                .where(
                    (c) => c['isEnrolled'] == true && c['enrolledAt'] != null)
                .toList()
              ..sort((a, b) => DateTime.parse(b['enrolledAt'] as String)
                  .compareTo(DateTime.parse(a['enrolledAt'] as String)));

            return DefaultTabController(
              length: 2,
              child: Column(
                children: [
                  const TabBar(
                    indicatorColor: AppColors.primary,
                    labelColor: AppColors.primary,
                    unselectedLabelColor: Colors.white54,
                    tabs: [
                      Tab(icon: Icon(Icons.security), text: 'Detections'),
                      Tab(
                          icon: Icon(Icons.record_voice_over),
                          text: 'Enrollments'),
                    ],
                  ),
                  Expanded(
                    child: TabBarView(
                      children: [
                        _DetectionList(items: detections),
                        _EnrollmentList(items: enrollments),
                      ],
                    ),
                  ),
                ],
              ),
            );
          },
        );
      },
    );
  }
}

class _DetectionList extends StatelessWidget {
  final List<Map<String, dynamic>> items;

  const _DetectionList({required this.items});

  @override
  Widget build(BuildContext context) {
    if (items.isEmpty) {
      return const _EmptyState(
        icon: Icons.manage_search,
        title: 'No detections yet',
        message: 'Verification scans will appear here after calls.',
      );
    }

    return ListView.builder(
      padding: const EdgeInsets.all(16),
      itemCount: items.length,
      itemBuilder: (context, index) {
        final item = items[index];
        final verdict = item['verdict'] as String? ?? 'unknown';
        final color = _verdictColor(verdict);
        // Show the threshold-anchored display confidence (falls back to raw
        // similarity), so the number agrees with the flag and reads sensibly
        // regardless of model scale.
        final shown = ((item['displayConfidence'] as num?)?.toDouble() ??
                (item['similarityScore'] as num?)?.toDouble() ??
                0) *
            100;
        final time = DateTime.tryParse(item['timestamp'] as String? ?? '');

        return Container(
          margin: const EdgeInsets.only(bottom: 10),
          decoration: BoxDecoration(
            color: AppColors.surface,
            borderRadius: BorderRadius.circular(8),
          ),
          child: ListTile(
            leading: CircleAvatar(
              backgroundColor: color.withValues(alpha: 0.15),
              child: Icon(_verdictIcon(verdict), color: color),
            ),
            title: Text(
              item['contactName'] as String? ?? 'Unknown',
              style: const TextStyle(
                  color: Colors.white, fontWeight: FontWeight.w600),
            ),
            subtitle: Text(
              '${_verdictLabel(verdict)} • ${time == null ? '' : _formatTime(time)}',
              style: TextStyle(color: color, fontSize: 12),
            ),
            trailing: Text(
              '${shown.round()}%',
              style: TextStyle(color: color, fontWeight: FontWeight.bold),
            ),
            onTap: () => _showDetectionDetails(context, item),
          ),
        );
      },
    );
  }

  void _showDetectionDetails(BuildContext context, Map<String, dynamic> item) {
    final verdict = item['verdict'] as String? ?? 'unknown';
    final color = _verdictColor(verdict);

    showModalBottomSheet<void>(
      context: context,
      backgroundColor: AppColors.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(18)),
      ),
      builder: (_) => Padding(
        padding: const EdgeInsets.fromLTRB(20, 18, 20, 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(_verdictIcon(verdict), color: color, size: 28),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    _verdictLabel(verdict),
                    style: TextStyle(
                      color: color,
                      fontSize: 18,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            _detail('Contact', item['contactName']),
            _detail('Number / ID', item['contactNumber']),
            _detail('Call type', item['callType']),
            _detail('Confidence', _percent(item['confidence'])),
            _detail('Voice match', _percent(item['similarityScore'])),
            _detail('Spoof risk', _percent(item['spoofProbability'])),
            _detail(
                'Secondary match', _percent(item['secondarySimilarityScore'])),
            _detail('Audio source', item['mediaSource']),
            _detail('Segments analyzed', '${item['segmentsAnalyzed'] ?? 0}'),
            if ((item['message'] as String?)?.isNotEmpty == true) ...[
              const SizedBox(height: 8),
              Text(
                item['message'] as String,
                style: const TextStyle(color: Colors.white60, fontSize: 13),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _EnrollmentList extends StatelessWidget {
  final List<Map<String, dynamic>> items;

  const _EnrollmentList({required this.items});

  @override
  Widget build(BuildContext context) {
    if (items.isEmpty) {
      return const _EmptyState(
        icon: Icons.record_voice_over,
        title: 'No enrollments yet',
        message: 'Voice profiles appear here after enrollment succeeds.',
      );
    }

    return ListView.builder(
      padding: const EdgeInsets.all(16),
      itemCount: items.length,
      itemBuilder: (context, index) {
        final item = items[index];
        final enrolledAt =
            DateTime.tryParse(item['enrolledAt'] as String? ?? '');
        return Container(
          margin: const EdgeInsets.only(bottom: 10),
          decoration: BoxDecoration(
            color: AppColors.surface,
            borderRadius: BorderRadius.circular(8),
          ),
          child: ListTile(
            leading: CircleAvatar(
              backgroundColor: AppColors.verified.withValues(alpha: 0.15),
              child: const Icon(Icons.check, color: AppColors.verified),
            ),
            title: Text(
              item['name'] as String? ?? 'Unknown',
              style: const TextStyle(
                  color: Colors.white, fontWeight: FontWeight.w600),
            ),
            subtitle: Text(
              enrolledAt == null
                  ? 'Enrolled'
                  : 'Enrolled ${_formatTime(enrolledAt)}',
              style: const TextStyle(color: Colors.white54, fontSize: 12),
            ),
          ),
        );
      },
    );
  }
}

class _EmptyState extends StatelessWidget {
  final IconData icon;
  final String title;
  final String message;

  const _EmptyState({
    required this.icon,
    required this.title,
    required this.message,
  });

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(icon, color: Colors.white24, size: 64),
          const SizedBox(height: 16),
          Text(title,
              style: const TextStyle(color: Colors.white38, fontSize: 16)),
          const SizedBox(height: 8),
          Text(message,
              style: const TextStyle(color: Colors.white24, fontSize: 13),
              textAlign: TextAlign.center),
        ],
      ),
    );
  }
}

Widget _detail(String label, Object? value) {
  return Padding(
    padding: const EdgeInsets.symmetric(vertical: 5),
    child: Row(
      children: [
        Expanded(
          child: Text(label,
              style: const TextStyle(color: Colors.white38, fontSize: 13)),
        ),
        Text(
          '${value ?? '-'}',
          style:
              const TextStyle(color: Colors.white, fontWeight: FontWeight.w600),
        ),
      ],
    ),
  );
}

// Real speaker = green; Not real speaker = red. Both the new realSpeaker/
// notRealSpeaker strings and the per-segment verified/notVerified strings map
// to the same two flags so history reads as a clean binary.
Color _verdictColor(String verdict) {
  switch (verdict) {
    case 'realSpeaker':
    case 'verifiedHigh':
    case 'verified':
      return AppColors.verified;
    case 'notRealSpeaker':
    case 'notVerified':
    case 'spoofDetected':
      return AppColors.danger;
    default:
      return Colors.white54;
  }
}

IconData _verdictIcon(String verdict) {
  switch (verdict) {
    case 'realSpeaker':
    case 'verifiedHigh':
    case 'verified':
      return Icons.verified_user;
    case 'notRealSpeaker':
    case 'notVerified':
    case 'spoofDetected':
      return Icons.gpp_bad;
    default:
      return Icons.help_outline;
  }
}

String _verdictLabel(String verdict) {
  switch (verdict) {
    case 'realSpeaker':
    case 'verifiedHigh':
    case 'verified':
      return 'Real speaker';
    case 'notRealSpeaker':
    case 'notVerified':
    case 'spoofDetected':
      return 'Not real speaker';
    default:
      return 'Inconclusive';
  }
}

String _percent(Object? value) {
  final number = (value as num?)?.toDouble();
  if (number == null) return '-';
  return '${(number * 100).round()}%';
}

String _formatTime(DateTime time) {
  final now = DateTime.now();
  final local = time.toLocal();
  final clock =
      '${local.hour.toString().padLeft(2, '0')}:${local.minute.toString().padLeft(2, '0')}';
  if (now.year == local.year &&
      now.month == local.month &&
      now.day == local.day) {
    return 'today at $clock';
  }
  return '${local.day}/${local.month}/${local.year} $clock';
}
