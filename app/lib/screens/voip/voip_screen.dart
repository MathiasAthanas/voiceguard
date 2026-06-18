import 'package:flutter/material.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:provider/provider.dart';
import '../../core/constants/app_colors.dart';
import '../../core/services/signaling_service.dart';
import '../../core/services/webrtc_service.dart';
import '../in_call/in_call_screen.dart';

class VoIPScreen extends StatefulWidget {
  const VoIPScreen({super.key});

  @override
  State<VoIPScreen> createState() => _VoIPScreenState();
}

class _VoIPScreenState extends State<VoIPScreen> {
  // Tracks which user we're currently trying to call so we can show a spinner
  // on that tile and block double-taps or simultaneous calls.
  String? _callingUserId;

  Future<void> _initiateVoIPCall(String calleeId) async {
    if (_callingUserId != null) return; // already calling

    final signaling = context.read<SignalingService>();
    final webrtc    = context.read<WebRTCService>();

    // Guard: don't call if already connected
    if (webrtc.callState != CallState.idle) {
      _showSnack('A call is already active', AppColors.warning);
      return;
    }

    if (!signaling.isConnected) {
      _showSnack('Not connected to signaling server', AppColors.danger);
      return;
    }

    // Request microphone permission before touching WebRTC
    final micStatus = await Permission.microphone.request();
    if (!mounted) return;
    if (!micStatus.isGranted) {
      _showSnack('Microphone permission is required for VoIP calls', AppColors.danger);
      return;
    }

    setState(() => _callingUserId = calleeId);

    try {
      // Wire ICE callback BEFORE createOffer — candidates start as soon as
      // setLocalDescription is called inside createOffer.
      webrtc.onIceCandidate = (candidate) {
        final roomId = signaling.currentRoomId;
        if (roomId == null) return;
        signaling.sendIceCandidate(
          roomId: roomId,
          targetUserId: calleeId,
          candidate: {
            'candidate':     candidate.candidate,
            'sdpMid':        candidate.sdpMid,
            'sdpMLineIndex': candidate.sdpMLineIndex,
          },
        );
      };

      // Receive callee's ICE candidates → feed into peer connection
      signaling.onIceCandidate = (data) async {
        final c = data['candidate'];
        if (c == null) return;
        await webrtc.addIceCandidate(RTCIceCandidate(
          c['candidate']     as String?,
          c['sdpMid']        as String?,
          c['sdpMLineIndex'] as int?,
        ));
      };

      // Callee answers → set their SDP on our peer connection
      signaling.onCallAnswered = (data) async {
        signaling.cancelCallTimeout();
        final answerMap = data['answer'] as Map?;
        if (answerMap == null) return;
        final answer = RTCSessionDescription(
          answerMap['sdp']  as String? ?? '',
          answerMap['type'] as String? ?? 'answer',
        );
        await webrtc.setRemoteAnswer(answer);
      };

      // Create offer (triggers ICE gathering)
      final offer = await webrtc.createOffer();

      signaling.callUser(
        calleeId: calleeId,
        callerId: signaling.userId ?? 'unknown',
        offer: {'sdp': offer.sdp, 'type': offer.type},
      );

      // 30-second ring timeout
      signaling.startCallTimeout();
      signaling.onCallTimeout = () {
        if (mounted) {
          _showSnack('No answer — call timed out', AppColors.warning);
          webrtc.endCall();
          setState(() => _callingUserId = null);
        }
      };

      // Callee rejected
      signaling.onCallRejected = (_) {
        signaling.cancelCallTimeout();
        if (mounted) {
          _showSnack('Call rejected', AppColors.warning);
          webrtc.endCall();
          setState(() => _callingUserId = null);
        }
      };

      if (!mounted) return;

      // Navigate — clear _callingUserId when the call screen pops
      await Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => InCallScreen(
            contactName:   calleeId,
            contactNumber: calleeId,
            isVoIP:        true,
            isIncoming:    false,
          ),
        ),
      );
    } catch (e) {
      debugPrint('VoIP call initiation error: $e');
      if (mounted) _showSnack('Failed to start call: $e', AppColors.danger);
      // Clean up on error
      webrtc.endCall();
    } finally {
      if (mounted) setState(() => _callingUserId = null);
      // Clear signaling callbacks after call screen exits
      signaling.onCallAnswered = null;
      signaling.onCallTimeout  = null;
      signaling.onCallRejected = null;
      signaling.onIceCandidate = null;
      webrtc.onIceCandidate    = null;
    }
  }

  void _showSnack(String message, Color color) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(message),
      backgroundColor: color,
      duration: const Duration(seconds: 3),
    ));
  }

  @override
  Widget build(BuildContext context) {
    final signaling = context.watch<SignalingService>();
    // Filter out our own ID from the online-users list
    final peers = signaling.onlineUsers
        .where((id) => id != signaling.userId)
        .toList();

    return Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _StatusCard(
            isConnected:  signaling.isConnected,
            userId:       signaling.userId,
            reconnecting: signaling.state == SignalingState.connecting,
          ),

          const SizedBox(height: 24),

          Row(
            children: [
              const Text(
                'Online Users',
                style: TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.w600),
              ),
              const Spacer(),
              if (peers.isNotEmpty)
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
                  decoration: BoxDecoration(
                    color: AppColors.verified.withValues(alpha: 0.15),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Text(
                    '${peers.length} online',
                    style: const TextStyle(
                      color: AppColors.verified, fontSize: 12, fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
            ],
          ),

          const SizedBox(height: 12),

          Expanded(
            child: peers.isEmpty
                ? const _EmptyState()
                : ListView.builder(
                    itemCount: peers.length,
                    itemBuilder: (context, index) {
                      final userId = peers[index];
                      return _UserTile(
                        userId:    userId,
                        isCalling: _callingUserId == userId,
                        isBlocked: _callingUserId != null && _callingUserId != userId,
                        onCall:    () => _initiateVoIPCall(userId),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}

// ── Status card ───────────────────────────────────────────────────────────────

class _StatusCard extends StatelessWidget {
  final bool isConnected;
  final bool reconnecting;
  final String? userId;

  const _StatusCard({
    required this.isConnected,
    required this.reconnecting,
    this.userId,
  });

  @override
  Widget build(BuildContext context) {
    final color = isConnected
        ? AppColors.verified
        : reconnecting
            ? AppColors.warning
            : AppColors.danger;

    final label = isConnected
        ? 'Connected'
        : reconnecting
            ? 'Reconnecting…'
            : 'Disconnected';

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: color.withValues(alpha: 0.3)),
      ),
      child: Row(
        children: [
          reconnecting
              ? SizedBox(
                  width: 12, height: 12,
                  child: CircularProgressIndicator(strokeWidth: 2, color: AppColors.warning),
                )
              : Container(
                  width: 12, height: 12,
                  decoration: BoxDecoration(color: color, shape: BoxShape.circle),
                ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(label, style: TextStyle(color: color, fontWeight: FontWeight.w600)),
                if (userId != null)
                  Text(
                    'Your ID: $userId',
                    style: const TextStyle(color: Colors.white54, fontSize: 12),
                    overflow: TextOverflow.ellipsis,
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// ── User tile ─────────────────────────────────────────────────────────────────

class _UserTile extends StatelessWidget {
  final String userId;
  final bool isCalling;
  final bool isBlocked;
  final VoidCallback onCall;

  const _UserTile({
    required this.userId,
    required this.isCalling,
    required this.isBlocked,
    required this.onCall,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(14),
      ),
      child: ListTile(
        leading: CircleAvatar(
          backgroundColor: AppColors.primary.withValues(alpha: 0.2),
          child: Text(
            userId.isNotEmpty ? userId[0].toUpperCase() : '?',
            style: const TextStyle(color: AppColors.primary, fontWeight: FontWeight.bold),
          ),
        ),
        title: Text(userId, style: const TextStyle(color: Colors.white)),
        subtitle: const Text('Online', style: TextStyle(color: AppColors.verified, fontSize: 12)),
        trailing: isCalling
            ? const SizedBox(
                width: 24, height: 24,
                child: CircularProgressIndicator(strokeWidth: 2, color: AppColors.callGreen),
              )
            : IconButton(
                icon: Icon(
                  Icons.wifi_calling,
                  color: isBlocked ? Colors.white24 : AppColors.verified,
                ),
                tooltip: isBlocked ? 'Call in progress' : 'VoIP call',
                onPressed: isBlocked ? null : onCall,
              ),
      ),
    );
  }
}

// ── Empty state ───────────────────────────────────────────────────────────────

class _EmptyState extends StatelessWidget {
  const _EmptyState();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: const [
          Icon(Icons.people_outline, size: 64, color: Colors.white24),
          SizedBox(height: 16),
          Text('No users online',
              style: TextStyle(color: Colors.white38, fontSize: 16)),
          SizedBox(height: 8),
          Text(
            'Ask your contact to open VoiceGuard\nand sign in with their ID',
            style: TextStyle(color: Colors.white24, fontSize: 13),
            textAlign: TextAlign.center,
          ),
        ],
      ),
    );
  }
}
