import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/widgets.dart';

import '../constants/app_constants.dart';

enum SignalingState { disconnected, connecting, connected }

enum _SignalingTransport { none, websocket, polling }

class SignalingService extends ChangeNotifier with WidgetsBindingObserver {
  WebSocket? _webSocket;
  Dio? _dio;
  SignalingState _state = SignalingState.disconnected;
  _SignalingTransport _transport = _SignalingTransport.none;
  String? _userId;
  List<String> _onlineUsers = [];
  String? _currentRoomId;
  bool _intentionalDisconnect = false;
  bool _polling = false;
  bool _wsConnecting = false;
  bool _connectInProgress = false;

  Timer? _callTimeoutTimer;
  Timer? _reconnectTimer;
  Timer? _heartbeatTimer;
  int _pollErrors = 0;
  int _reconnectAttempts = 0;
  final Set<String> _recentEventKeys = <String>{};
  final List<String> _recentEventOrder = <String>[];

  static const Duration _callTimeout = Duration(seconds: 30);
  static const Duration _webSocketConnectTimeout = Duration(seconds: 15);

  // Exponential backoff: 2 s → 5 s → 15 s → 30 s (capped)
  static const List<Duration> _reconnectDelays = [
    Duration(seconds: 2),
    Duration(seconds: 5),
    Duration(seconds: 15),
    Duration(seconds: 30),
  ];

  Function(Map<String, dynamic>)? onIncomingCall;
  Function(Map<String, dynamic>)? onCallAnswered;
  Function(Map<String, dynamic>)? onCallRejected;
  Function(Map<String, dynamic>)? onCallEnded;
  Function(Map<String, dynamic>)? onIceCandidate;
  Function(Map<String, dynamic>)? onVerificationResult;
  Function(Map<String, dynamic>)? onAudioChunk;
  Function(List<String>)? onUserListUpdated;
  Function(String roomId)? onCallCreated;
  Function(String reason)? onCallFailed;
  VoidCallback? onCallTimeout;

  SignalingState get state => _state;
  bool get isConnected => _state == SignalingState.connected;
  List<String> get onlineUsers => _onlineUsers;
  String? get userId => _userId;
  String? get currentRoomId => _currentRoomId;

  void connect(String userId) {
    if (_userId == userId && _state == SignalingState.connected) return;
    if (_userId == userId && _state == SignalingState.connecting) return;

    if (_userId != null && _userId != userId) {
      disconnect();
    }

    _userId = userId;
    _intentionalDisconnect = false;
    _reconnectAttempts = 0;
    _reconnectTimer?.cancel();
    WidgetsBinding.instance.addObserver(this);
    unawaited(_connect());
  }

  // ── App lifecycle — reconnect when app resumes from background ────────────

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) return;
    if (_intentionalDisconnect || _userId == null) return;

    if (_state != SignalingState.connected) {
      debugPrint('Signaling: app resumed while disconnected — reconnecting');
      _reconnectTimer?.cancel();
      _reconnectAttempts = 0;
      unawaited(_connect());
    } else {
      // Re-sync user list in case it drifted while the app was backgrounded
      _requestUserList();
    }
  }

  Future<void> _connect() async {
    if (_connectInProgress) return;
    _connectInProgress = true;
    _disposeTransport();

    _state = SignalingState.connecting;
    notifyListeners();

    try {
      final signalingUrl = _normalizeBaseUrl(AppConstants.signalingServerUrl);
      debugPrint('Signaling: connecting to $signalingUrl');

      final connectedByWebSocket = await _connectWebSocket(signalingUrl);
      if (connectedByWebSocket || _intentionalDisconnect || _userId == null) {
        return;
      }

      debugPrint(
          'Signaling: websocket unavailable, falling back to HTTP polling');
      await _connectPolling(signalingUrl);
    } finally {
      _connectInProgress = false;
    }
  }

  Future<bool> _connectWebSocket(String baseUrl) async {
    final userId = _userId;
    if (userId == null) return false;

    _wsConnecting = true;
    try {
      final wsUrl = _webSocketUrl(baseUrl, userId);
      debugPrint('Signaling: websocket URL $wsUrl');
      final socket =
          await WebSocket.connect(wsUrl).timeout(_webSocketConnectTimeout);
      if (_intentionalDisconnect || _userId != userId) {
        await socket.close();
        return true;
      }

      _webSocket = socket;
      _transport = _SignalingTransport.websocket;
      _state = SignalingState.connected;
      _reconnectAttempts = 0;
      notifyListeners();
      debugPrint('Signaling: connected by websocket as $userId');

      socket.listen(
        (data) => _handleEvent(_decodeEvent(data)),
        onDone: () => _handleWebSocketClosed(socket),
        onError: (error) {
          debugPrint('Signaling: websocket error $error');
          _handleWebSocketClosed(socket);
        },
        cancelOnError: true,
      );

      _startHeartbeat();

      // Request user list after a short settle delay so both sides are registered
      Future.delayed(const Duration(milliseconds: 600), () {
        if (_transport == _SignalingTransport.websocket) _requestUserList();
      });

      return true;
    } catch (error) {
      debugPrint('Signaling: websocket connect failed $error');
      return false;
    } finally {
      _wsConnecting = false;
    }
  }

  Future<void> _connectPolling(String baseUrl) async {
    final userId = _userId;
    if (userId == null || _intentionalDisconnect) return;

    _dio = Dio(BaseOptions(
      baseUrl: '$baseUrl/signaling',
      connectTimeout: const Duration(seconds: 5),
      receiveTimeout: const Duration(seconds: 35),
      sendTimeout: const Duration(seconds: 10),
    ));

    try {
      await _dio!.post('/register', data: {'userId': userId});
      if (_intentionalDisconnect || _userId != userId) return;

      _transport = _SignalingTransport.polling;
      _state = SignalingState.connected;
      _polling = true;
      _pollErrors = 0;
      _reconnectAttempts = 0;
      notifyListeners();
      debugPrint('Signaling: connected by HTTP polling as $userId');
      unawaited(_pollLoop(userId));
    } catch (error) {
      if (_intentionalDisconnect) return;
      _state = SignalingState.disconnected;
      notifyListeners();
      debugPrint('Signaling: polling connect error $error');
      _scheduleReconnect();
    }
  }

  Future<void> _pollLoop(String userId) async {
    while (_polling && !_intentionalDisconnect && _userId == userId) {
      try {
        final response = await _dio?.get(
          '/events/$userId',
          queryParameters: {'timeout': 20},
        );
        final events = response?.data['events'] as List<dynamic>? ?? [];
        for (final event in events) {
          _handleEvent(_asMap(event));
        }
      } catch (error) {
        if (_intentionalDisconnect || _userId != userId) return;
        debugPrint('Signaling: polling error $error');
        _pollErrors++;
        if (_pollErrors >= 2) {
          _state = SignalingState.disconnected;
          _transport = _SignalingTransport.none;
          _polling = false;
          notifyListeners();
          _scheduleReconnect();
          return;
        }
        await Future.delayed(const Duration(seconds: 2));
      }
    }
  }

  void _handleWebSocketClosed(WebSocket socket) {
    if (_intentionalDisconnect || _transport != _SignalingTransport.websocket) {
      return;
    }
    if (!identical(_webSocket, socket)) {
      debugPrint('Signaling: stale websocket close ignored');
      return;
    }

    _state = SignalingState.disconnected;
    _transport = _SignalingTransport.none;
    _webSocket = null;
    notifyListeners();
    debugPrint('Signaling: websocket disconnected');
    _scheduleReconnect();
  }

  void _scheduleReconnect() {
    if (_intentionalDisconnect || _userId == null) return;
    if (_reconnectTimer?.isActive == true) return;
    final delay =
        _reconnectDelays[_reconnectAttempts.clamp(0, _reconnectDelays.length - 1)];
    _reconnectAttempts = min(_reconnectAttempts + 1, _reconnectDelays.length - 1);
    debugPrint('Signaling: reconnect in ${delay.inSeconds}s '
        '(attempt $_reconnectAttempts)');
    _reconnectTimer = Timer(delay, () {
      if (!_intentionalDisconnect && _userId != null) {
        unawaited(_connect());
      }
    });
  }

  // ── Heartbeat / keepalive ─────────────────────────────────────────────────

  void _startHeartbeat() {
    _heartbeatTimer?.cancel();
    // Send a ping every 25 s to keep the TCP connection alive through NAT/
    // Doze-mode network changes, and to detect silently-dead sockets early.
    _heartbeatTimer = Timer.periodic(const Duration(seconds: 25), (_) {
      if (_transport != _SignalingTransport.websocket) return;
      final socket = _webSocket;
      if (socket == null) {
        return;
      }
      try {
        socket.add(jsonEncode({'type': 'ping'}));
      } catch (e) {
        debugPrint('Signaling: heartbeat send error — $e');
        _handleWebSocketClosed(socket);
      }
    });
  }

  void _stopHeartbeat() {
    _heartbeatTimer?.cancel();
    _heartbeatTimer = null;
  }

  void _requestUserList() {
    if (_transport == _SignalingTransport.websocket) {
      try {
        _webSocket?.add(jsonEncode({'type': 'get_user_list'}));
      } catch (_) {}
    }
    // HTTP polling: user list arrives automatically with each /events poll
  }

  void startCallTimeout() {
    _callTimeoutTimer?.cancel();
    _callTimeoutTimer = Timer(_callTimeout, () {
      onCallTimeout?.call();
      onCallTimeout = null;
    });
  }

  void cancelCallTimeout() {
    _callTimeoutTimer?.cancel();
    _callTimeoutTimer = null;
    onCallTimeout = null;
  }

  void callUser({
    required String calleeId,
    required String callerId,
    required Map<String, dynamic> offer,
  }) {
    _send('call_user', {
      'calleeId': calleeId,
      'callerId': callerId,
      'offer': offer,
    });
  }

  void answerCall({
    required String roomId,
    required String callerId,
    required Map<String, dynamic> answer,
  }) {
    cancelCallTimeout();
    _send('answer_call', {
      'roomId': roomId,
      'callerId': callerId,
      'answer': answer,
    });
  }

  void rejectCall({required String roomId, required String callerId}) {
    _send('reject_call', {'roomId': roomId, 'callerId': callerId});
    if (_currentRoomId == roomId) _currentRoomId = null;
  }

  void endCall({required String roomId, required String targetUserId}) {
    cancelCallTimeout();
    _send('end_call', {'roomId': roomId, 'targetUserId': targetUserId});
    if (_currentRoomId == roomId) _currentRoomId = null;
  }

  void sendIceCandidate({
    required String roomId,
    required String targetUserId,
    required Map<String, dynamic> candidate,
  }) {
    _send('ice_candidate', {
      'roomId': roomId,
      'targetUserId': targetUserId,
      'candidate': candidate,
    });
  }

  void sendAudioChunk({
    required String roomId,
    required String senderUserId,
    required String targetUserId,
    required String data,
  }) {
    _send('audio_chunk', {
      'roomId': roomId,
      'senderUserId': senderUserId,
      'targetUserId': targetUserId,
      'data': data,
    });
  }

  void sendVerificationResult({
    required String roomId,
    required String targetUserId,
    required String speakerId,
    required Map<String, dynamic> result,
  }) {
    _send('verification_result', {
      'roomId': roomId,
      'targetUserId': targetUserId,
      'speakerId': speakerId,
      'result': result,
    });
  }

  void _send(String type, Map<String, dynamic> data) {
    final payload = {'type': type, ...data};

    if (_transport == _SignalingTransport.websocket) {
      _webSocket?.add(jsonEncode(payload));
      return;
    }

    if (_transport == _SignalingTransport.polling) {
      unawaited(_sendHttp(type, data));
    }
  }

  Future<void> _sendHttp(String type, Map<String, dynamic> data) async {
    final endpoint = switch (type) {
      'call_user' => '/call',
      'answer_call' => '/answer',
      'reject_call' => '/reject',
      'end_call' => '/end',
      'ice_candidate' => '/ice',
      'verification_result' => '/verification-result',
      'audio_chunk' => '/audio-chunk',
      _ => null,
    };
    if (endpoint == null) return;

    try {
      await _dio?.post(endpoint, data: data);
    } catch (error) {
      debugPrint('Signaling: HTTP send error $type $error');
    }
  }

  void _handleEvent(Map<String, dynamic> event) {
    final type = event['type'] as String?;
    if (_isDuplicateEvent(event)) return;
    switch (type) {
      case 'pong':
        // Heartbeat acknowledged — connection is alive.
        break;
      case 'registered':
        debugPrint(
            'Signaling: registered by ${event['transport'] ?? 'server'}');
        break;
      case 'incoming_call':
        onIncomingCall?.call(event);
        break;
      case 'call_answered':
        onCallAnswered?.call(event);
        break;
      case 'call_rejected':
        _currentRoomId = null;
        onCallRejected?.call(event);
        break;
      case 'call_ended':
        _currentRoomId = null;
        onCallEnded?.call(event);
        break;
      case 'ice_candidate':
        onIceCandidate?.call(event);
        break;
      case 'verification_result':
        onVerificationResult?.call(event);
        break;
      case 'audio_chunk':
        onAudioChunk?.call(event);
        break;
      case 'user_list':
        _onlineUsers = List<String>.from(event['users'] ?? []);
        onUserListUpdated?.call(_onlineUsers);
        notifyListeners();
        break;
      case 'call_created':
        _currentRoomId = event['roomId'] as String?;
        if (_currentRoomId != null) onCallCreated?.call(_currentRoomId!);
        break;
      case 'call_failed':
        _currentRoomId = null;
        cancelCallTimeout();
        onCallFailed?.call(event['reason'] as String? ?? 'Call failed');
        break;
    }
  }

  bool _isDuplicateEvent(Map<String, dynamic> event) {
    final type = event['type'] as String?;
    if (type == null || type == 'user_list' || type == 'pong' || type == 'audio_chunk') return false;

    final roomId = event['roomId']?.toString() ?? '';
    final candidate = event['candidate'];
    final candidateText = candidate is Map
        ? (candidate['candidate']?.toString() ?? '')
        : '';
    final key = switch (type) {
      'ice_candidate' => '$type|$roomId|$candidateText',
      'call_answered' => '$type|$roomId|${event['answer']}',
      'incoming_call' => '$type|$roomId|${event['callerId']}',
      'call_created' => '$type|$roomId',
      'call_rejected' => '$type|$roomId',
      'call_ended' => '$type|$roomId',
      'call_failed' => '$type|${event['reason']}',
      'verification_result' => '$type|$roomId|${event['speakerId']}|${event['result']}',
      _ => '$type|${event.toString()}',
    };

    if (_recentEventKeys.contains(key)) {
      debugPrint('Signaling: duplicate $type ignored');
      return true;
    }
    _recentEventKeys.add(key);
    _recentEventOrder.add(key);
    while (_recentEventOrder.length > 200) {
      final oldest = _recentEventOrder.removeAt(0);
      _recentEventKeys.remove(oldest);
    }
    return false;
  }

  Map<String, dynamic> _decodeEvent(dynamic data) {
    if (data is String) {
      try {
        return _asMap(jsonDecode(data));
      } catch (_) {
        return {};
      }
    }
    return _asMap(data);
  }

  Map<String, dynamic> _asMap(dynamic data) {
    if (data == null) return {};
    try {
      return Map<String, dynamic>.from(data as Map);
    } catch (_) {
      return {};
    }
  }

  String _normalizeBaseUrl(String raw) {
    final trimmed = raw.trim();
    return trimmed.endsWith('/')
        ? trimmed.substring(0, trimmed.length - 1)
        : trimmed;
  }

  String _webSocketUrl(String baseUrl, String userId) {
    final uri = Uri.parse(baseUrl);
    final scheme = uri.scheme == 'https' ? 'wss' : 'ws';
    final path = '${uri.path}/signaling/ws/${Uri.encodeComponent(userId)}'
        .replaceAll(RegExp(r'/+'), '/');
    return uri.replace(scheme: scheme, path: path, query: '').toString();
  }

  void disconnect() {
    _intentionalDisconnect = true;
    _reconnectTimer?.cancel();
    _callTimeoutTimer?.cancel();
    _stopHeartbeat();
    _recentEventKeys.clear();
    _recentEventOrder.clear();
    try {
      WidgetsBinding.instance.removeObserver(this);
    } catch (_) {}
    final userId = _userId;
    final dio = _dio;
    if (_transport == _SignalingTransport.polling && userId != null) {
      unawaited(_disconnectHttp(dio, userId));
    }
    _disposeTransport(resetConnecting: true);
    _state = SignalingState.disconnected;
    notifyListeners();
  }

  void _disposeTransport({bool resetConnecting = false}) {
    _stopHeartbeat();
    _polling = false;
    _transport = _SignalingTransport.none;
    _dio = null;
    if (resetConnecting) _connectInProgress = false;
    final socket = _webSocket;
    _webSocket = null;
    if (socket != null && !_wsConnecting) {
      unawaited(_closeWebSocket(socket));
    }
  }

  Future<void> _closeWebSocket(WebSocket socket) async {
    await socket.close();
  }

  Future<void> _disconnectHttp(Dio? dio, String userId) async {
    try {
      await dio?.post('/disconnect/$userId');
    } catch (_) {
      // The app is already disconnecting; this is only a best-effort cleanup.
    }
  }

  @override
  void dispose() {
    disconnect();
    super.dispose();
  }
}
