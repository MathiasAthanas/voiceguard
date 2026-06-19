import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart'
    show RTCIceCandidate, RTCSessionDescription;

import 'voip_relay_service.dart';

enum CallState { idle, calling, ringing, active, failed, ended }

/// VoIP call service — relay mode.
///
/// Audio travels through the signaling server (phone → server → phone) instead
/// of a direct WebRTC peer connection. This eliminates STUN/TURN/ICE entirely.
///
/// The public API is identical to the old WebRTC-backed version so
/// InCallScreen requires minimal changes.
class WebRTCService extends ChangeNotifier {
  static const _channel = MethodChannel('com.voiceguard/calls');

  CallState _callState = CallState.idle;
  bool _isMuted = false;
  bool _isSpeakerOn = true;
  bool _ending = false;

  VoipRelayService? _relay;

  /// No-op in relay mode — ICE candidates are never generated.
  Function(RTCIceCandidate)? onIceCandidate;

  CallState get callState => _callState;
  bool get isMuted => _isMuted;
  bool get isSpeakerOn => _isSpeakerOn;
  bool get isInCall => _callState == CallState.active;

  /// Called by InCallScreen once the relay service is ready, so that
  /// toggleMute / toggleSpeaker are forwarded correctly.
  void setRelay(VoipRelayService relay) {
    _relay = relay;
  }

  // ── Call lifecycle ─────────────────────────────────────────────────────────

  /// Returns a stub offer SDP. No peer connection is created.
  Future<RTCSessionDescription> createOffer() async {
    _ending = false;
    _setCallState(CallState.calling);
    return RTCSessionDescription('relay://v1', 'offer');
  }

  /// Returns a stub answer SDP and transitions to active after a short delay
  /// (gives InCallScreen time to wire _setupVoIPConnectionListener first).
  Future<RTCSessionDescription> createAnswer(RTCSessionDescription offer) async {
    _ending = false;
    _setCallState(CallState.ringing);
    Future.delayed(const Duration(milliseconds: 300), () {
      if (!_ending) _setCallState(CallState.active);
    });
    return RTCSessionDescription('relay://v1', 'answer');
  }

  /// Caller side — transitions to active immediately (listener already wired).
  Future<void> setRemoteAnswer(RTCSessionDescription answer) async {
    if (_ending) return;
    _setCallState(CallState.active);
  }

  /// No-op — relay mode has no ICE negotiation.
  Future<void> addIceCandidate(RTCIceCandidate candidate) async {}

  Future<void> reapplyAudioMode() async {
    await _setNativeSpeaker(_isSpeakerOn);
  }

  void toggleMute() {
    _isMuted = !_isMuted;
    _relay?.setMuted(_isMuted);
    notifyListeners();
  }

  Future<void> toggleSpeaker() async {
    _isSpeakerOn = !_isSpeakerOn;
    _relay?.setSpeaker(_isSpeakerOn);
    await _setNativeSpeaker(_isSpeakerOn);
    notifyListeners();
  }

  /// DTMF is not available in relay mode.
  Future<void> sendDtmf(String digit) async {
    debugPrint('WebRTC relay: DTMF not supported');
  }

  Future<void> endCall({bool clearCallbacks = true}) async {
    _ending = true;
    _setCallState(CallState.ended);
    if (clearCallbacks) onIceCandidate = null;
    _relay = null;
    await _setNativeSpeaker(false);
    _isMuted = false;
    _isSpeakerOn = true;
    _ending = false;
    _setCallState(CallState.idle);
  }

  // ── Audio routing ──────────────────────────────────────────────────────────

  Future<void> _setNativeSpeaker(bool enabled) async {
    // Helper.setSpeakerphoneOn is intentionally NOT called here.
    // In relay mode we have no WebRTC peer connection, and calling flutter_webrtc's
    // AudioManager initialiser right before _startMic() locks the Android audio
    // session so that AudioRecord fails to open on the caller's phone.
    // All routing is handled by the native setVoipSpeaker channel call below.
    try {
      await _channel.invokeMethod('setVoipSpeaker', {'enabled': enabled});
    } catch (e) {
      debugPrint('setVoipSpeaker native error: $e');
    }
  }

  void _setCallState(CallState state) {
    if (_callState == state) return;
    _callState = state;
    notifyListeners();
  }

  @override
  void dispose() {
    _relay = null;
    super.dispose();
  }
}
