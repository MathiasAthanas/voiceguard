enum CallType { voip, cellular }

/// incoming  – answered by us
/// outgoing  – we placed the call
/// missed    – rang but was never answered (rejected or caller hung up first)
enum CallDirection { incoming, outgoing, missed }

class CallRecordModel {
  final String id;
  final String contactName;
  final String contactNumber;
  final CallType callType;
  final CallDirection direction;
  final DateTime startTime;
  final Duration? duration;
  final String? verificationVerdict;
  final double? verificationConfidence;
  final double? similarityScore;
  final double? spoofProbability;
  final int? segmentsAnalyzed;
  final String? verificationMessage;
  final bool? spoofDetected;

  CallRecordModel({
    required this.id,
    required this.contactName,
    required this.contactNumber,
    required this.callType,
    required this.direction,
    required this.startTime,
    this.duration,
    this.verificationVerdict,
    this.verificationConfidence,
    this.similarityScore,
    this.spoofProbability,
    this.segmentsAnalyzed,
    this.verificationMessage,
    this.spoofDetected,
  });

  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'contactName': contactName,
      'contactNumber': contactNumber,
      'callType': callType.name,
      'direction': direction.name,
      'startTime': startTime.toIso8601String(),
      'duration': duration?.inSeconds,
      'verificationVerdict': verificationVerdict,
      'verificationConfidence': verificationConfidence,
      'similarityScore': similarityScore,
      'spoofProbability': spoofProbability,
      'segmentsAnalyzed': segmentsAnalyzed,
      'verificationMessage': verificationMessage,
      'spoofDetected': spoofDetected,
    };
  }

  factory CallRecordModel.fromMap(Map<String, dynamic> map) {
    return CallRecordModel(
      id: map['id'] ?? '',
      contactName: map['contactName'] ?? 'Unknown',
      contactNumber: map['contactNumber'] ?? '',
      callType: CallType.values.firstWhere(
        (e) => e.name == map['callType'],
        orElse: () => CallType.cellular,
      ),
      direction: CallDirection.values.firstWhere(
        (e) => e.name == map['direction'],
        orElse: () => CallDirection.incoming,
      ),
      startTime: DateTime.parse(map['startTime']),
      duration:
          map['duration'] != null ? Duration(seconds: map['duration']) : null,
      verificationVerdict: map['verificationVerdict'],
      verificationConfidence:
          (map['verificationConfidence'] as num?)?.toDouble(),
      similarityScore: (map['similarityScore'] as num?)?.toDouble(),
      spoofProbability: (map['spoofProbability'] as num?)?.toDouble(),
      segmentsAnalyzed: map['segmentsAnalyzed'],
      verificationMessage: map['verificationMessage'],
      spoofDetected: map['spoofDetected'],
    );
  }

  String get formattedDuration {
    if (duration == null) return '—';
    final minutes = duration!.inMinutes;
    final seconds = duration!.inSeconds % 60;
    return '${minutes}m ${seconds}s';
  }

  String get formattedTime {
    final now = DateTime.now();
    final diff = now.difference(startTime);
    if (diff.inDays == 0)
      return 'Today ${startTime.hour}:${startTime.minute.toString().padLeft(2, '0')}';
    if (diff.inDays == 1) return 'Yesterday';
    return '${startTime.day}/${startTime.month}/${startTime.year}';
  }
}
