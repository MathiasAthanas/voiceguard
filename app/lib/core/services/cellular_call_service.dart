import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/contact_model.dart';

enum CellularCallState { idle, dialing, ringing, active, ended }

class CellularCallService extends ChangeNotifier {
  static const MethodChannel _channel = MethodChannel('com.voiceguard/calls');
  static const EventChannel _eventChannel =
      EventChannel('com.voiceguard/call_state');

  CellularCallState _callState = CellularCallState.idle;
  String? _currentNumber;
  String? _currentContactName;
  bool _isSpeakerOn = false;
  bool _isMuted = false;

  // ── Deduplication guards ───────────────────────────────────────────────────
  // These prevent double-firing when both InCallService events (call_ended +
  // call_state_changed:disconnected) arrive for the same call end.
  bool _callEndedFired = false;
  bool _incomingCallFired = false;

  // ── Callbacks ──────────────────────────────────────────────────────────────
  Function(String number, String? contactName)? onIncomingCall;
  Function()? onCallActive;
  Function()? onCallEnded;

  CellularCallState get callState => _callState;
  String? get currentNumber => _currentNumber;
  String? get currentContactName => _currentContactName;
  bool get isSpeakerOn => _isSpeakerOn;
  bool get isMuted => _isMuted;
  bool get isInCall => _callState == CellularCallState.active;

  CellularCallService() {
    _listenToCallEvents();
  }

  void _listenToCallEvents() {
    _eventChannel.receiveBroadcastStream().listen(
      (event) async {
        final data = Map<String, dynamic>.from(event as Map);
        final eventType = data['event'] as String?;
        final callData = Map<String, String>.from(data['data'] as Map? ?? {});

        switch (eventType) {
          case 'call_state_changed':
            await _handleStateChange(
              callData['state'] ?? '',
              callData['number'] ?? '',
            );
            break;

          case 'call_ended':
            // Guard: don't double-fire if _handleStateChange already ended the call
            if (!_callEndedFired) {
              _callEndedFired = true;
              _resetCallState();
              onCallEnded?.call();
              notifyListeners();
            }
            break;
        }
      },
      onError: (e) => debugPrint('CellularCallService event error: $e'),
    );
  }

  Future<void> _handleStateChange(String state, String number) async {
    switch (state) {
      case 'dialing':
      case 'connecting':
        _incomingCallFired = false; // reset for next call
        _callEndedFired = false;
        _currentNumber = number;
        _currentContactName = await findContactName(number);
        _callState = CellularCallState.dialing;
        break;

      case 'ringing':
        // Guard: fire onIncomingCall only ONCE per incoming call.
        // Some devices/networks can briefly cycle through ringing state
        // more than once before settling.
        _callEndedFired = false;
        if (!_incomingCallFired) {
          _incomingCallFired = true;
          _currentNumber = number;
          _currentContactName = await findContactName(number);
          _callState = CellularCallState.ringing;
          onIncomingCall?.call(number, _currentContactName);
        }
        break;

      case 'active':
        _callState = CellularCallState.active;
        onCallActive?.call();
        break;

      case 'holding':
        _callState =
            CellularCallState.active; // treat hold as still-active for UI
        break;

      case 'disconnected':
      case 'ended':
        if (!_callEndedFired) {
          _callEndedFired = true;
          _resetCallState();
          onCallEnded?.call();
        }
        break;

      // 'unknown' and other states — ignore
      default:
        break;
    }

    notifyListeners();
  }

  void _resetCallState() {
    _callState = CellularCallState.idle;
    _currentNumber = null;
    _currentContactName = null;
    _isSpeakerOn = false;
    _isMuted = false;
    _incomingCallFired = false;
  }

  // ── Public API ─────────────────────────────────────────────────────────────

  Future<void> makeCall(String phoneNumber) async {
    try {
      _callEndedFired = false;
      _incomingCallFired = false;
      _currentNumber = phoneNumber;
      _currentContactName = await findContactName(phoneNumber);
      _callState = CellularCallState.dialing;
      notifyListeners();
      await _channel.invokeMethod('makeCall', {'number': phoneNumber});
    } on PlatformException catch (e) {
      debugPrint('Make call error: ${e.message}');
      _resetCallState();
      notifyListeners();
    }
  }

  Future<void> acceptCall() async {
    try {
      await _channel.invokeMethod('acceptCall');
      _callState = CellularCallState.active;
      onCallActive?.call();
      notifyListeners();
    } on PlatformException catch (e) {
      debugPrint('Accept call error: ${e.message}');
    }
  }

  Future<void> rejectCall() async {
    try {
      await _channel.invokeMethod('rejectCall');
      _callEndedFired =
          true; // we triggered it — suppress native event duplicate
      _resetCallState();
      onCallEnded?.call();
      notifyListeners();
    } on PlatformException catch (e) {
      debugPrint('Reject call error: ${e.message}');
    }
  }

  Future<void> endCall() async {
    try {
      await _channel.invokeMethod('endCall');
    } on PlatformException catch (e) {
      debugPrint('End call error: ${e.message}');
    } finally {
      // Always reset state so the next call isn't blocked by a stale dialing/
      // active state (e.g. when a VoiceGuardInCallService instance is null).
      _callEndedFired = true;
      _resetCallState();
      notifyListeners();
    }
  }

  Future<void> toggleSpeaker() async {
    _isSpeakerOn = !_isSpeakerOn;
    try {
      await _channel.invokeMethod('toggleSpeaker', {'enabled': _isSpeakerOn});
    } on PlatformException catch (e) {
      _isSpeakerOn = !_isSpeakerOn; // revert on failure
      debugPrint('Speaker toggle error: ${e.message}');
    }
    notifyListeners();
  }

  Future<void> toggleMute() async {
    _isMuted = !_isMuted;
    try {
      await _channel.invokeMethod('toggleMute', {'muted': _isMuted});
    } on PlatformException catch (e) {
      _isMuted = !_isMuted; // revert on failure
      debugPrint('Mute toggle error: ${e.message}');
    }
    notifyListeners();
  }

  /// Send a DTMF digit on the active cellular call.
  Future<void> sendDtmf(String digit) async {
    try {
      await _channel.invokeMethod('sendDtmf', {'digit': digit});
    } on PlatformException catch (e) {
      debugPrint('DTMF error: ${e.message}');
    }
  }

  /// Show a high-priority native notification for an incoming VoIP call.
  /// This fires the full-screen intent and wakes the screen when locked —
  /// bridging the gap that VoIP calls don't go through TelecomManager.
  Future<void> showVoipCallNotification(String callerId) async {
    try {
      await _channel
          .invokeMethod('showVoipCallNotification', {'callerId': callerId});
    } on PlatformException catch (e) {
      debugPrint('showVoipCallNotification error: ${e.message}');
    }
  }

  /// Dismiss the VoIP incoming-call notification (call answered or rejected).
  Future<void> dismissVoipCallNotification() async {
    try {
      await _channel.invokeMethod('dismissVoipCallNotification');
    } on PlatformException catch (e) {
      debugPrint('dismissVoipCallNotification error: ${e.message}');
    }
  }

  /// Play the device's default ringtone (for incoming VoIP calls).
  Future<void> playRingtone() async {
    try {
      await _channel.invokeMethod('playRingtone');
    } on PlatformException catch (e) {
      debugPrint('playRingtone error: ${e.message}');
    }
  }

  Future<void> stopRingtone() async {
    try {
      await _channel.invokeMethod('stopRingtone');
    } on PlatformException catch (e) {
      debugPrint('stopRingtone error: ${e.message}');
    }
  }

  Future<bool> isDefaultDialer() async {
    try {
      return await _channel.invokeMethod<bool>('isDefaultDialer') ?? false;
    } on PlatformException {
      return false;
    }
  }

  Future<void> requestDefaultDialer() async {
    try {
      await _channel.invokeMethod('requestDefaultDialer');
    } on PlatformException catch (e) {
      debugPrint('Request default dialer error: ${e.message}');
    }
  }

  /// Acquire the proximity wake lock (screen off when phone near ear).
  Future<void> acquireProximityWakeLock() async {
    try {
      await _channel.invokeMethod('acquireProximityWakeLock');
    } on PlatformException catch (e) {
      debugPrint('Proximity acquire error: ${e.message}');
    }
  }

  /// Release the proximity wake lock.
  Future<void> releaseProximityWakeLock() async {
    try {
      await _channel.invokeMethod('releaseProximityWakeLock');
    } on PlatformException catch (e) {
      debugPrint('Proximity release error: ${e.message}');
    }
  }

  Future<List<ContactModel>> getDeviceContacts() async {
    try {
      final result = await _channel.invokeMethod<List<dynamic>>('getContacts');
      return (result ?? [])
          .map((item) {
            final map = Map<String, dynamic>.from(item as Map);
            return ContactModel(
              id: (map['id'] as String?)?.isNotEmpty == true
                  ? map['id'] as String
                  : map['phoneNumber'] as String,
              name: map['name'] as String? ?? 'Unknown',
              phoneNumber: map['phoneNumber'] as String? ?? '',
            );
          })
          .where((c) => c.phoneNumber.isNotEmpty)
          .toList();
    } on PlatformException catch (e) {
      debugPrint('Contacts load error: ${e.message}');
      return [];
    }
  }

  Future<bool> saveDeviceContact({
    required String name,
    required String phoneNumber,
    String? alternatePhoneNumber,
    String? email,
    String? notes,
    String phoneLabel = 'Mobile',
  }) async {
    try {
      return await _channel.invokeMethod<bool>('saveContact', {
            'name': name,
            'phoneNumber': phoneNumber,
            'alternatePhoneNumber': alternatePhoneNumber,
            'email': email,
            'notes': notes,
            'phoneLabel': phoneLabel,
          }) ??
          false;
    } on PlatformException catch (e) {
      debugPrint('Save contact error: ${e.message}');
      return false;
    }
  }

  Future<bool> openNativeContactInsert({
    required String name,
    required String phoneNumber,
    String? alternatePhoneNumber,
    String? email,
    String? notes,
  }) async {
    try {
      return await _channel.invokeMethod<bool>('openNativeContactInsert', {
            'name': name,
            'phoneNumber': phoneNumber,
            'alternatePhoneNumber': alternatePhoneNumber,
            'email': email,
            'notes': notes,
          }) ??
          false;
    } on PlatformException catch (e) {
      debugPrint('Open native contact insert error: ${e.message}');
      return false;
    }
  }

  Future<String?> findContactName(String phoneNumber) async {
    if (phoneNumber.isEmpty || phoneNumber == 'Unknown') return null;
    try {
      return await _channel.invokeMethod<String>(
        'findContactName',
        {'number': phoneNumber},
      );
    } on PlatformException {
      return null;
    }
  }
}
