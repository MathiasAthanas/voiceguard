import 'package:flutter/material.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:provider/provider.dart';
import '../../core/constants/app_colors.dart';
import '../../core/services/signaling_service.dart';
import '../../core/services/cellular_call_service.dart';
import '../../core/services/verification_service.dart';
import '../dialer/dialer_screen.dart';
import '../detection/detection_history_screen.dart';
import '../in_call/in_call_screen.dart';
import '../settings/settings_screen.dart';
import '../voip/voip_screen.dart';
import '../contacts/contacts_screen.dart';
import '../history/history_screen.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  int _selectedIndex = 0;
  final TextEditingController _userIdController = TextEditingController();
  bool _incomingCallScreenOpen = false;
  bool _backendReachable = true; // optimistic until checked

  static const _settingsBox = 'settings';
  static const _userIdKey = 'userId';

  final List<Widget> _screens = const [
    DialerScreen(),
    VoIPScreen(),
    ContactsScreen(),
    HistoryScreen(),
    DetectionHistoryScreen(),
  ];

  @override
  void initState() {
    super.initState();
    _checkSetup();
  }

  void _checkSetup() {
    _setupCellularCallbacks();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _autoConnectOrShowDialog();
    });
  }

  /// On launch: read saved userId from Hive.
  /// If found → connect silently and skip the dialog.
  /// If not found → show the setup dialog as before.
  Future<void> _autoConnectOrShowDialog() async {
    // Check AI backend health in the background
    _checkBackendHealth();

    try {
      final box = Hive.box(_settingsBox);
      final savedId = box.get(_userIdKey) as String?;

      if (savedId != null && savedId.isNotEmpty) {
        _userIdController.text = savedId;
        if (!mounted) return;
        final signaling = context.read<SignalingService>();
        signaling.connect(savedId);
        _prepareCellularMode();
        return;
      }
    } catch (e) {
      debugPrint('VoiceGuard: Failed to read saved userId: $e');
    }

    if (mounted) _showSetupDialog();
  }

  Future<void> _checkBackendHealth() async {
    final reachable =
        await context.read<VerificationService>().isBackendReachable();
    if (!mounted) return;
    setState(() => _backendReachable = reachable);
  }

  void _setupCellularCallbacks() {
    final cellular = context.read<CellularCallService>();
    final signaling = context.read<SignalingService>();

    // ── Cellular incoming ────────────────────────────────────────────────────
    cellular.onIncomingCall = (number, contactName) {
      if (!mounted || _incomingCallScreenOpen) return;
      _incomingCallScreenOpen = true;
      Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => InCallScreen(
            contactName: contactName ?? number,
            contactNumber: number,
            isVoIP: false,
            isIncoming: true,
          ),
        ),
      ).whenComplete(() => _incomingCallScreenOpen = false);
    };

    cellular.onCallEnded = () {
      if (!mounted) return;
      // Safety net only: InCallScreen's own _onCellularStateChanged listener is
      // the primary handler for ending the screen. This only fires if the screen
      // is still marked open but hasn't popped itself (e.g. arrived before
      // InCallScreen finished initialising).
      if (_incomingCallScreenOpen) {
        _incomingCallScreenOpen = false;
        // Don't pop — InCallScreen will pop itself via _endCallFromRemote.
        // Calling maybePop() here races against that and can pop the wrong screen.
      }
    };

    // ── VoIP incoming ────────────────────────────────────────────────────────
    signaling.onIncomingCall = (data) {
      if (!mounted || _incomingCallScreenOpen) return;
      _incomingCallScreenOpen = true;

      final callerId = data['callerId'] as String? ?? 'Unknown';
      final roomId = data['roomId'] as String? ?? '';
      final offer = Map<String, dynamic>.from(data['offer'] as Map? ?? {});

      // Show a native full-screen notification so the call UI surfaces even
      // when the device is locked or the app is in the background.
      context.read<CellularCallService>().showVoipCallNotification(callerId);

      Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => InCallScreen(
            contactName: callerId,
            contactNumber: callerId,
            isVoIP: true,
            isIncoming: true,
            voipRoomId: roomId,
            voipCallerId: callerId,
            voipOffer: offer,
          ),
        ),
      ).whenComplete(() {
        _incomingCallScreenOpen = false;
        // Dismiss the VoIP notification once the call screen has closed
        if (mounted) {
          context.read<CellularCallService>().dismissVoipCallNotification();
        }
      });
    };
  }

  Future<void> _prepareCellularMode() async {
    await [
      Permission.phone,
      Permission.microphone,
      Permission.contacts,
    ].request();

    if (!mounted) return;

    final cellular = context.read<CellularCallService>();
    final isDefaultDialer = await cellular.isDefaultDialer();
    if (!mounted || isDefaultDialer) return;

    _showDefaultDialerDialog();
  }

  void _showDefaultDialerDialog() {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: AppColors.surface,
        title: const Text(
          'Enable cellular calls',
          style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
        ),
        content: const Text(
          'To answer normal SIM calls inside VoiceGuard, set VoiceGuard as your default Phone app.',
          style: TextStyle(color: Colors.white70),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Later'),
          ),
          ElevatedButton(
            onPressed: () {
              context.read<CellularCallService>().requestDefaultDialer();
              Navigator.pop(context);
            },
            child: const Text('Set as Phone app'),
          ),
        ],
      ),
    );
  }

  void _showSetupDialog({bool isFirstTime = true}) {
    // Pre-fill if there's already a saved ID (e.g. opened from settings icon)
    final existingId = Hive.box(_settingsBox).get(_userIdKey) as String?;
    if (existingId != null && existingId.isNotEmpty) {
      _userIdController.text = existingId;
    }

    showDialog(
      context: context,
      barrierDismissible:
          !isFirstTime, // dismiss-able from settings, not on first launch
      builder: (context) => PopScope(
        canPop: !isFirstTime,
        child: AlertDialog(
          backgroundColor: AppColors.surface,
          title: Text(
            isFirstTime ? 'Welcome to VoiceGuard' : 'Change User ID',
            style: const TextStyle(
                color: Colors.white, fontWeight: FontWeight.bold),
          ),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                isFirstTime
                    ? 'Enter your user ID to connect.\nUse your phone number or any unique name.'
                    : 'Update your user ID below.',
                style: const TextStyle(color: Colors.white70),
              ),
              const SizedBox(height: 16),
              TextField(
                controller: _userIdController,
                style: const TextStyle(color: Colors.white),
                decoration: InputDecoration(
                  hintText: 'e.g. +254712345678',
                  hintStyle: const TextStyle(color: Colors.white38),
                  filled: true,
                  fillColor: AppColors.cardBg,
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(10),
                    borderSide: BorderSide.none,
                  ),
                  prefixIcon:
                      const Icon(Icons.person, color: AppColors.primary),
                ),
              ),
            ],
          ),
          actions: [
            if (!isFirstTime)
              TextButton(
                onPressed: () {
                  Navigator.pop(context);
                  _prepareCellularMode();
                },
                child: const Text('Cancel'),
              ),
            ElevatedButton(
              onPressed: () {
                final userId = _userIdController.text.trim();
                if (userId.isEmpty) {
                  ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
                    content: Text('User ID is required for VoIP registration'),
                    backgroundColor: AppColors.warning,
                  ));
                  return;
                }
                Hive.box(_settingsBox).put(_userIdKey, userId);
                final signaling = context.read<SignalingService>();
                signaling.connect(userId);
                Navigator.pop(context);
                _prepareCellularMode();
              },
              child: const Text('Connect'),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        title: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 8,
              height: 8,
              decoration: BoxDecoration(
                color: context.watch<SignalingService>().isConnected
                    ? AppColors.verified
                    : AppColors.danger,
                shape: BoxShape.circle,
              ),
            ),
            const SizedBox(width: 8),
            const Text('VoiceGuard'),
          ],
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.settings_outlined),
            tooltip: 'Settings',
            onPressed: () => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => const SettingsScreen()),
            ),
          ),
        ],
      ),
      body: Column(
        children: [
          // AI backend offline banner
          if (!_backendReachable)
            Material(
              color: AppColors.danger.withValues(alpha: 0.15),
              child: InkWell(
                onTap: _checkBackendHealth,
                child: Container(
                  width: double.infinity,
                  padding:
                      const EdgeInsets.symmetric(vertical: 8, horizontal: 16),
                  child: Row(
                    children: const [
                      Icon(Icons.warning_amber_rounded,
                          color: AppColors.danger, size: 16),
                      SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          'AI backend offline — voice verification unavailable. Tap to retry.',
                          style:
                              TextStyle(color: AppColors.danger, fontSize: 12),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          Expanded(child: _screens[_selectedIndex]),
        ],
      ),
      bottomNavigationBar: NavigationBar(
        backgroundColor: AppColors.surface,
        selectedIndex: _selectedIndex,
        onDestinationSelected: (i) => setState(() => _selectedIndex = i),
        indicatorColor: AppColors.primary.withValues(alpha: 0.2),
        destinations: const [
          NavigationDestination(
            icon: Icon(Icons.dialpad_outlined),
            selectedIcon: Icon(Icons.dialpad, color: AppColors.primary),
            label: 'Dialer',
          ),
          NavigationDestination(
            icon: Icon(Icons.wifi_calling_outlined),
            selectedIcon: Icon(Icons.wifi_calling, color: AppColors.primary),
            label: 'VoIP',
          ),
          NavigationDestination(
            icon: Icon(Icons.contacts_outlined),
            selectedIcon: Icon(Icons.contacts, color: AppColors.primary),
            label: 'Contacts',
          ),
          NavigationDestination(
            icon: Icon(Icons.history_outlined),
            selectedIcon: Icon(Icons.history, color: AppColors.primary),
            label: 'History',
          ),
          NavigationDestination(
            icon: Icon(Icons.security_outlined),
            selectedIcon: Icon(Icons.security, color: AppColors.primary),
            label: 'Results',
          ),
        ],
      ),
    );
  }

  @override
  void dispose() {
    _userIdController.dispose();
    super.dispose();
  }
}
