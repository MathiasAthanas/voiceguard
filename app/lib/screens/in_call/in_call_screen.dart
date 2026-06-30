import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:path_provider/path_provider.dart';
import 'package:provider/provider.dart';
import '../../core/constants/app_colors.dart';
import '../../core/models/contact_model.dart';
import '../../core/services/signaling_service.dart';
import '../../core/services/webrtc_service.dart';
import '../../core/services/cellular_call_service.dart';
import '../../core/services/voip_audio_recorder.dart';
import '../../core/services/voip_relay_service.dart';
import '../../core/services/call_audio_recorder.dart';
import '../../core/services/vad_processor.dart';
import '../../core/services/verification_service.dart';
import '../../core/services/shell_audio_service.dart';
import '../../core/models/verification_result_model.dart';
import '../../widgets/verification_overlay_widget.dart';
import '../../widgets/voice_wave_widget.dart';
import '../../widgets/call_button_widget.dart';
import '../enroll/enroll_screen.dart';

class InCallScreen extends StatefulWidget {
  final String contactName;
  final String contactNumber;
  final bool isVoIP;
  final bool isIncoming;

  // VoIP-specific (only for incoming VoIP calls)
  final String? voipRoomId;
  final String? voipCallerId;
  final Map<String, dynamic>? voipOffer;

  const InCallScreen({
    super.key,
    required this.contactName,
    required this.contactNumber,
    required this.isVoIP,
    required this.isIncoming,
    this.voipRoomId,
    this.voipCallerId,
    this.voipOffer,
  });

  @override
  State<InCallScreen> createState() => _InCallScreenState();
}

class _InCallScreenState extends State<InCallScreen> {
  // ── Call timer ────────────────────────────────────────────────────────────
  Timer? _callTimer;
  int _callSeconds = 0;
  bool _callIsActive = false;
  DateTime? _callStartTime;

  // ── Monitoring / verification ─────────────────────────────────────────────
  bool _isMonitoring = false;
  Timer? _monitoringWatchdog;

  /// VoIP path: streams audio through the signaling server (relay mode).
  VoipRelayService? _relay;

  /// Legacy OUTPUT-channel recorder — kept for the AI monitoring path but
  /// disabled via _enableVoipOutputRecorder while relay is active.
  final VoipAudioRecorder _voipRecorder = VoipAudioRecorder();

  /// Cellular path: native VOICE_RECOGNITION recorder + VAD (AEC off → more
  /// earpiece bleed → cleaner remote-speaker extraction)
  final CallAudioRecorder _callRecorder = CallAudioRecorder();

  /// Indirection pointer used by the active call recorder.
  /// Both _voipRecorder and _callRecorder forward to this via their callbacks.
  Function(String)? _segmentHandler;

  late VerificationService _verificationService;
  String? _lastVerdict;
  double? _lastConfidence;
  double? _lastSimilarityScore;
  double? _lastSpoofProbability;
  int? _lastSegmentsAnalyzed;
  String? _lastVerificationMessage;
  VerificationVerdict? _lastAlertVerdict;

  // ── Auto-enrollment state ─────────────────────────────────────────────────
  bool _enrollmentMode = false;
  bool _enrollmentComplete = false;
  bool _enrollmentInProgress = false;
  final List<String> _enrollmentSegments = [];
  String _enrollmentStatus = '';
  // How many segments have arrived since monitoring started. The first two
  // (10 s) are discarded: call audio is unstable at start (AGC settling,
  // high packet-loss burst, short "Hello?" utterance). Only segments 3+
  // are used for enrollment so the voiceprint is built on stable audio.
  int _enrollSkipCount = 0;

  // Whether we already retried cellular capture with the MIC source after
  // VOICE_RECOGNITION returned silence (Android 12–13 restriction).
  bool _triedMicFallback = false;

  // Set when ADB shell audio (VOICE_DOWNLINK via UID 2000) is the active
  // capture path. When true, _callRecorder is not started and the signal-
  // quality notice is suppressed.
  bool _usingShellAudio = false;

  // Set when the OS silences ALL audio sources at the HAL level (peak == 0).
  // Triggers post-call enrollment redirect to EnrollScreen for unenrolled contacts.
  bool _hardwareAudioBlocked = false;

  /// Set when the recorder can't pick up usable remote-caller audio (e.g. the
  /// call is on the earpiece so there's nothing for VAD to extract). Surfaced
  /// as a prompt to switch to speakerphone.
  String? _captureHint;

  /// During a live call we require more VAD-filtered segments to build a
  /// reliable voiceprint (audio quality is lower than a quiet EnrollScreen
  /// recording).  Outside of calls the EnrollScreen uses its own recording.
  /// For presentation testing we collect three usable call-time segments. This
  /// keeps enrollment fast while still avoiding a one-sample voiceprint.
  static const int _enrollmentTargetCallTime = 3;

  // ── DTMF keypad ───────────────────────────────────────────────────────────
  bool _dtmfOpen = false;

  // ── VoIP audio debug counters (updated by _callTimer every second) ──────
  int _voipSentChunks = 0;
  int _voipRecvChunks = 0;

  // ── Hang-up guard ─────────────────────────────────────────────────────────
  bool _endCallCalled = false;
  bool _answeringCall = false;

  // ── VoIP ICE candidate buffering ──────────────────────────────────────────
  // Caller ICE candidates can arrive while the phone is still ringing, before
  // the callee's peer connection exists. Buffer them and flush after
  // createAnswer so the connection path can be established reliably.
  final List<RTCIceCandidate> _earlyRemoteCandidates = [];
  bool _peerReady = false;

  // ── Outgoing VoIP: ICE candidates that fire before call_created ───────────
  // The caller's own ICE candidates may fire before the server sends back the
  // roomId (call_created). Buffer them and flush once the roomId is known.
  final List<Map<String, dynamic>> _pendingCallerCandidates = [];
  bool _callerRoomKnown = false;
  bool _callerAnswerApplied = false;

  // ── Proximity wake lock ───────────────────────────────────────────────────
  bool _proximityAcquired = false;

  // ── Cached service references (safe to use in dispose) ───────────────────
  late CellularCallService _cellular;
  late WebRTCService _webrtc;
  late SignalingService _signaling;

  // ── Helpers ───────────────────────────────────────────────────────────────
  String? get _voipRoomId => widget.voipRoomId ?? _signaling.currentRoomId;
  String? get _voipTargetId => widget.voipCallerId ?? widget.contactNumber;
  // Always verify/enroll the remote contact by their name, regardless of call
  // type. VoIP now records the remote party via WebRTC OUTPUT channel, so the
  // enrolled voiceprint should match the remote caller, not the local user.
  String get _verificationContactId => widget.contactName;

  // ─────────────────────────────────────────────────────────────────────────
  @override
  void initState() {
    super.initState();
    _verificationService = context.read<VerificationService>();
    _cellular = context.read<CellularCallService>();
    _webrtc = context.read<WebRTCService>();
    _signaling = context.read<SignalingService>();
    // Clear the previous call's verification result once the first frame is
    // painted. Calling resetResult() directly in initState() triggers
    // notifyListeners() while Provider consumers may still be building
    // (Navigator push animation), which can cause a setState-during-build
    // assertion that silently kills the InCallScreen.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _verificationService.resetResult();
    });

    if (widget.isVoIP) {
      _wireVoIPHangupListener();
      if (widget.isIncoming && widget.voipOffer != null) {
        // Start buffering the caller's ICE candidates immediately — they begin
        // arriving during the ringing phase, before the user taps Answer.
        _wireVoIPIceReceiver();
        _startRingtone();
      } else {
        // Outgoing VoIP call: create offer and send to callee.
        _setupVoIPConnectionListener();
        unawaited(_makeVoIPCall());
      }
    } else {
      _cellular.addListener(_onCellularStateChanged);
      _cellular.onCallActive = _markCallActive;
      if (_cellular.callState == CellularCallState.active) {
        _markCallActive();
      }
    }
  }

  // ── Cellular: state-change listener ──────────────────────────────────────

  void _onCellularStateChanged() {
    if (!mounted || _endCallCalled) return;
    final state = _cellular.callState;
    if (state == CellularCallState.idle || state == CellularCallState.ended) {
      _endCallFromRemote();
    }
  }

  // ── Ringtone (VoIP incoming) ──────────────────────────────────────────────

  Future<void> _startRingtone() async => _cellular.playRingtone();

  Future<void> _stopRingtone() async => _cellular.stopRingtone();

  // ── VoIP: remote hang-up / rejection ─────────────────────────────────────

  void _wireVoIPHangupListener() {
    _signaling.onVerificationResult = _handleRemoteVerificationResult;
    _signaling.onCallEnded = (data) {
      if (!_endCallCalled) _endCallFromRemote();
    };
    _signaling.onCallRejected = (data) {
      if (!_endCallCalled) _endCallFromRemote();
    };
  }

  void _handleRemoteVerificationResult(Map<String, dynamic> data) {
    if (!mounted || !widget.isVoIP) return;
    final roomId = data['roomId'] as String?;
    if (roomId != null && _voipRoomId != null && roomId != _voipRoomId) return;
    final raw = data['result'];
    if (raw is! Map) return;
    final resultJson = Map<String, dynamic>.from(raw);
    resultJson['contact_id'] = data['speakerId'] ?? resultJson['contact_id'];
    _verificationService.applyRemoteResult(resultJson);
    final result = VerificationResultModel.fromJson(resultJson);
    setState(() {
      _lastVerdict = result.verdict.name;
      _lastConfidence = result.confidence;
      _lastSimilarityScore = result.similarityScore;
      _lastSpoofProbability = result.spoofProbability;
      _lastSegmentsAnalyzed = result.segmentsAnalyzed;
      _lastVerificationMessage = result.message;
    });
    unawaited(_saveDetectionRecord(result));
    _showVerificationAlert(result);
  }

  Future<void> _endCallFromRemote() async {
    if (_endCallCalled) return;
    _endCallCalled = true;

    await _stopRingtone();
    _callTimer?.cancel();
    await _stopAllMonitoring();
    _releaseProximityWakeLock();

    if (widget.isVoIP) {
      await _webrtc.endCall();
    }

    if (!_callIsActive) {
      await _saveMissedCallRecord();
    } else {
      await _saveCallRecord();
    }

    if (mounted) _popOrEnroll();
  }

  // ── WebRTC connection listener ────────────────────────────────────────────

  void _setupVoIPConnectionListener() {
    _webrtc.addListener(_onWebRTCStateChanged);
    _onWebRTCStateChanged();
  }

  void _onWebRTCStateChanged() {
    if (!mounted) return;

    if (_webrtc.callState == CallState.active && !_callIsActive) {
      _markCallActive();
      return;
    }

    if (_webrtc.callState == CallState.ended && !_endCallCalled) {
      _endCallFromRemote();
      return;
    }

    if (_webrtc.callState == CallState.failed && !_endCallCalled) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('⚠️ Connection failed — network issue or firewall'),
        backgroundColor: AppColors.danger,
        duration: Duration(seconds: 5),
      ));
      Future.delayed(const Duration(seconds: 3), () {
        if (mounted && !_endCallCalled) _endCall();
      });
    }
  }

  // ── Call lifecycle ────────────────────────────────────────────────────────

  void _markCallActive() {
    if (!mounted || _callIsActive) return;
    setState(() {
      _callIsActive = true;
      _callStartTime = DateTime.now();
    });
    _startTimer();
    if (widget.isVoIP) unawaited(_startVoipRelay());
    _startMonitoring();
    _acquireProximityWakeLock();
  }

  Future<void> _startVoipRelay() async {
    final roomId = _voipRoomId;
    final targetId = _voipTargetId;
    if (roomId == null || roomId.isEmpty || targetId == null || targetId.isEmpty) {
      debugPrint('VoipRelay: cannot start — roomId or targetId missing');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('⚠️ Call routing failed — please hang up and retry'),
          backgroundColor: AppColors.danger,
          duration: Duration(seconds: 5),
        ));
      }
      return;
    }
    // Request audio focus before starting flutter_sound's AudioTrack.
    await _webrtc.reapplyAudioMode();
    await Future.delayed(const Duration(milliseconds: 150));
    _relay = VoipRelayService();
    _webrtc.setRelay(_relay!);
    await _relay!.start(roomId, targetId, _signaling);

    // Use a live closure so _segmentHandler is read at segment-delivery time,
    // not at relay-init time. This eliminates the race where _startMonitoring()
    // hasn't finished its /enroll/status/ network call yet when the relay
    // initialises, which caused _segmentHandler to be null and all remote-audio
    // segments to be silently discarded (onRemoteSegmentReady guard in relay).
    _relay!.onRemoteSegmentReady = (path) async {
      await _segmentHandler?.call(path);
    };

    // Surface audio-hardware failures that the relay logs as debugPrint only.
    if (!_relay!.micActive || !_relay!.playerActive) {
      debugPrint(
        'VoipRelay: incomplete start — '
        'mic=${_relay!.micActive} player=${_relay!.playerActive}',
      );
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('⚠️ VoIP audio could not start — check microphone permission'),
          backgroundColor: AppColors.danger,
          duration: Duration(seconds: 5),
        ));
      }
    }
  }

  void _startTimer() {
    _callTimer ??= Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) return;
      setState(() {
        _callSeconds++;
        if (widget.isVoIP && _relay != null) {
          final (s, r) = _relay!.audioStats;
          _voipSentChunks = s;
          _voipRecvChunks = r;
        }
      });
    });
  }

  // ── Proximity wake lock ───────────────────────────────────────────────────

  Future<void> _acquireProximityWakeLock() async {
    if (_proximityAcquired) return;
    _proximityAcquired = true;
    await _cellular.acquireProximityWakeLock();
  }

  Future<void> _releaseProximityWakeLock() async {
    if (!_proximityAcquired) return;
    _proximityAcquired = false;
    await _cellular.releaseProximityWakeLock();
  }

  // ── Auto-enrollment + verification ────────────────────────────────────────

  Future<void> _startMonitoring() async {
    if (_isMonitoring) return;
    _verificationService.resetResult();

    final isEnrolled =
        await _verificationService.isEnrolled(_verificationContactId);
    debugPrint('InCall: START monitoring "${widget.contactName}" '
        '(isVoIP=${widget.isVoIP}, isEnrolled=$isEnrolled → '
        '${isEnrolled ? 'verify' : 'enroll'})');
    if (!mounted) return;
    setState(() {
      _isMonitoring = true;
      _enrollmentComplete = false;
    });

    // ── Build the segment handler ─────────────────────────────────────────
    // Both _audioCapture and _callRecorder route through _segmentHandler,
    // which keeps recording separate from enrollment/verification decisions.

    if (!isEnrolled) {
      // ── Auto-enrollment mode ────────────────────────────────────────────
      final target = _enrollmentTargetCallTime;
      final contactLabel = widget.contactName.isNotEmpty
          ? widget.contactName
          : widget.contactNumber;

      setState(() {
        _enrollmentMode = true;
        _captureHint = null;
        _enrollmentStatus = 'Capturing ${contactLabel}\'s voice (0/$target)…';
      });

      _segmentHandler = (filePath) async {
        if (!mounted || !_isMonitoring) return;

        // Discard the first 2 segments (10 s). The very start of a call has
        // the worst audio quality: AGC is still settling, jitter buffers are
        // filling, and the first utterance is often a short "Hello?" with more
        // silence than speech. Voiceprints built from these segments enroll
        // badly and then fail to match the same speaker later in the call.
        _enrollSkipCount++;
        if (_enrollSkipCount <= 2) {
          if (mounted) {
            setState(() {
              _enrollmentStatus =
                  'Waiting for call to stabilise (0/$target)…';
            });
          }
          return;
        }

        // The recorder deletes filePath once this callback returns.
        // Copy to a persistent temp file so earlier segments survive.
        try {
          final dir = await getTemporaryDirectory();
          final ext = filePath.endsWith('.mp4') ? '.mp4' : '.wav';
          final copy =
              '${dir.path}/vg_enroll_${DateTime.now().millisecondsSinceEpoch}$ext';
          await File(filePath).copy(copy);
          _enrollmentSegments.add(copy);
        } catch (e) {
          debugPrint('Auto-enroll: failed to copy segment: $e');
          return;
        }

        final count = _enrollmentSegments.length;

        if (count < target) {
          if (mounted) {
            setState(() {
              _captureHint = null; // audio is flowing — clear any stale hint
              _enrollmentStatus =
                  'Capturing ${contactLabel}\'s voice ($count/$target)…';
            });
          }
          return;
        }

        // Guard: if a previous enrollment call is still in flight (WavLM
        // inference + network), new segments arriving during that wait must
        // not fire a second concurrent enrollment call. Without this, each
        // segment above the target fires its own API request.
        if (_enrollmentInProgress) return;
        _enrollmentInProgress = true;

        if (mounted) {
          setState(() => _enrollmentStatus = 'Processing voice profile…');
        }

        // Call-time audio is lower quality than a quiet EnrollScreen recording;
        // signal that to the AI so it applies appropriate normalisation.
        final success = await _verificationService.enrollContact(
          contactId: _verificationContactId,
          audioPaths: List.from(_enrollmentSegments),
          sourceQuality: 'low',
        );
        _enrollmentInProgress = false;

        // Always clean up the persistent copies we made.
        for (final p in List<String>.from(_enrollmentSegments)) {
          try { File(p).deleteSync(); } catch (_) {}
        }
        _enrollmentSegments.clear();

        if (!mounted) return;

        if (success) {
          setState(() {
            _enrollmentMode = true;
            _enrollmentComplete = true;
            _captureHint = null;
            _enrollmentStatus =
                'Voice profile saved. Verification starts on your next call with $contactLabel.';
          });
          _persistEnrolledInHive();
          // Stop recording — we have what we need.  A small delay keeps the
          // success message visible before the UI settles.
          _segmentHandler = null;
          await Future.delayed(const Duration(seconds: 2));
          unawaited(_stopAllMonitoring());
        } else {
          // Backend rejected the segments (too short, too noisy, etc.).
          // Reset and try again with fresh segments this call.
          _enrollmentSegments.clear();
          _enrollSkipCount = 0;
          _enrollmentInProgress = false;
          if (mounted) {
            setState(() {
              _enrollmentComplete = false;
              _enrollmentStatus =
                  'Profile attempt failed — retrying ($contactLabel 0/$target)…';
            });
          }
        }
      };
    } else {
      // ── Verification mode ───────────────────────────────────────────────
      bool warmupDone = false;
      _segmentHandler = (filePath) async {
        if (_captureHint != null && mounted) {
          setState(() => _captureHint = null); // audio is flowing again
        }
        if (!warmupDone) {
          warmupDone = true;
          return;
        }
        await _verifySegment(filePath);
      };
    }

    // ── Route callbacks through _segmentHandler ───────────────────────────
    if (widget.isVoIP) {
      // Relay mode: remote audio comes via VoipRelayService.onRemoteSegmentReady,
      // wired in _startVoipRelay() once the relay is up. Nothing to start here —
      // _segmentHandler is already set above and the relay picks it up.
      debugPrint('VoipMonitor: segment handler ready, relay will wire it');
      return;
    }

    // ── Cellular: try ADB shell audio (VOICE_DOWNLINK) first ─────────────────
    // Shell audio captures the caller's receive path directly via UID 2000,
    // bypassing Android's hardware mic block (Pixel 6 / Android 12+ during
    // MODE_IN_CALL). No speaker setup needed — the downlink is digital.
    if (await _tryStartShellAudio()) return;

    // ── Cellular: fall back to standard mic recorder ──────────────────────────
    if (!isEnrolled) {
      await _prepareCallTimeEnrollmentAudio();
    } else {
      await _prepareCallTimeVerificationAudio();
    }

    _callRecorder.onSegmentReady = (f) async {
      await _segmentHandler?.call(f);
    };
    _callRecorder.onCaptureIssue = _onCaptureIssue;
    _callRecorder.onCaptureBlocked = _onCaptureBlocked;

    if (!isEnrolled) {
      // ── Enrollment: skip VOICE_RECOGNITION entirely ─────────────────────
      // VOICE_RECOGNITION returns silence on Android 12+ even with default
      // dialer permission, wasting 3 × 5 s before the MIC fallback fires.
      // For enrollment we need audio NOW, so start with MIC (+ speakerphone
      // already on from _prepareCallTimeEnrollmentAudio) immediately.
      // Mark _triedMicFallback so the issue handler doesn't restart again —
      // if MIC also fails the caller gets a persistent hint instead.
      _triedMicFallback = true;
      await _callRecorder.startMonitoring(
        segmentSeconds: 8,
        vadMode: VadMode.speech,
        audioSource: CallAudioRecorder.audioSourceMic,
      );
    } else {
      // ── Verification: VOICE_RECOGNITION + speakerphone ──────────────────
      // Speaker is pre-enabled by _prepareCallTimeVerificationAudio, so the
      // remote caller's voice is loud in the room. VOICE_RECOGNITION source
      // has AEC/AGC/NS disabled — it captures the speaker output cleanly.
      // VadMode.speech detects direct speech rather than subtle earpiece bleed.
      // If VOICE_RECOGNITION is silenced by the OS (Android 12+ restriction),
      // _onCaptureIssue will fall back to the MIC source the same way
      // enrollment does — speaker volume is high enough that some signal
      // survives AEC cancellation.
      await _callRecorder.startMonitoring(
        segmentSeconds: 8,
        vadMode: VadMode.speech,
      );
    }
  }

  /// Attempts to start ADB shell audio capture (VOICE_DOWNLINK via UID 2000).
  /// Returns `true` and sets [_usingShellAudio] if started successfully.
  /// Returns `false` to signal that the caller should fall back to [_callRecorder].
  Future<bool> _tryStartShellAudio() async {
    if (!await ShellAudioService.instance.isReady()) return false;

    ShellAudioService.instance.onSegmentReady = (f) async {
      await _segmentHandler?.call(f);
    };
    ShellAudioService.instance.onBlocked = () {
      if (mounted) _onCaptureBlocked('hardware_muted');
    };

    final started = await ShellAudioService.instance.startCapture();
    if (!started) {
      ShellAudioService.instance.onSegmentReady = null;
      ShellAudioService.instance.onBlocked = null;
      return false;
    }

    _usingShellAudio = true;
    debugPrint('InCall: shell audio active (VOICE_DOWNLINK via ADB UID 2000)');
    if (mounted) setState(() => _captureHint = null);
    return true;
  }

  // Stamps isEnrolled=true in the local Hive contacts box after successful
  // auto-enrollment during a call, so ContactsScreen shows the correct badge.
  void _persistEnrolledInHive() {
    try {
      final box = Hive.box('contacts');
      final normalized =
          widget.contactNumber.replaceAll(RegExp(r'\D'), '');
      for (final key in box.keys) {
        final raw = box.get(key);
        if (raw == null) continue;
        final map = Map<String, dynamic>.from(raw as Map);
        final storedNum = ((map['phoneNumber'] as String?) ?? '')
            .replaceAll(RegExp(r'\D'), '');
        if ((normalized.isNotEmpty && storedNum == normalized) ||
            map['name'] == widget.contactName) {
          map['isEnrolled'] = true;
          map['enrolledAt'] = DateTime.now().toIso8601String();
          box.put(key, map);
          return;
        }
      }
    } catch (e) {
      debugPrint('Auto-enroll: Hive persist failed: $e');
    }
  }

  Future<void> _prepareCallTimeEnrollmentAudio() async {
    if (!mounted) return;
    if (widget.isVoIP) {
      // VoIP relay provides clean remote PCM directly — no speaker change needed.
      setState(() => _captureHint =
          'Listening to ${widget.contactName}\'s voice — building profile automatically.');
      return;
    }
    // Cellular: enforce loudspeaker so the remote caller's voice plays loud
    // enough for VOICE_RECOGNITION (AEC off) to capture it cleanly.
    // forceSpeakerOn() verifies the hardware route via Telecom, not just the
    // Dart flag, and retries up to 3× to survive Telecom audio-route resets.
    if (mounted) {
      setState(() => _captureHint =
          'Enabling speaker for voice capture…');
    }
    try {
      await _cellular.forceSpeakerOn();
    } catch (e) {
      debugPrint('InCall: forceSpeakerOn failed: $e');
    }
    if (mounted) {
      setState(() => _captureHint =
          'Speaker on — stay quiet so VoiceGuard can hear ${widget.contactName}.');
    }
  }

  Future<void> _prepareCallTimeVerificationAudio() async {
    if (!mounted) return;
    if (widget.isVoIP) {
      setState(() => _captureHint = null);
      return;
    }
    // Cellular: same speaker enforcement as enrollment — the hardware must
    // actually be routing to the loudspeaker before the recorder starts.
    if (mounted) {
      setState(() => _captureHint = 'Enabling speaker for voice verification…');
    }
    try {
      await _cellular.forceSpeakerOn();
    } catch (e) {
      debugPrint('InCall: forceSpeakerOn (verify) failed: $e');
    }
    if (mounted) {
      setState(() => _captureHint =
          'Speaker on — VoiceGuard is listening to ${widget.contactName}.');
    }
  }

  /// Called when a recorder reports it can't capture usable remote-caller
  /// audio. For VoIP the OUTPUT channel may not be ready yet. For cellular,
  /// VOICE_RECOGNITION can return silence on Android 12+ even for the default
  /// dialer — so we retry with the MIC source (speakerphone routes the caller's
  /// voice directly to the mic, bypassing the Android restriction).
  void _onCaptureIssue(String reason) {
    if (!mounted || !_isMonitoring) return;
    if (widget.isVoIP) {
      // VoIP OUTPUT recorder failed — WebRTC connection not ready or peer hung up.
      _verificationService.showCaptureIssue(
          'WebRTC audio unavailable — VoiceGuard will retry when the call audio starts.');
      setState(() => _captureHint = 'Waiting for call audio to stabilise…');
      return;
    }

    // ── Cellular ─────────────────────────────────────────────────────────────
    final contactLabel = widget.contactName.isNotEmpty
        ? widget.contactName
        : widget.contactNumber;

    if (!_cellular.isSpeakerOn) {
      // Speaker was turned off mid-call (user manually disabled it).
      // Re-enforce it — VoiceGuard cannot capture without speakerphone.
      _verificationService.showCaptureIssue(
          'Speaker must stay on for VoiceGuard to hear the caller.');
      setState(() => _captureHint = 'Re-enabling speaker for voice capture…');
      // forceSpeakerOn confirms the hardware route, not just the Dart flag.
      unawaited(_cellular.forceSpeakerOn().then((_) {
        if (mounted) {
          setState(() => _captureHint =
              'Speaker restored — listening to $contactLabel.');
        }
      }));
      return;
    }

    // Speaker is ON but VOICE_RECOGNITION returned silence.
    // On Android 12–13, the OS silences VOICE_RECOGNITION during calls even
    // for the default dialer.  Retry with MIC — at high speaker volumes a
    // meaningful signal survives AEC cancellation.
    if (!_triedMicFallback) {
      _triedMicFallback = true;
      debugPrint('InCall: VOICE_RECOGNITION silent — retrying with MIC source');
      unawaited(_callRecorder.restartWithAudioSource(
        CallAudioRecorder.audioSourceMic,
        vadMode: VadMode.speech,
      ));
      if (mounted) setState(() => _captureHint = null);
      return;
    }

    // Both sources exhausted — show a contextual, non-blocking hint.
    if (_enrollmentMode && !_enrollmentComplete) {
      _verificationService.showCaptureIssue(
          'No speech detected. Ask $contactLabel to speak — the profile needs ~15 s of audio.');
      setState(() => _captureHint =
          'Ask $contactLabel to keep talking — building voice profile.');
    } else {
      _verificationService.showCaptureIssue(
          'Audio capture limited on this device. Keep phone on speaker for best results.');
      setState(() =>
          _captureHint = 'Keep phone on speaker — VoiceGuard is listening.');
    }
  }

  /// Called when [CallAudioRecorder] detects that ALL PCM samples are zero —
  /// the telephony HAL is silencing the mic at OS level (Pixel 6 / Android 12+
  /// during MODE_IN_CALL).  No source switch or retry can bypass this.
  ///
  /// For unenrolled contacts we set a flag so [_popOrEnroll] navigates to
  /// [EnrollScreen] after the call ends, letting the user record the contact's
  /// voice while the mic is free.
  void _onCaptureBlocked(String reason) {
    if (!mounted || !_isMonitoring) return;
    _hardwareAudioBlocked = true;

    final contactLabel = widget.contactName.isNotEmpty
        ? widget.contactName
        : widget.contactNumber;

    if (_enrollmentMode && !_enrollmentComplete) {
      setState(() => _captureHint =
          'Mic blocked by Android during cellular calls on this device. '
          'You\'ll be taken to enroll $contactLabel after the call.');
    } else {
      setState(() => _captureHint =
          'Mic blocked by Android during cellular calls on this device. '
          'Verification unavailable for this call.');
    }
  }

  /// After a call ends, navigate to [EnrollScreen] when the mic was blocked and
  /// the contact is still unenrolled.  Otherwise just pop back to the caller.
  void _popOrEnroll() {
    if (!mounted) return;
    if (_hardwareAudioBlocked && _enrollmentMode && !_enrollmentComplete && !widget.isVoIP) {
      final contact = ContactModel(
        id: widget.contactNumber.isNotEmpty
            ? widget.contactNumber
            : widget.contactName,
        name: widget.contactName.isNotEmpty ? widget.contactName : 'Unknown',
        phoneNumber: widget.contactNumber,
      );
      Navigator.pushReplacement(
        context,
        MaterialPageRoute(builder: (_) => EnrollScreen(contact: contact)),
      );
      return;
    }
    Navigator.pop(context);
  }

  /// One-tap action on the capture hint: enable speakerphone so the remote
  /// caller's voice is loud in the mic and VAD has something to extract.
  Future<void> _enableSpeakerForCapture() async {
    try {
      if (widget.isVoIP) {
        // VoIP verification is sent from each phone's own microphone, so no
        // speaker routing change is needed here.
      } else {
        if (!_cellular.isSpeakerOn) await _cellular.toggleSpeaker();
      }
    } catch (e) {
      debugPrint('InCall: enable speaker failed: $e');
    }
    if (mounted) setState(() => _captureHint = null);
  }

  Future<void> _verifySegment(String filePath) async {
    if (!mounted || !_isMonitoring) return;
    // VoIP OUTPUT gives clean full-quality remote audio — treat as 'high'.
    // Cellular VAD-extracted earpiece bleed is lower quality — treat as 'low'.
    final quality = widget.isVoIP ? 'high' : 'low';
    final source = widget.isVoIP ? 'voip_output_channel' : 'cellular_remote_vad';
    final result = await _verificationService.verifyAudioFile(
      contactId: widget.contactName,
      audioFilePath: filePath,
      sourceQuality: quality,
      audioRole: 'remote_speaker',
      mediaSource: source,
    );
    if (result != null && mounted) {
      setState(() {
        _lastVerdict = result.verdict.name;
        _lastConfidence = result.confidence;
        _lastSimilarityScore = result.similarityScore;
        _lastSpoofProbability = result.spoofProbability;
        _lastSegmentsAnalyzed = result.segmentsAnalyzed;
        _lastVerificationMessage = result.message;
      });
      await _saveDetectionRecord(result);
      _showVerificationAlert(result);
    }
  }

  /// Writes a single detection record for the whole call — the *settled* verdict
  /// from [VerificationService], not a per-segment ruling. Called once from
  /// _stopAllMonitoring(); the guard makes repeat end-of-call paths idempotent.
  ///
  /// Only a committed verdict is saved. If the call never gathered enough
  /// consistent evidence (still "Checking…"), nothing is written — we don't
  /// record a guess.
  Future<void> _saveDetectionRecord(VerificationResultModel result) async {
    // Only persist a committed flag (Real / Not real). Transient and uncertain
    // segments are shown live as "Checking…" but never written to history, so
    // the list stays a clean binary.
    if (result.verdict != VerificationVerdict.verified &&
        result.verdict != VerificationVerdict.verifiedHigh &&
        result.verdict != VerificationVerdict.notVerified &&
        result.verdict != VerificationVerdict.spoofDetected) {
      return;
    }
    try {
      final box = Hive.box('detection_history');
      final id = '${DateTime.now().millisecondsSinceEpoch}_${box.length}';
      await box.put(id, {
        'id': id,
        'contactName': widget.contactName,
        'contactNumber': widget.contactNumber,
        'callType': widget.isVoIP ? 'VoIP' : 'Cellular',
        'verdict': result.verdict.name,
        'confidence': result.confidence,
        'similarityScore': result.similarityScore,
        'displayConfidence': result.displayConfidence,
        'spoofProbability': result.spoofProbability,
        'secondarySimilarityScore': result.secondarySimilarityScore,
        'secondaryAvailable': result.secondaryAvailable,
        'secondaryMatched': result.secondaryMatched,
        'audioRole': result.audioRole,
        'mediaSource': result.mediaSource,
        'segmentsAnalyzed': result.segmentsAnalyzed,
        'message': result.message,
        'timestamp': result.timestamp.toIso8601String(),
      });
    } catch (e) {
      debugPrint('Detection history save error: $e');
    }
  }

  void _showVerificationAlert(VerificationResultModel result) {
    if (!mounted || _lastAlertVerdict == result.verdict) return;
    if (result.verdict == VerificationVerdict.uncertain ||
        result.verdict == VerificationVerdict.notEnrolled) {
      return;
    }

    _lastAlertVerdict = result.verdict;

    late final String message;
    late final Color color;

    switch (result.verdict) {
      case VerificationVerdict.verifiedHigh:
      case VerificationVerdict.verified:
        message = 'Speaker authenticated';
        color = AppColors.verified;
        break;
      case VerificationVerdict.spoofDetected:
        message = 'Fake or spoofed voice detected';
        color = AppColors.danger;
        break;
      case VerificationVerdict.spoofSuspected:
        message = 'Possible spoof detected; gathering more evidence';
        color = AppColors.warning;
        break;
      case VerificationVerdict.notVerified:
        message = 'Speaker is not verified';
        color = AppColors.warning;
        break;
      case VerificationVerdict.secondaryWarning:
        message = 'Secondary model disagrees with primary match';
        color = AppColors.warning;
        break;
      default:
        return;
    }

    HapticFeedback.heavyImpact();
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text('$message (${result.confidencePercent}%)'),
      backgroundColor: color,
      behavior: SnackBarBehavior.floating,
      duration: const Duration(seconds: 4),
    ));
  }

  // ── End call ──────────────────────────────────────────────────────────────

  Future<void> _stopAllMonitoring() async {
    _isMonitoring = false;
    _monitoringWatchdog?.cancel();
    _monitoringWatchdog = null;
    _segmentHandler = null;
    await _relay?.stop();
    _relay = null;
    await _voipRecorder.stopMonitoring();
    if (_usingShellAudio) {
      await ShellAudioService.instance.stopCapture();
      _usingShellAudio = false;
    }
    await _callRecorder.stopMonitoring();
  }

  void _notifyVoipCallEnded() {
    if (!widget.isVoIP) return;
    final roomId = _voipRoomId;
    final targetId = _voipTargetId;
    if (roomId != null && roomId.isNotEmpty && targetId != null && targetId.isNotEmpty) {
      _signaling.endCall(roomId: roomId, targetUserId: targetId);
    }
  }

  Future<void> _endCall() async {
    if (_endCallCalled) return;
    _endCallCalled = true;

    _callTimer?.cancel();
    await _stopAllMonitoring();
    _releaseProximityWakeLock();

    if (widget.isVoIP) {
      _notifyVoipCallEnded();
      await _webrtc.endCall();
    } else {
      await _cellular.endCall();
    }

    await _saveCallRecord();
    if (mounted) _popOrEnroll();
  }

  // ── Call history ──────────────────────────────────────────────────────────

  Future<void> _saveCallRecord() async {
    if (!_callIsActive) return;
    try {
      final box = Hive.box('call_history');
      final id = DateTime.now().millisecondsSinceEpoch.toString();
      await box.put(id, {
        'id': id,
        'contactName': widget.contactName,
        'contactNumber': widget.contactNumber,
        'callType': widget.isVoIP ? 'voip' : 'cellular',
        'direction': widget.isIncoming ? 'incoming' : 'outgoing',
        'startTime': (_callStartTime ?? DateTime.now()).toIso8601String(),
        'duration': _callSeconds,
        'verificationVerdict': _lastVerdict,
        'verificationConfidence': _lastConfidence,
        'similarityScore': _lastSimilarityScore,
        'spoofProbability': _lastSpoofProbability,
        'segmentsAnalyzed': _lastSegmentsAnalyzed,
        'verificationMessage': _lastVerificationMessage,
        'spoofDetected': _lastVerdict == 'spoofDetected',
      });
    } catch (e) {
      debugPrint('History save error: $e');
    }
  }

  Future<void> _saveMissedCallRecord() async {
    if (!widget.isIncoming) return;
    try {
      final box = Hive.box('call_history');
      final id = DateTime.now().millisecondsSinceEpoch.toString();
      await box.put(id, {
        'id': id,
        'contactName': widget.contactName,
        'contactNumber': widget.contactNumber,
        'callType': widget.isVoIP ? 'voip' : 'cellular',
        'direction': 'missed',
        'startTime': DateTime.now().toIso8601String(),
        'duration': null,
        'verificationVerdict': null,
        'verificationConfidence': null,
        'similarityScore': null,
        'spoofProbability': null,
        'segmentsAnalyzed': null,
        'verificationMessage': null,
        'spoofDetected': false,
      });
    } catch (e) {
      debugPrint('Missed-call history save error: $e');
    }
  }

  // ── VoIP outgoing call ────────────────────────────────────────────────────

  Future<void> _makeVoIPCall() async {
    if (!mounted) return;

    // Wire caller → callee ICE candidates.
    // The roomId from call_created may not be known yet when the first
    // candidates fire — buffer them and flush in onCallCreated.
    _webrtc.onIceCandidate = (candidate) {
      final payload = {
        'candidate': candidate.candidate,
        'sdpMid': candidate.sdpMid,
        'sdpMLineIndex': candidate.sdpMLineIndex,
      };
      final roomId = _voipRoomId;
      if (_callerRoomKnown && roomId != null && roomId.isNotEmpty) {
        _signaling.sendIceCandidate(
          roomId: roomId,
          targetUserId: _voipTargetId!,
          candidate: payload,
        );
      } else {
        _pendingCallerCandidates.add(payload);
      }
    };

    // Wire callee → caller ICE candidates.
    _wireVoIPIceReceiver();

    // When callee answers: set remote description and flush buffered candidates.
    _signaling.onCallAnswered = (data) async {
      if (_callerAnswerApplied) {
        debugPrint('VoIP: duplicate call_answered ignored');
        return;
      }
      final answer = data['answer'];
      if (answer == null) return;
      _callerAnswerApplied = true;
      _signaling.cancelCallTimeout();
      try {
        await _webrtc.setRemoteAnswer(RTCSessionDescription(
          answer['sdp'] as String? ?? '',
          answer['type'] as String? ?? 'answer',
        ));
        _peerReady = true;
        for (final c in List<RTCIceCandidate>.from(_earlyRemoteCandidates)) {
          await _webrtc.addIceCandidate(c);
        }
        _earlyRemoteCandidates.clear();
      } catch (e) {
        debugPrint('VoIP: failed to apply answer: $e');
        _callerAnswerApplied = false;
      }
    };

    // When server assigns a roomId, flush buffered ICE candidates to callee.
    _signaling.onCallCreated = (roomId) {
      _callerRoomKnown = true;
      final targetId = _voipTargetId;
      if (targetId == null || targetId.isEmpty) return;
      for (final payload
          in List<Map<String, dynamic>>.from(_pendingCallerCandidates)) {
        _signaling.sendIceCandidate(
          roomId: roomId,
          targetUserId: targetId,
          candidate: payload,
        );
      }
      _pendingCallerCandidates.clear();
    };

    // Timeout if callee doesn't answer within 30 s.
    _signaling.onCallTimeout = () {
      if (mounted && !_endCallCalled) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('Call not answered'),
          backgroundColor: AppColors.danger,
          duration: Duration(seconds: 3),
        ));
        unawaited(_endCall());
      }
    };
    _signaling.startCallTimeout();

    try {
      final offer = await _webrtc.createOffer();
      if (!mounted) return;
      _signaling.callUser(
        calleeId: _voipTargetId!,
        callerId: _signaling.userId ?? '',
        offer: {'sdp': offer.sdp, 'type': offer.type},
      );
    } catch (e) {
      debugPrint('VoIP outgoing call error: $e');
      if (mounted && !_endCallCalled) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('Failed to initiate VoIP call'),
          backgroundColor: AppColors.danger,
          duration: Duration(seconds: 3),
        ));
        unawaited(_endCall());
      }
    }
  }

  // ── VoIP answer / reject ──────────────────────────────────────────────────

  Future<void> _answerCall() async {
    if (_answeringCall || _endCallCalled) return;
    _answeringCall = true;
    await _stopRingtone();
    try {
      if (widget.isVoIP) {
        await _answerVoIPCall();
      } else {
        await _cellular.acceptCall();
        if (!mounted) return;
        _markCallActive();
      }
    } catch (e) {
      debugPrint('Answer call error: $e');
      if (mounted && !_endCallCalled) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('Could not answer call. Please try again.'),
          backgroundColor: AppColors.danger,
          duration: Duration(seconds: 3),
        ));
      }
      _answeringCall = false;
    }
  }

  /// Wire the handler that receives the caller's ICE candidates. Candidates
  /// that arrive before the peer connection is ready (during ringing or while
  /// createAnswer is running) are buffered and flushed once it is ready.
  void _wireVoIPIceReceiver() {
    _signaling.onIceCandidate = (data) async {
      final c = data['candidate'];
      if (c == null) return;
      final candidate = RTCIceCandidate(
        c['candidate'] as String?,
        c['sdpMid'] as String?,
        c['sdpMLineIndex'] as int?,
      );
      if (_peerReady) {
        await _webrtc.addIceCandidate(candidate);
      } else {
        _earlyRemoteCandidates.add(candidate);
      }
    };
  }

  Future<void> _answerVoIPCall() async {
    if (widget.voipOffer == null || widget.voipRoomId == null) return;

    // Wire the local→remote ICE sender BEFORE createAnswer. createAnswer calls
    // setLocalDescription, which starts ICE gathering immediately; if this
    // callback isn't set yet, the callee's early candidates are lost and the
    // connection can silently fail to establish.
    _webrtc.onIceCandidate = (candidate) {
      _signaling.sendIceCandidate(
        roomId: widget.voipRoomId!,
        targetUserId: widget.voipCallerId!,
        candidate: {
          'candidate': candidate.candidate,
          'sdpMid': candidate.sdpMid,
          'sdpMLineIndex': candidate.sdpMLineIndex,
        },
      );
    };

    // Make sure the remote-candidate receiver is wired (normally set in
    // initState during ringing; set again defensively here).
    _wireVoIPIceReceiver();

    final sdp = widget.voipOffer!['sdp'] as String? ?? '';
    final type = widget.voipOffer!['type'] as String? ?? 'offer';
    final offer = RTCSessionDescription(sdp, type);
    final answer = await _webrtc.createAnswer(offer);

    // Peer connection now exists and the remote description is set — it is safe
    // to add candidates directly. Flush everything buffered while ringing.
    _peerReady = true;
    for (final candidate in List<RTCIceCandidate>.from(_earlyRemoteCandidates)) {
      await _webrtc.addIceCandidate(candidate);
    }
    _earlyRemoteCandidates.clear();

    _signaling.answerCall(
      roomId: widget.voipRoomId!,
      callerId: widget.voipCallerId!,
      answer: {'sdp': answer.sdp, 'type': answer.type},
    );

    _setupVoIPConnectionListener();
  }

  Future<void> _rejectCall() async {
    await _stopRingtone();
    await _saveMissedCallRecord();
    if (widget.isVoIP) {
      _signaling.rejectCall(
        roomId: widget.voipRoomId ?? '',
        callerId: widget.voipCallerId ?? '',
      );
    } else {
      await _cellular.rejectCall();
    }
    if (mounted) Navigator.pop(context);
  }

  // ── DTMF ─────────────────────────────────────────────────────────────────

  Future<void> _sendDtmf(String digit) async {
    HapticFeedback.lightImpact();
    if (widget.isVoIP) {
      await _webrtc.sendDtmf(digit);
    } else {
      await _cellular.sendDtmf(digit);
    }
  }

  // ── UI helpers ────────────────────────────────────────────────────────────

  String get _callStatusText {
    if (_enrollmentMode) return _enrollmentStatus;
    if (_callIsActive) return _formattedDuration;
    if (widget.isIncoming) return 'Incoming call…';
    return 'Calling…';
  }

  String get _formattedDuration {
    final m = _callSeconds ~/ 60;
    final s = _callSeconds % 60;
    return '${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';
  }

  // ── Build ─────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final verificationService = context.watch<VerificationService>();

    return Scaffold(
      backgroundColor: AppColors.background,
      resizeToAvoidBottomInset: false,
      body: SafeArea(
        child: Column(
          children: [
            const SizedBox(height: 40),

            // Call type badge
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
              decoration: BoxDecoration(
                color: widget.isVoIP
                    ? AppColors.primary.withValues(alpha: 0.2)
                    : AppColors.secondary.withValues(alpha: 0.2),
                borderRadius: BorderRadius.circular(20),
              ),
              child: Text(
                widget.isVoIP ? '📡 VoIP Call' : '📞 Cellular Call',
                style: TextStyle(
                  color:
                      widget.isVoIP ? AppColors.primary : AppColors.secondary,
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),

            const SizedBox(height: 24),

            // Avatar
            CircleAvatar(
              radius: 50,
              backgroundColor: AppColors.primary.withValues(alpha: 0.2),
              child: Text(
                widget.contactName.isNotEmpty
                    ? widget.contactName[0].toUpperCase()
                    : '?',
                style: const TextStyle(
                  fontSize: 40,
                  color: AppColors.primary,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),

            const SizedBox(height: 16),

            Text(
              widget.contactName,
              style: const TextStyle(
                fontSize: 26,
                fontWeight: FontWeight.bold,
                color: Colors.white,
              ),
            ),

            const SizedBox(height: 4),

            Text(
              _callStatusText,
              style: TextStyle(
                fontSize: 14,
                color: _enrollmentMode ? AppColors.primary : Colors.white54,
                fontWeight:
                    _enrollmentMode ? FontWeight.w600 : FontWeight.normal,
              ),
            ),

            // VoIP audio flow indicator — shows chunks sent and received so
            // both sides can confirm their mics are working without logcat.
            if (widget.isVoIP && _callIsActive) ...[
              const SizedBox(height: 4),
              Text(
                '↑ $_voipSentChunks  ↓ $_voipRecvChunks',
                style: const TextStyle(fontSize: 10, color: Colors.white24),
              ),
            ],

            // Enrollment progress bar
            if (_enrollmentMode) ...[
              const SizedBox(height: 8),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 48),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(4),
                  child: LinearProgressIndicator(
                    value: _enrollmentComplete
                        ? 1
                        : _enrollmentTargetCallTime > 0
                            ? (_enrollmentSegments.length /
                                    _enrollmentTargetCallTime)
                                .clamp(0.0, 1.0)
                            : 0,
                    minHeight: 4,
                    backgroundColor: Colors.white10,
                    color: AppColors.primary,
                  ),
                ),
              ),
            ],

            // Capture hint — shown when the recorder can't hear the caller.
            if (_captureHint != null && !_enrollmentComplete) ...[
              const SizedBox(height: 10),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 24),
                child: Material(
                  color: _hardwareAudioBlocked
                      ? AppColors.danger.withValues(alpha: 0.12)
                      : AppColors.warning.withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(10),
                  child: InkWell(
                    borderRadius: BorderRadius.circular(10),
                    onTap: _hardwareAudioBlocked ? null : _enableSpeakerForCapture,
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 12, vertical: 8),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            _hardwareAudioBlocked
                                ? Icons.mic_off
                                : Icons.volume_up,
                            size: 16,
                            color: _hardwareAudioBlocked
                                ? AppColors.danger
                                : AppColors.warning,
                          ),
                          const SizedBox(width: 8),
                          Flexible(
                            child: Text(
                              _captureHint!,
                              style: TextStyle(
                                fontSize: 12,
                                color: _hardwareAudioBlocked
                                    ? AppColors.danger
                                    : AppColors.warning,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ],

            // Cellular signal-quality notice (shown once call is active)
            if (!widget.isVoIP && _callIsActive && !_enrollmentMode && !_usingShellAudio) ...[
              const SizedBox(height: 6),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 24),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: const [
                    Icon(Icons.info_outline, size: 12, color: Colors.white24),
                    SizedBox(width: 4),
                    Text(
                      'Cellular verification uses earpiece audio — confidence may be lower',
                      style: TextStyle(fontSize: 10, color: Colors.white24),
                      textAlign: TextAlign.center,
                    ),
                  ],
                ),
              ),
            ],
            // Shell audio active indicator
            if (!widget.isVoIP && _callIsActive && _usingShellAudio) ...[
              const SizedBox(height: 6),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: const [
                  Icon(Icons.hd, size: 12, color: AppColors.verified),
                  SizedBox(width: 4),
                  Text(
                    'High-quality caller audio active',
                    style: TextStyle(fontSize: 10, color: AppColors.verified),
                  ),
                ],
              ),
            ],

            const SizedBox(height: 24),

            const VoiceWaveWidget(),
            const SizedBox(height: 24),

            // Verification overlay
            if (!_enrollmentMode) ...[
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 24),
                child: VerificationOverlayWidget(service: verificationService),
              ),
            ],

            const Spacer(),

            // DTMF keypad (slides in above the call controls)
            if (_dtmfOpen) _buildDtmfKeypad(),

            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 40),
              child: _buildCallControls(),
            ),

            const SizedBox(height: 48),
          ],
        ),
      ),
    );
  }

  // ── DTMF keypad widget ────────────────────────────────────────────────────

  Widget _buildDtmfKeypad() {
    const keys = [
      ['1', '2', '3'],
      ['4', '5', '6'],
      ['7', '8', '9'],
      ['*', '0', '#'],
    ];
    return Container(
      margin: const EdgeInsets.fromLTRB(24, 0, 24, 16),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        children: keys.map((row) {
          return Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: row.map((digit) {
                return GestureDetector(
                  onTap: () => _sendDtmf(digit),
                  child: Container(
                    width: 64,
                    height: 48,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: AppColors.cardBg,
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Text(
                      digit,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 22,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                );
              }).toList(),
            ),
          );
        }).toList(),
      ),
    );
  }

  // ── Call controls ─────────────────────────────────────────────────────────

  Widget _buildCallControls() {
    final cellular = context.watch<CellularCallService>();
    final webrtc = context.watch<WebRTCService>();

    final showVoIPRinging =
        widget.isVoIP && widget.isIncoming && !_callIsActive;
    final showCellularRinging = !widget.isVoIP &&
        widget.isIncoming &&
        cellular.callState == CellularCallState.ringing;

    // ── Ringing: Answer / Reject ───────────────────────────────────────────
    if (showVoIPRinging || showCellularRinging) {
      return Row(
        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
        children: [
          CallButtonWidget(
            icon: Icons.call_end,
            label: 'Reject',
            color: AppColors.callRed,
            size: 72,
            onTap: _rejectCall,
          ),
          CallButtonWidget(
            icon: Icons.call,
            label: 'Answer',
            color: AppColors.callGreen,
            size: 72,
            onTap: _answerCall,
          ),
        ],
      );
    }

    // ── Active call: Mute, End, Speaker, Keypad ────────────────────────────
    final isMuted = widget.isVoIP ? webrtc.isMuted : cellular.isMuted;
    final isSpeaker = widget.isVoIP ? webrtc.isSpeakerOn : cellular.isSpeakerOn;

    return Column(
      children: [
        // Top row: mute · end · speaker
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceEvenly,
          children: [
            CallButtonWidget(
              icon: isMuted ? Icons.mic_off : Icons.mic,
              label: isMuted ? 'Unmute' : 'Mute',
              isActive: isMuted,
              onTap: () =>
                  widget.isVoIP ? webrtc.toggleMute() : cellular.toggleMute(),
            ),
            CallButtonWidget(
              icon: Icons.call_end,
              label: 'End',
              color: AppColors.callRed,
              size: 72,
              onTap: _endCall,
            ),
            CallButtonWidget(
              icon: isSpeaker ? Icons.volume_up : Icons.volume_down,
              label: 'Speaker',
              isActive: isSpeaker,
              onTap: () async {
                if (widget.isVoIP) {
                  await webrtc.toggleSpeaker();
                } else {
                  await cellular.toggleSpeaker();
                }
              },
            ),
          ],
        ),

        // Bottom row: keypad toggle (only during active call)
        if (_callIsActive) ...[
          const SizedBox(height: 12),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              CallButtonWidget(
                icon: Icons.dialpad,
                label: _dtmfOpen ? 'Hide' : 'Keypad',
                isActive: _dtmfOpen,
                onTap: () => setState(() => _dtmfOpen = !_dtmfOpen),
              ),
            ],
          ),
        ],
      ],
    );
  }

  // ── Dispose ───────────────────────────────────────────────────────────────

  @override
  void dispose() {
    if (!_endCallCalled) {
      _notifyVoipCallEnded();
    }
    _callTimer?.cancel();
    _monitoringWatchdog?.cancel();
    _segmentHandler = null;
    _isMonitoring = false;
    _voipRecorder.dispose(); // VoIP OUTPUT channel cleanup
    _callRecorder.dispose(); // cellular native recording cleanup
    _releaseProximityWakeLock();
    _cellular.stopRingtone();

    _relay?.dispose();
    _relay = null;

    // Clean up any auto-enrollment segment copies if the call ended before
    // enrollment finished collecting its target number of samples.
    for (final p in List<String>.from(_enrollmentSegments)) {
      try { File(p).deleteSync(); } catch (_) {}
    }
    _enrollmentSegments.clear();
    _earlyRemoteCandidates.clear();
    if (widget.isVoIP) {
      _webrtc.removeListener(_onWebRTCStateChanged);
      _signaling.onCallEnded = null;
      _signaling.onCallRejected = null;
      _signaling.onIceCandidate = null;
      _signaling.onVerificationResult = null;
      _signaling.onCallAnswered = null;
      _signaling.onCallCreated = null;
      _signaling.onCallTimeout = null;
      _signaling.cancelCallTimeout();
    } else {
      _cellular.onCallActive = null;
      _cellular.removeListener(_onCellularStateChanged);
    }
    super.dispose();
  }
}
