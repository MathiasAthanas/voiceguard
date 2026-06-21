import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../../core/constants/app_colors.dart';
import '../../core/services/shell_audio_service.dart';

enum _Phase {
  checking,       // initial status check
  needsA11y,      // accessibility service not yet enabled
  waitingForPair, // a11y enabled — open the pairing dialog in Settings
  connecting,     // paired, auto-discovering main port
  mainPort,       // need main port manually (auto-discover timed out)
  done,
}

class AdbAudioSetupScreen extends StatefulWidget {
  const AdbAudioSetupScreen({super.key});

  @override
  State<AdbAudioSetupScreen> createState() => _AdbAudioSetupScreenState();
}

class _AdbAudioSetupScreenState extends State<AdbAudioSetupScreen>
    with WidgetsBindingObserver {
  _Phase  _phase = _Phase.checking;
  String? _error;

  final _mainPortCtrl = TextEditingController(); // manual fallback only

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _init();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _mainPortCtrl.dispose();
    super.dispose();
  }

  // Re-check whenever the user returns from Settings
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _init();
  }

  // ── Status check ─────────────────────────────────────────────────────────

  Future<void> _init() async {
    if (!mounted) return;
    setState(() => _phase = _Phase.checking);

    final svc = ShellAudioService.instance;
    final s   = await svc.setupStatus();
    if (!mounted) return;

    // Already fully set up
    if (s['isPaired'] == true && s['hasPort'] == true) {
      setState(() => _phase = _Phase.done);
      return;
    }

    // Paired but main port missing — auto-discover it
    if (s['isPaired'] == true) {
      setState(() { _phase = _Phase.connecting; _error = null; });
      final mainPort = await svc.discoverMainPort();
      if (!mounted) return;
      if (mainPort != null) {
        await svc.setMainPort(mainPort);
        if (!mounted) return;
        if (await svc.testConnection()) {
          setState(() => _phase = _Phase.done);
          return;
        }
      }
      setState(() { _phase = _Phase.mainPort; _error = null; });
      return;
    }

    // Not paired yet — check if accessibility service is enabled
    final a11y = await svc.isAccessibilityEnabled();
    if (!mounted) return;
    setState(() => _phase = a11y ? _Phase.waitingForPair : _Phase.needsA11y);
  }

  // ── Manual connect (main-port fallback) ───────────────────────────────────

  Future<void> _doManualConnect() async {
    final port = int.tryParse(_mainPortCtrl.text.trim());
    if (port == null) {
      setState(() => _error = 'Enter the port shown on the Wireless Debugging screen.');
      return;
    }
    setState(() { _phase = _Phase.connecting; _error = null; });
    final svc = ShellAudioService.instance;
    await svc.setMainPort(port);
    if (!mounted) return;
    if (await svc.testConnection()) {
      setState(() => _phase = _Phase.done);
    } else {
      setState(() {
        _phase = _Phase.mainPort;
        _error = 'Connection failed. Verify the port and that Wireless Debugging is active.';
      });
    }
  }

  // ── Reset ─────────────────────────────────────────────────────────────────

  Future<void> _doReset() async {
    await ShellAudioService.instance.reset();
    if (!mounted) return;
    _mainPortCtrl.clear();
    _init();
  }

  // ── Build ─────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        backgroundColor: AppColors.surface,
        title: const Text(
          'Cellular Audio Setup',
          style: TextStyle(color: Colors.white, fontSize: 17, fontWeight: FontWeight.w600),
        ),
        iconTheme: const IconThemeData(color: Colors.white),
        elevation: 0,
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: AnimatedSwitcher(
            duration: const Duration(milliseconds: 250),
            child: _buildPhase(),
          ),
        ),
      ),
    );
  }

  Widget _buildPhase() {
    switch (_phase) {
      case _Phase.checking:      return _buildLoading('Checking setup…');
      case _Phase.needsA11y:     return _buildNeedsA11y();
      case _Phase.waitingForPair: return _buildWaiting();
      case _Phase.connecting:    return _buildLoading('Connecting…');
      case _Phase.mainPort:      return _buildMainPort();
      case _Phase.done:          return _buildDone();
    }
  }

  // ── Phase widgets ─────────────────────────────────────────────────────────

  Widget _buildNeedsA11y() {
    return Column(
      key: const ValueKey('needsA11y'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _sectionHeader(
          'One-time permission needed',
          'VoiceGuard uses Android\'s Accessibility feature to automatically '
          'read the ADB pairing code from Developer Options — so you never have '
          'to copy port numbers or switch between apps.',
        ),
        _instruction(1, 'Tap the button below to open Accessibility Settings'),
        _instruction(2, 'Find "VoiceGuard" and enable it'),
        _instruction(3, 'Return here — setup continues automatically'),
        const SizedBox(height: 28),
        _primaryButton(
          'Open Accessibility Settings',
          () => ShellAudioService.instance.openAccessibilitySettings(),
        ),
        const SizedBox(height: 16),
        Center(
          child: TextButton(
            onPressed: _init,
            child: const Text(
              'I already enabled it — check again',
              style: TextStyle(color: AppColors.primary, fontSize: 13),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildWaiting() {
    return Column(
      key: const ValueKey('waiting'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _sectionHeader(
          'Open the pairing dialog',
          'VoiceGuard will detect the pairing code automatically — '
          'you stay in Settings the whole time.',
        ),
        _instruction(1, 'Open  Settings → Developer options → Wireless debugging'),
        _instruction(2, 'Tap  "Pair device with pairing code"'),
        _instruction(3, 'Watch for the VoiceGuard notification — pairing happens in the background!'),
        const SizedBox(height: 32),
        Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: AppColors.surface,
            borderRadius: BorderRadius.circular(12),
          ),
          child: Row(
            children: [
              const SizedBox(
                width: 20, height: 20,
                child: CircularProgressIndicator(strokeWidth: 2, color: AppColors.primary),
              ),
              const SizedBox(width: 14),
              const Expanded(
                child: Text(
                  'Waiting for pairing dialog to open…',
                  style: TextStyle(color: Colors.white70, fontSize: 14),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 24),
        Center(
          child: TextButton(
            onPressed: _init,
            child: const Text(
              'Check if pairing completed',
              style: TextStyle(color: AppColors.primary, fontSize: 13),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildMainPort() {
    return Column(
      key: const ValueKey('mainPort'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _sectionHeader(
          'Almost done — enter the connection port',
          'Pairing succeeded! The main ADB port could not be detected automatically. '
          'Enter it manually once to finish.',
        ),
        _instruction(1, 'Open Settings → Developer options → Wireless debugging'),
        _instruction(2, 'Note the port next to your device IP  (e.g. "43651")'),
        const SizedBox(height: 12),
        TextField(
          controller: _mainPortCtrl,
          keyboardType: TextInputType.number,
          inputFormatters: [FilteringTextInputFormatter.digitsOnly],
          style: const TextStyle(color: Colors.white),
          decoration: _inputDecoration('Main ADB port  (e.g. 43651)'),
        ),
        const SizedBox(height: 24),
        _errorBox(),
        _primaryButton('Connect', _doManualConnect),
      ],
    );
  }

  Widget _buildLoading(String label) {
    return SizedBox(
      key: ValueKey('loading-$label'),
      height: 200,
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const CircularProgressIndicator(color: AppColors.primary),
            const SizedBox(height: 16),
            Text(label, style: const TextStyle(color: Colors.white70, fontSize: 14)),
          ],
        ),
      ),
    );
  }

  Widget _buildDone() {
    return Column(
      key: const ValueKey('done'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Icon(Icons.check_circle, color: AppColors.verified, size: 56),
        const SizedBox(height: 16),
        const Text(
          'Cellular audio capture ready',
          style: TextStyle(
              color: Colors.white, fontSize: 22, fontWeight: FontWeight.bold),
        ),
        const SizedBox(height: 10),
        const Text(
          'VoiceGuard will now capture the remote caller\'s voice during cellular '
          'calls — even on Android 16 where the standard microphone is blocked.',
          style: TextStyle(color: Colors.white60, fontSize: 14, height: 1.5),
        ),
        const SizedBox(height: 20),
        _warningBox(
          'Wireless Debugging must stay enabled during calls. After a device '
          'reboot, toggle it back on — no re-pairing needed.',
        ),
        const SizedBox(height: 32),
        OutlinedButton(
          onPressed: _doReset,
          style: OutlinedButton.styleFrom(
            foregroundColor: Colors.white38,
            side: const BorderSide(color: Colors.white12),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
          ),
          child: const Text('Reset ADB setup'),
        ),
      ],
    );
  }

  // ── Reusable widgets ──────────────────────────────────────────────────────

  Widget _sectionHeader(String title, String subtitle) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(title,
            style: const TextStyle(
                color: Colors.white, fontSize: 20, fontWeight: FontWeight.bold)),
        const SizedBox(height: 8),
        Text(subtitle,
            style: const TextStyle(color: Colors.white60, fontSize: 13, height: 1.5)),
        const SizedBox(height: 28),
      ],
    );
  }

  Widget _instruction(int n, String text) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          CircleAvatar(
            radius: 11,
            backgroundColor: AppColors.primary,
            child: Text('$n',
                style: const TextStyle(
                    color: Colors.black, fontSize: 11, fontWeight: FontWeight.bold)),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(text,
                style: const TextStyle(color: Colors.white70, fontSize: 13, height: 1.5)),
          ),
        ],
      ),
    );
  }

  InputDecoration _inputDecoration(String label) {
    return InputDecoration(
      labelText: label,
      labelStyle: const TextStyle(color: Colors.white54, fontSize: 13),
      filled: true,
      fillColor: AppColors.surface,
      border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10), borderSide: BorderSide.none),
      focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: const BorderSide(color: AppColors.primary, width: 1.5)),
    );
  }

  Widget _errorBox() {
    if (_error == null) return const SizedBox.shrink();
    return Container(
      margin: const EdgeInsets.only(bottom: 16),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppColors.danger.withValues(alpha: 0.13),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(Icons.error_outline, color: AppColors.danger, size: 16),
          const SizedBox(width: 8),
          Expanded(
              child: Text(_error!,
                  style: const TextStyle(color: AppColors.danger, fontSize: 13))),
        ],
      ),
    );
  }

  Widget _warningBox(String text) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppColors.warning.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(Icons.info_outline, color: AppColors.warning, size: 16),
          const SizedBox(width: 8),
          Expanded(
              child: Text(text,
                  style: const TextStyle(
                      color: AppColors.warning, fontSize: 13, height: 1.5))),
        ],
      ),
    );
  }

  Widget _primaryButton(String label, VoidCallback onPressed) {
    return SizedBox(
      width: double.infinity,
      child: ElevatedButton(
        onPressed: onPressed,
        style: ElevatedButton.styleFrom(
          backgroundColor: AppColors.primary,
          foregroundColor: Colors.black,
          padding: const EdgeInsets.symmetric(vertical: 16),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        ),
        child: Text(label,
            style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
      ),
    );
  }
}
