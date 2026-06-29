import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_sound/flutter_sound.dart';
import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart';

import 'signaling_service.dart';

/// Routes VoIP audio through the signaling server instead of a direct
/// WebRTC peer connection. Both phones stream raw PCM16 chunks via the
/// existing WebSocket channel; the server relays them to the remote party.
///
/// Audio format: 16 kHz, mono, 16-bit signed PCM (matches the AI backend).
class VoipRelayService {
  final AudioRecorder _recorder = AudioRecorder();
  final FlutterSoundPlayer _player = FlutterSoundPlayer();

  StreamSubscription<Uint8List>? _micSubscription;
  final List<Uint8List> _prePlayerQueue = <Uint8List>[];
  bool _playerReady = false;
  bool _isMuted = false;
  bool _isActive = false;
  int _sentChunks = 0;
  int _receivedChunks = 0;

  SignalingService? _signaling;
  String _targetUserId = '';

  // ── Remote audio segment recording (for enrollment / verification) ─────────
  /// Called with the path to each completed 5-second WAV of the remote caller.
  /// The file is deleted automatically after the callback returns.
  Future<void> Function(String wavPath)? onRemoteSegmentReady;

  final List<Uint8List> _segChunks = [];
  int _segBytes = 0;
  // 5 s @ 16 kHz, mono, 16-bit = 160 000 bytes
  static const int _segTargetBytes = 16000 * 2 * 5;

  bool get isActive => _isActive;
  bool get micActive => _micSubscription != null;
  bool get playerActive => _playerReady;

  /// Live counters — read from the UI every second to verify both ends are
  /// sending and receiving without needing logcat.
  (int sent, int received) get audioStats => (_sentChunks, _receivedChunks);

  Future<void> start(
    String roomId,
    String targetUserId,
    SignalingService signaling,
  ) async {
    if (_isActive) return;
    _signaling = signaling;
    _targetUserId = targetUserId;
    _isActive = true;

    // Mic opens AudioRecord before flutter_sound opens AudioTrack.
    // Reversing this order causes the caller's AudioRecord init to race
    // against an AudioTrack that just locked the session — mic fails silently.
    await _startMic(signaling, roomId);
    await _startPlayer(signaling, roomId);
  }

  Future<void> _startPlayer(SignalingService signaling, String roomId) async {
    // Wire the audio handler BEFORE opening the player so that chunks arriving
    // during player initialisation (~80 ms) are captured in _prePlayerQueue
    // instead of being silently dropped. _playPcmChunk routes to the queue
    // when !_playerReady and flushes it once the player signals ready.
    signaling.onAudioChunk = (event) {
      if (!_isActive) return;
      if (event['senderUserId'] == signaling.userId) return;
      final data = event['data'] as String?;
      if (data == null || data.isEmpty) return;
      try {
        final bytes = base64Decode(data);
        _receivedChunks++;
        if (_receivedChunks == 1 || _receivedChunks % 50 == 0) {
          debugPrint(
            'VoipRelay: received audio chunks=$_receivedChunks '
            'bytes=${bytes.length} from=${event['senderUserId'] ?? 'unknown'}',
          );
        }
        _playPcmChunk(Uint8List.fromList(bytes));
      } catch (e) {
        debugPrint('VoipRelay: decode error: $e');
      }
    };

    try {
      await _player.openPlayer();
      await _player.startPlayerFromStream(
        codec: Codec.pcm16,
        numChannels: 1,
        sampleRate: 16000,
        bufferSize: 1024,
        interleaved: true,
      );
      // Let the Android AudioTrack initialise before live data is pushed.
      await Future.delayed(const Duration(milliseconds: 80));
      _playerReady = true;
      _flushPrePlayerQueue();
      debugPrint('VoipRelay: player ready');
    } catch (e) {
      debugPrint('VoipRelay: player setup error: $e');
    }
  }

  void _playPcmChunk(Uint8List bytes) {
    if (!_isActive || bytes.isEmpty) return;

    final safeBytes = bytes.length.isOdd
        ? Uint8List.sublistView(bytes, 0, bytes.length - 1)
        : bytes;
    if (safeBytes.isEmpty) return;

    if (!_playerReady || _player.uint8ListSink == null) {
      _prePlayerQueue.add(safeBytes);
      while (_prePlayerQueue.length > 12) {
        _prePlayerQueue.removeAt(0);
      }
    } else {
      try {
        _player.uint8ListSink!.add(safeBytes);
      } catch (e) {
        debugPrint('VoipRelay: sink feed error: $e');
      }
    }

    // Buffer for enrollment / verification segments regardless of player state.
    _onRemoteChunk(safeBytes);
  }

  void _flushPrePlayerQueue() {
    if (!_isActive || !_playerReady || _player.uint8ListSink == null) {
      _prePlayerQueue.clear();
      return;
    }
    final queued = List<Uint8List>.from(_prePlayerQueue);
    _prePlayerQueue.clear();
    for (final bytes in queued) {
      _playPcmChunk(bytes);
    }
  }

  Future<void> _startMic(SignalingService signaling, String roomId) async {
    final senderUserId = signaling.userId ?? '';
    try {
      if (!await _recorder.hasPermission()) {
        debugPrint('VoipRelay: mic permission denied');
        return;
      }
      final stream = await _recorder.startStream(
        const RecordConfig(
          encoder: AudioEncoder.pcm16bits,
          sampleRate: 16000,
          numChannels: 1,
          // Disable DSP post-processing — it removes the remote caller's voice
          // (AEC) and the AI backend handles noise reduction itself.
          echoCancel: false,
          noiseSuppress: false,
          autoGain: false,
          // AudioInterruptionMode.none tells record_android to skip the
          // AUDIOFOCUS_GAIN_TRANSIENT_EXCLUSIVE request and register no
          // OnAudioFocusChangeListener. Without this, FlutterSoundPlayer
          // opening its AudioTrack dispatches AUDIOFOCUS_LOSS(-1) to the
          // record plugin, which pauses/stops the mic stream — silencing
          // the local user for the rest of the call on both ends.
          // The native setVoipSpeakerphone() already holds AUDIOFOCUS_GAIN
          // for the session so the audio session is still properly owned.
          audioInterruption: AudioInterruptionMode.none,
        ),
      );
      _micSubscription = stream.listen(
        (chunk) {
          if (!_isActive || _isMuted) return;
          _sentChunks++;
          if (_sentChunks == 1 || _sentChunks % 50 == 0) {
            debugPrint(
              'VoipRelay: sent audio chunks=$_sentChunks '
              'bytes=${chunk.length} to=$_targetUserId',
            );
          }
          signaling.sendAudioChunk(
            roomId: roomId,
            senderUserId: senderUserId,
            targetUserId: _targetUserId,
            data: base64Encode(chunk),
          );
        },
        onError: (e) => debugPrint('VoipRelay: mic error: $e'),
        cancelOnError: false,
      );
      debugPrint('VoipRelay: mic streaming started (userId=$senderUserId)');
    } catch (e) {
      debugPrint('VoipRelay: mic start error: $e');
    }
  }

  // ── Remote segment recording ───────────────────────────────────────────────

  void _onRemoteChunk(Uint8List bytes) {
    if (onRemoteSegmentReady == null) return;
    _segChunks.add(bytes);
    _segBytes += bytes.length;
    if (_segBytes >= _segTargetBytes) _flushSegment();
  }

  void _flushSegment() {
    // Combine queued chunks into one buffer.
    final combined = Uint8List(_segBytes);
    int pos = 0;
    for (final c in _segChunks) {
      combined.setRange(pos, pos + c.length, c);
      pos += c.length;
    }
    _segChunks.clear();
    _segBytes = 0;

    final pcm = Uint8List.fromList(combined.sublist(0, _segTargetBytes));

    // Keep any overflow for the next segment.
    if (combined.length > _segTargetBytes) {
      final overflow = Uint8List.fromList(combined.sublist(_segTargetBytes));
      _segChunks.add(overflow);
      _segBytes = overflow.length;
    }

    unawaited(_emitSegment(pcm));
  }

  Future<void> _emitSegment(Uint8List pcm) async {
    String? path;
    try {
      final dir = await getTemporaryDirectory();
      path = '${dir.path}/vg_relay_${DateTime.now().millisecondsSinceEpoch}.wav';
      await File(path).writeAsBytes(_buildWav(pcm));
      await onRemoteSegmentReady?.call(path);
    } catch (e) {
      debugPrint('VoipRelay: segment error: $e');
    } finally {
      if (path != null) {
        try { File(path).deleteSync(); } catch (_) {}
      }
    }
  }

  static Uint8List _buildWav(Uint8List pcm) {
    const sampleRate = 16000;
    final dataLen = pcm.length;
    final bd = ByteData(44 + dataLen);
    void s4(int o, int v) => bd.setUint32(o, v, Endian.little);
    void s2(int o, int v) => bd.setUint16(o, v, Endian.little);
    void tag(int o, String s) {
      for (var i = 0; i < s.length; i++) bd.setUint8(o + i, s.codeUnitAt(i));
    }
    tag(0, 'RIFF'); s4(4, 36 + dataLen); tag(8, 'WAVE');
    tag(12, 'fmt '); s4(16, 16); s2(20, 1); s2(22, 1);
    s4(24, sampleRate); s4(28, sampleRate * 2); s2(32, 2); s2(34, 16);
    tag(36, 'data'); s4(40, dataLen);
    bd.buffer.asUint8List().setRange(44, 44 + dataLen, pcm);
    return bd.buffer.asUint8List();
  }

  // ──────────────────────────────────────────────────────────────────────────

  Future<void> stop() async {
    if (!_isActive) return;
    _isActive = false;

    // Clear the callback and ready-flag *before* touching the player so the
    // FeedThread cannot receive a new feedFromStream call while we are in the
    // process of releasing the AudioTrack. Reversing this order is the root
    // cause of the SIGSEGV null-pointer crash in AudioTrack::releaseBuffer.
    final wasReady = _playerReady;
    _playerReady = false;
    _prePlayerQueue.clear();
    _segChunks.clear();
    _segBytes = 0;
    onRemoteSegmentReady = null;
    _signaling?.onAudioChunk = null;
    _signaling = null;
    _targetUserId = '';
    _sentChunks = 0;
    _receivedChunks = 0;

    await _micSubscription?.cancel();
    _micSubscription = null;
    try {
      await _recorder.stop();
    } catch (e) {
      debugPrint('VoipRelay: recorder stop error: $e');
    }

    if (wasReady) {
      // Give the FeedThread ~100 ms to finish any write that was already in
      // flight before we release the AudioTrack underneath it.
      await Future.delayed(const Duration(milliseconds: 100));
      try {
        await _player.stopPlayer();
      } catch (e) {
        debugPrint('VoipRelay: player stop error: $e');
      }
      try {
        await _player.closePlayer();
      } catch (e) {
        debugPrint('VoipRelay: player close error: $e');
      }
    }

    debugPrint('VoipRelay: stopped');
  }

  void setMuted(bool muted) {
    _isMuted = muted;
    debugPrint('VoipRelay: muted=$muted');
  }

  // Speaker routing is handled by the native channel via WebRTCService.
  void setSpeaker(bool speaker) {}

  void dispose() {
    unawaited(stop());
    _recorder.dispose();
  }
}
