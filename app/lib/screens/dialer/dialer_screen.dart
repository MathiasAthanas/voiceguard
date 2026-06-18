import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:provider/provider.dart';
import '../../core/constants/app_colors.dart';
import '../../core/services/cellular_call_service.dart';
import '../in_call/in_call_screen.dart';

class DialerScreen extends StatefulWidget {
  const DialerScreen({super.key});

  @override
  State<DialerScreen> createState() => _DialerScreenState();
}

class _DialerScreenState extends State<DialerScreen> {
  String _input = '';
  bool _calling = false;

  // ── Input handling ─────────────────────────────────────────────────────────

  void _onKeyPress(String value) {
    HapticFeedback.lightImpact();
    setState(() => _input += value);
  }

  void _onLongPress(String main) {
    // Long-press 0 inserts '+' (international prefix)
    if (main == '0') {
      HapticFeedback.mediumImpact();
      setState(() => _input += '+');
    }
  }

  void _onDelete() {
    HapticFeedback.lightImpact();
    if (_input.isNotEmpty) {
      setState(() => _input = _input.substring(0, _input.length - 1));
    }
  }

  void _onDeleteLong() {
    HapticFeedback.mediumImpact();
    setState(() => _input = '');
  }

  // ── Display formatting ─────────────────────────────────────────────────────

  /// Format digits as they're typed so the display looks like a phone number.
  /// Handles international (+XX XXXXXXXXXX) and local (XXX-XXXX-XXXX) formats.
  String get _formattedInput {
    if (_input.isEmpty) return '';
    final digits = _input.replaceAll(RegExp(r'[^\d+]'), '');
    if (digits.isEmpty) return _input;

    // International format: +<cc> <rest>
    if (digits.startsWith('+')) {
      final rest = digits.substring(1);
      if (rest.length <= 3) return digits;
      if (rest.length <= 6)
        return '+${rest.substring(0, rest.length <= 3 ? rest.length : 3)} ${rest.substring(rest.length <= 3 ? rest.length : 3)}';
      return '+${rest.substring(0, 3)} ${_groupLocal(rest.substring(3))}';
    }

    // Local format
    return _groupLocal(digits);
  }

  String _groupLocal(String digits) {
    if (digits.length <= 3) return digits;
    if (digits.length <= 6)
      return '${digits.substring(0, 3)}-${digits.substring(3)}';
    if (digits.length <= 10) {
      return '${digits.substring(0, 3)}-${digits.substring(3, 6)}-${digits.substring(6)}';
    }
    return '${digits.substring(0, 3)}-${digits.substring(3, 6)}-${digits.substring(6, 10)}${digits.length > 10 ? ' ${digits.substring(10)}' : ''}';
  }

  // ── Contact suggestion ─────────────────────────────────────────────────────

  /// Look up a display name from the device contacts for the current input.
  Future<String?> _lookupName() async {
    final raw = _input.replaceAll(RegExp(r'[^\d+]'), '');
    if (raw.length < 3) return null;
    return context.read<CellularCallService>().findContactName(raw);
  }

  // ── Call ──────────────────────────────────────────────────────────────────

  Future<void> _makeCall() async {
    final raw = _input.replaceAll(RegExp(r'\s', unicode: true), '');
    if (raw.isEmpty || _calling) return;

    // Prevent calling while already in a call
    final cellular = context.read<CellularCallService>();
    if (cellular.callState != CellularCallState.idle) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('A call is already active'),
        backgroundColor: AppColors.warning,
      ));
      return;
    }

    final phoneStatus = await Permission.phone.request();
    if (!mounted) return;
    if (!phoneStatus.isGranted) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('Phone permission is required to place calls'),
        backgroundColor: AppColors.danger,
      ));
      return;
    }

    // VoiceGuardInCallService (which drives all call-state events to Flutter)
    // is only bound when VoiceGuard is the default dialer. Without this role,
    // the call is placed but InCallScreen never transitions from "Calling…".
    final isDefault = await cellular.isDefaultDialer();
    if (!mounted) return;
    if (!isDefault) {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Set as Default Phone App'),
          content: const Text(
            'VoiceGuard needs to be your default phone app to '
            'track and protect outgoing calls.\n\n'
            'Tap "Set Now" to open the system prompt.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Set Now'),
            ),
          ],
        ),
      );
      if (confirmed == true && mounted) {
        await cellular.requestDefaultDialer();
      }
      return;
    }

    setState(() => _calling = true);
    HapticFeedback.mediumImpact();

    // Lookup display name for InCallScreen
    final contactName = await cellular.findContactName(raw) ?? raw;
    if (!mounted) return;

    await cellular.makeCall(raw);
    if (!mounted) return;

    setState(() {
      _calling = false;
      _input = ''; // clear after initiating
    });

    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => InCallScreen(
          contactName: contactName,
          contactNumber: raw,
          isVoIP: false,
          isIncoming: false,
        ),
      ),
    );
  }

  // ── Build ─────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 24, 24, 0),
      child: Column(
        children: [
          // ── Display ───────────────────────────────────────────────────────
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
            decoration: BoxDecoration(
              color: AppColors.surface,
              borderRadius: BorderRadius.circular(16),
            ),
            child: Column(
              children: [
                Row(
                  children: [
                    const SizedBox(width: 48),
                    Expanded(
                      child: Text(
                        _input.isEmpty ? 'Enter number' : _formattedInput,
                        style: TextStyle(
                          fontSize: _input.isEmpty ? 18 : 28,
                          fontWeight: FontWeight.bold,
                          color: _input.isEmpty ? Colors.white24 : Colors.white,
                          letterSpacing: 1.5,
                        ),
                        textAlign: TextAlign.center,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    SizedBox(
                      width: 48,
                      child: _input.isEmpty
                          ? const SizedBox.shrink()
                          : IconButton(
                              tooltip: 'Delete',
                              icon: const Icon(Icons.backspace_outlined,
                                  color: Colors.white54),
                              onPressed: _onDelete,
                              onLongPress: _onDeleteLong,
                            ),
                    ),
                  ],
                ),

                // Contact name suggestion
                if (_input.length >= 3)
                  FutureBuilder<String?>(
                    future: _lookupName(),
                    builder: (_, snap) {
                      if (snap.data == null) return const SizedBox.shrink();
                      return Padding(
                        padding: const EdgeInsets.only(top: 4),
                        child: Text(
                          snap.data!,
                          style: const TextStyle(
                            color: AppColors.primary,
                            fontSize: 13,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                      );
                    },
                  ),
              ],
            ),
          ),

          const SizedBox(height: 24),

          // ── Keypad ────────────────────────────────────────────────────────
          Expanded(
            child: GridView.count(
              crossAxisCount: 3,
              mainAxisSpacing: 10,
              crossAxisSpacing: 10,
              childAspectRatio: 1.6,
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              children: [
                ..._buildNumberKeys(),
                _buildKey('*', ''),
                _buildKey('0', '+'),
                _buildKey('#', ''),
              ],
            ),
          ),

          const SizedBox(height: 20),

          // ── Call button ───────────────────────────────────────────────────
          GestureDetector(
            onTap: _calling ? null : _makeCall,
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 150),
              width: 72,
              height: 72,
              decoration: BoxDecoration(
                color: _calling
                    ? AppColors.callGreen.withValues(alpha: 0.6)
                    : AppColors.callGreen,
                shape: BoxShape.circle,
                boxShadow: [
                  BoxShadow(
                    color: AppColors.callGreen.withValues(alpha: 0.35),
                    blurRadius: 20,
                    spreadRadius: 4,
                  ),
                ],
              ),
              child: _calling
                  ? const Padding(
                      padding: EdgeInsets.all(20),
                      child: CircularProgressIndicator(
                          strokeWidth: 2, color: Colors.white),
                    )
                  : const Icon(Icons.call, color: Colors.white, size: 32),
            ),
          ),

          const SizedBox(height: 32),
        ],
      ),
    );
  }

  // ── Key builders ──────────────────────────────────────────────────────────

  List<Widget> _buildNumberKeys() {
    const keys = [
      ['1', ''],
      ['2', 'ABC'],
      ['3', 'DEF'],
      ['4', 'GHI'],
      ['5', 'JKL'],
      ['6', 'MNO'],
      ['7', 'PQRS'],
      ['8', 'TUV'],
      ['9', 'WXYZ'],
    ];
    return keys.map((k) => _buildKey(k[0], k[1])).toList();
  }

  Widget _buildKey(String main, String sub) {
    return GestureDetector(
      onTap: () => _onKeyPress(main),
      onLongPress: sub == '+' ? () => _onLongPress(main) : null,
      child: Container(
        decoration: BoxDecoration(
          color: AppColors.surface,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Text(
              main,
              style: const TextStyle(
                fontSize: 22,
                fontWeight: FontWeight.w600,
                color: Colors.white,
              ),
            ),
            if (sub.isNotEmpty)
              Text(sub,
                  style: const TextStyle(fontSize: 9, color: Colors.white38)),
          ],
        ),
      ),
    );
  }
}
