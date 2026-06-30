enum VerificationVerdict {
  verified,
  verifiedHigh,
  notVerified,
  uncertain,
  secondaryWarning,
  spoofSuspected,
  spoofDetected,
  notEnrolled,
  silent,
  analyzing,
  idle,
}

class VerificationResultModel {
  final String contactId;
  final VerificationVerdict verdict;
  final double confidence;
  final double? similarityScore;
  final double spoofProbability;
  final bool isVerified;
  final bool isSpoof;
  final String label;
  final String message;
  final DateTime timestamp;
  final int segmentsAnalyzed;
  final double? secondarySimilarityScore;
  final bool secondaryAvailable;
  final bool? secondaryMatched;
  final String? audioRole;
  final String? mediaSource;
  // Presentational confidence (0..1) from the backend, anchored on the active
  // model's thresholds. What the UI shows — raw cosine is misleading as a %.
  final double? displayConfidence;

  VerificationResultModel({
    required this.contactId,
    required this.verdict,
    required this.confidence,
    this.similarityScore,
    required this.spoofProbability,
    required this.isVerified,
    required this.isSpoof,
    required this.label,
    required this.message,
    required this.timestamp,
    this.segmentsAnalyzed = 0,
    this.secondarySimilarityScore,
    this.secondaryAvailable = false,
    this.secondaryMatched,
    this.audioRole,
    this.mediaSource,
    this.displayConfidence,
  });

  factory VerificationResultModel.idle() {
    return VerificationResultModel(
      contactId: '',
      verdict: VerificationVerdict.idle,
      confidence: 0,
      spoofProbability: 0,
      isVerified: false,
      isSpoof: false,
      label: 'Waiting...',
      message: 'Waiting for call',
      timestamp: DateTime.now(),
    );
  }

  factory VerificationResultModel.analyzing() {
    return VerificationResultModel(
      contactId: '',
      verdict: VerificationVerdict.analyzing,
      confidence: 0,
      spoofProbability: 0,
      isVerified: false,
      isSpoof: false,
      label: 'Analyzing voice...',
      message: 'Processing audio',
      timestamp: DateTime.now(),
    );
  }

  factory VerificationResultModel.notEnrolled(String contactId) {
    return VerificationResultModel(
      contactId: contactId,
      verdict: VerificationVerdict.notEnrolled,
      confidence: 0,
      spoofProbability: 0,
      isVerified: false,
      isSpoof: false,
      label: 'Not enrolled',
      message: 'Enroll this contact before live verification',
      timestamp: DateTime.now(),
    );
  }

  factory VerificationResultModel.error(String message) {
    return VerificationResultModel(
      contactId: '',
      verdict: VerificationVerdict.uncertain,
      confidence: 0,
      spoofProbability: 0,
      isVerified: false,
      isSpoof: false,
      label: 'Verification unavailable',
      message: message,
      timestamp: DateTime.now(),
    );
  }

  factory VerificationResultModel.fromJson(Map<String, dynamic> json) {
    final verdictStr = json['verdict'] as String? ?? 'uncertain';

    VerificationVerdict verdict;
    switch (verdictStr) {
      case 'verified_high':
        verdict = VerificationVerdict.verifiedHigh;
        break;
      case 'verified':
        verdict = VerificationVerdict.verified;
        break;
      case 'not_verified':
        verdict = VerificationVerdict.notVerified;
        break;
      case 'secondary_warning':
        verdict = VerificationVerdict.secondaryWarning;
        break;
      case 'spoof_suspected':
        verdict = VerificationVerdict.spoofSuspected;
        break;
      case 'spoof_detected':
        verdict = VerificationVerdict.spoofDetected;
        break;
      case 'not_enrolled':
        verdict = VerificationVerdict.notEnrolled;
        break;
      case 'silent':
        verdict = VerificationVerdict.silent;
        break;
      default:
        verdict = VerificationVerdict.uncertain;
    }

    final secondary = json['secondary_verification'] is Map
        ? Map<String, dynamic>.from(json['secondary_verification'])
        : <String, dynamic>{};

    return VerificationResultModel(
      contactId: json['contact_id'] ?? '',
      verdict: verdict,
      confidence: (json['confidence'] as num?)?.toDouble() ?? 0.0,
      similarityScore: (json['similarity_score'] as num?)?.toDouble(),
      displayConfidence: (json['display_confidence'] as num?)?.toDouble(),
      spoofProbability: (json['spoof_probability'] as num?)?.toDouble() ?? 0.0,
      isVerified: json['is_verified'] ?? false,
      isSpoof: json['is_spoof'] ?? false,
      label: json['label'] ?? '',
      message: json['message'] ?? '',
      timestamp: DateTime.now(),
      segmentsAnalyzed: json['segments_analyzed'] ?? 0,
      secondarySimilarityScore:
          (secondary['similarity_score'] as num?)?.toDouble(),
      secondaryAvailable: secondary['available'] == true,
      secondaryMatched: secondary.containsKey('is_same_speaker')
          ? secondary['is_same_speaker'] == true
          : null,
      audioRole: json['audio_role'] as String?,
      mediaSource: json['media_source'] as String?,
    );
  }

  Map<String, dynamic> toJson() {
    final verdictValue = switch (verdict) {
      VerificationVerdict.verifiedHigh => 'verified_high',
      VerificationVerdict.verified => 'verified',
      VerificationVerdict.notVerified => 'not_verified',
      VerificationVerdict.secondaryWarning => 'secondary_warning',
      VerificationVerdict.spoofSuspected => 'spoof_suspected',
      VerificationVerdict.spoofDetected => 'spoof_detected',
      VerificationVerdict.notEnrolled => 'not_enrolled',
      VerificationVerdict.silent => 'silent',
      VerificationVerdict.analyzing => 'analyzing',
      VerificationVerdict.idle => 'idle',
      VerificationVerdict.uncertain => 'uncertain',
    };
    return {
      'contact_id': contactId,
      'verdict': verdictValue,
      'confidence': confidence,
      'similarity_score': similarityScore,
      'display_confidence': displayConfidence,
      'spoof_probability': spoofProbability,
      'is_verified': isVerified,
      'is_spoof': isSpoof,
      'label': label,
      'message': message,
      'segments_analyzed': segmentsAnalyzed,
      'secondary_verification': {
        'available': secondaryAvailable,
        'similarity_score': secondarySimilarityScore,
        'is_same_speaker': secondaryMatched,
      },
      'audio_role': audioRole,
      'media_source': mediaSource,
    };
  }

  int get confidencePercent => (confidence * 100).round();
}
