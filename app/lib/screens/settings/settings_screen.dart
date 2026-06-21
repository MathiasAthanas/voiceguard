import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../core/constants/app_colors.dart';
import '../../core/constants/app_constants.dart';
import '../../core/services/settings_service.dart';
import '../../core/services/signaling_service.dart';
import '../../core/services/shell_audio_service.dart';
import '../../core/services/verification_service.dart';
import '../setup/adb_audio_setup_screen.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  late TextEditingController _signalingCtrl;
  late TextEditingController _backendCtrl;

  // Validation / test state
  String? _signalingError;
  String? _backendError;
  bool _testingSignaling = false;
  bool _testingBackend   = false;

  @override
  void initState() {
    super.initState();
    final s = SettingsService.instance;
    _signalingCtrl = TextEditingController(text: s.signalingUrl);
    _backendCtrl   = TextEditingController(text: s.aiBackendUrl);
  }

  @override
  void dispose() {
    _signalingCtrl.dispose();
    _backendCtrl.dispose();
    super.dispose();
  }

  // ── Validation ─────────────────────────────────────────────────────────────

  String? _validateUrl(String raw) {
    final trimmed = raw.trim();
    if (trimmed.isEmpty) return 'URL cannot be empty';
    try {
      final uri = Uri.parse(trimmed);
      if (!uri.hasScheme || !['http', 'https'].contains(uri.scheme)) {
        return 'Must start with http:// or https://';
      }
      if (!uri.hasAuthority || uri.host.isEmpty) return 'Missing host';
    } catch (_) {
      return 'Invalid URL format';
    }
    return null;
  }

  bool get _hasErrors =>
      _validateUrl(_signalingCtrl.text) != null ||
      _validateUrl(_backendCtrl.text) != null;

  // ── Save ───────────────────────────────────────────────────────────────────

  Future<void> _save() async {
    // Run validation
    setState(() {
      _signalingError = _validateUrl(_signalingCtrl.text);
      _backendError   = _validateUrl(_backendCtrl.text);
    });
    if (_signalingError != null || _backendError != null) return;

    final s = SettingsService.instance;
    await s.saveSignalingUrl(_signalingCtrl.text.trim());
    await s.saveAiBackendUrl(_backendCtrl.text.trim());

    if (!mounted) return;

    // Reconnect signaling
    final signaling = context.read<SignalingService>();
    if (signaling.userId != null) {
      signaling.disconnect();
      signaling.connect(signaling.userId!);
    }

    // Refresh verification service
    context.read<VerificationService>().resetResult();

    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
      content: Text('Settings saved — reconnecting…'),
      backgroundColor: AppColors.verified,
      duration: Duration(seconds: 2),
    ));
  }

  Future<void> _reset() async {
    await SettingsService.instance.resetToDefaults();
    if (!mounted) return;
    setState(() {
      _signalingCtrl.text = SettingsService.instance.signalingUrl;
      _backendCtrl.text   = SettingsService.instance.aiBackendUrl;
      _signalingError     = null;
      _backendError       = null;
    });
  }

  // ── Connection tests ───────────────────────────────────────────────────────

  /// Ping the AI backend health endpoint.
  Future<void> _testBackend() async {
    final err = _validateUrl(_backendCtrl.text);
    if (err != null) {
      setState(() => _backendError = err);
      return;
    }

    setState(() { _testingBackend = true; _backendError = null; });

    // Temporarily save the URL being tested
    await SettingsService.instance.saveAiBackendUrl(_backendCtrl.text.trim());
    if (!mounted) return;

    final reachable = await context.read<VerificationService>().isBackendReachable();
    if (!mounted) return;

    setState(() {
      _testingBackend = false;
      _backendError   = reachable ? null : 'Backend unreachable — check the URL and that the server is running';
    });

    if (reachable) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('✅ Backend reachable'),
        backgroundColor: AppColors.verified,
        duration: Duration(seconds: 2),
      ));
    }
  }

  /// Try to connect to the signaling server.
  Future<void> _testSignaling() async {
    final err = _validateUrl(_signalingCtrl.text);
    if (err != null) {
      setState(() => _signalingError = err);
      return;
    }

    setState(() { _testingSignaling = true; _signalingError = null; });
    await SettingsService.instance.saveSignalingUrl(_signalingCtrl.text.trim());
    if (!mounted) return;

    final signaling = context.read<SignalingService>();
    if (signaling.userId != null) {
      signaling.disconnect();
      signaling.connect(signaling.userId!);
    }

    // Wait long enough for websocket-first plus HTTP fallback.
    await Future.delayed(const Duration(seconds: 8));
    if (!mounted) return;

    final connected = context.read<SignalingService>().isConnected;
    setState(() {
      _testingSignaling = false;
      _signalingError   = connected ? null : 'Could not connect — check the URL and that the server is running';
    });

    if (connected) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('✅ Signaling server connected'),
        backgroundColor: AppColors.verified,
        duration: Duration(seconds: 2),
      ));
    }
  }

  // ── Build ─────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final settings = context.watch<SettingsService>();

    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        title: const Text('Settings'),
        backgroundColor: AppColors.surface,
        actions: [
          TextButton(
            onPressed: _hasErrors ? null : _save,
            child: Text(
              'Save',
              style: TextStyle(
                color: _hasErrors ? Colors.white38 : AppColors.primary,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [

          // ── Network ───────────────────────────────────────────────────────
          const _SectionHeader(title: 'Network'),
          const SizedBox(height: 12),

          _UrlField(
            controller:  _signalingCtrl,
            label:       'Signaling Server URL',
            hint:        'http://192.168.x.x:8000',
            icon:        Icons.hub_outlined,
            helperText:  'Run: ipconfig → IPv4 Address of the PC running the server',
            errorText:   _signalingError,
            testing:     _testingSignaling,
            onChanged:   (_) => setState(() => _signalingError = null),
            onTest:      _testSignaling,
          ),

          const SizedBox(height: 12),

          _UrlField(
            controller: _backendCtrl,
            label:      'AI Backend URL',
            hint:       'http://192.168.x.x:8000',
            icon:       Icons.psychology_outlined,
            helperText: 'Same IP, port 8000 where the Python FastAPI server runs',
            errorText:  _backendError,
            testing:    _testingBackend,
            onChanged:  (_) => setState(() => _backendError = null),
            onTest:     _testBackend,
          ),

          const SizedBox(height: 24),

          // ── Voice Verification ────────────────────────────────────────────
          const _SectionHeader(title: 'Voice Verification'),
          const SizedBox(height: 12),

          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: AppColors.surface,
              borderRadius: BorderRadius.circular(14),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    const Text('Sensitivity',
                        style: TextStyle(color: Colors.white, fontWeight: FontWeight.w600)),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
                      decoration: BoxDecoration(
                        color: AppColors.primary.withValues(alpha: 0.2),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Text(
                        settings.sensitivityLabel,
                        style: const TextStyle(
                            color: AppColors.primary, fontSize: 12, fontWeight: FontWeight.w600),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                Text(
                  'Threshold: ${(settings.verificationThreshold * 100).round()}%  '
                  '— lower = more lenient (more matches), higher = stricter (fewer false positives)',
                  style: const TextStyle(color: Colors.white38, fontSize: 11),
                ),
                Slider(
                  value: settings.verificationThreshold,
                  min: 0.30,
                  max: 0.80,
                  divisions: 10,
                  activeColor: AppColors.primary,
                  inactiveColor: Colors.white12,
                  onChanged: (v) => SettingsService.instance.saveVerificationThreshold(v),
                ),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: const [
                    Text('Lenient (30%)', style: TextStyle(color: Colors.white38, fontSize: 10)),
                    Text('Strict (80%)',  style: TextStyle(color: Colors.white38, fontSize: 10)),
                  ],
                ),
              ],
            ),
          ),

          const SizedBox(height: 24),

          // ── Cellular Audio ─────────────────────────────────────────────────
          const _SectionHeader(title: 'Cellular Audio'),
          const SizedBox(height: 12),
          _CellularAudioTile(),

          const SizedBox(height: 24),

          // ── About ─────────────────────────────────────────────────────────
          const _SectionHeader(title: 'About'),
          const SizedBox(height: 12),
          _InfoTile(icon: Icons.info_outline,     title: 'Version',              value: AppConstants.appVersion),
          const SizedBox(height: 8),
          _InfoTile(icon: Icons.security_outlined, title: 'Verification window',  value: '3-segment rolling average (~15 s)'),
          const SizedBox(height: 8),
          _InfoTile(
            icon: Icons.shield_outlined,
            title: 'Spoof detection',
            value: 'AASIST anti-spoofing (placeholder — real model loads separately)',
            valueColor: Colors.white38,
          ),

          const SizedBox(height: 32),

          // ── Reset ─────────────────────────────────────────────────────────
          OutlinedButton.icon(
            onPressed: _reset,
            icon: const Icon(Icons.restore, color: AppColors.warning),
            label: const Text('Reset to defaults', style: TextStyle(color: AppColors.warning)),
            style: OutlinedButton.styleFrom(
              side: const BorderSide(color: AppColors.warning),
              padding: const EdgeInsets.symmetric(vertical: 14),
            ),
          ),

          const SizedBox(height: 16),
        ],
      ),
    );
  }
}

// ── Sub-widgets ───────────────────────────────────────────────────────────────

class _CellularAudioTile extends StatefulWidget {
  @override
  State<_CellularAudioTile> createState() => _CellularAudioTileState();
}

class _CellularAudioTileState extends State<_CellularAudioTile> {
  bool? _isReady;

  @override
  void initState() {
    super.initState();
    _check();
  }

  Future<void> _check() async {
    final ready = await ShellAudioService.instance.isReady();
    if (mounted) setState(() => _isReady = ready);
  }

  @override
  Widget build(BuildContext context) {
    final ready   = _isReady;
    final status  = ready == null ? 'Checking…' : ready ? 'Active' : 'Not configured';
    final color   = ready == null ? Colors.white38 : ready ? AppColors.verified : AppColors.warning;
    final icon    = ready == null ? Icons.hourglass_empty : ready ? Icons.check_circle : Icons.warning_amber;

    return InkWell(
      onTap: () async {
        await Navigator.push(
          context,
          MaterialPageRoute(builder: (_) => const AdbAudioSetupScreen()),
        );
        _check(); // refresh status on return
      },
      borderRadius: BorderRadius.circular(12),
      child: Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: AppColors.surface,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Row(
          children: [
            Icon(Icons.cable, color: AppColors.primary, size: 22),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('ADB shell audio capture',
                      style: TextStyle(color: Colors.white, fontWeight: FontWeight.w600)),
                  const SizedBox(height: 2),
                  const Text(
                    'Captures caller voice on Android 12+ where the mic is blocked',
                    style: TextStyle(color: Colors.white38, fontSize: 12),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            Row(children: [
              Icon(icon, color: color, size: 14),
              const SizedBox(width: 4),
              Text(status, style: TextStyle(color: color, fontSize: 12, fontWeight: FontWeight.w600)),
              const SizedBox(width: 4),
              const Icon(Icons.chevron_right, color: Colors.white24, size: 18),
            ]),
          ],
        ),
      ),
    );
  }
}

class _SectionHeader extends StatelessWidget {
  final String title;
  const _SectionHeader({required this.title});

  @override
  Widget build(BuildContext context) {
    return Text(
      title.toUpperCase(),
      style: const TextStyle(
          color: AppColors.primary, fontSize: 11, fontWeight: FontWeight.w700, letterSpacing: 1.2),
    );
  }
}

class _UrlField extends StatelessWidget {
  final TextEditingController controller;
  final String label;
  final String hint;
  final IconData icon;
  final String helperText;
  final String? errorText;
  final bool testing;
  final ValueChanged<String>? onChanged;
  final VoidCallback? onTest;

  const _UrlField({
    required this.controller,
    required this.label,
    required this.hint,
    required this.icon,
    required this.helperText,
    this.errorText,
    this.testing = false,
    this.onChanged,
    this.onTest,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: const TextStyle(color: Colors.white70, fontSize: 13)),
        const SizedBox(height: 6),
        Row(children: [
          Expanded(
            child: TextField(
              controller: controller,
              onChanged: onChanged,
              style: const TextStyle(color: Colors.white, fontFamily: 'monospace', fontSize: 13),
              keyboardType: TextInputType.url,
              decoration: InputDecoration(
                hintText: hint,
                hintStyle: const TextStyle(color: Colors.white24),
                filled: true,
                fillColor: AppColors.surface,
                prefixIcon: Icon(icon, color: AppColors.primary, size: 20),
                errorText: errorText,
                errorStyle: const TextStyle(color: AppColors.danger, fontSize: 11),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(10),
                  borderSide: errorText != null
                      ? const BorderSide(color: AppColors.danger)
                      : BorderSide.none,
                ),
                enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(10),
                  borderSide: errorText != null
                      ? const BorderSide(color: AppColors.danger)
                      : BorderSide.none,
                ),
              ),
            ),
          ),
          const SizedBox(width: 8),
          SizedBox(
            height: 48,
            child: OutlinedButton(
              onPressed: testing ? null : onTest,
              style: OutlinedButton.styleFrom(
                side: BorderSide(
                  color: errorText != null ? AppColors.danger : AppColors.primary.withValues(alpha: 0.5),
                ),
                padding: const EdgeInsets.symmetric(horizontal: 12),
              ),
              child: testing
                  ? const SizedBox(
                      width: 16, height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2, color: AppColors.primary),
                    )
                  : const Text('Test', style: TextStyle(color: AppColors.primary, fontSize: 13)),
            ),
          ),
        ]),
        const SizedBox(height: 4),
        Padding(
          padding: const EdgeInsets.only(left: 4),
          child: Text(helperText, style: const TextStyle(color: Colors.white38, fontSize: 11)),
        ),
      ],
    );
  }
}

class _InfoTile extends StatelessWidget {
  final IconData icon;
  final String title;
  final String value;
  final Color valueColor;

  const _InfoTile({
    required this.icon,
    required this.title,
    required this.value,
    this.valueColor = Colors.white54,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        color: AppColors.surface, borderRadius: BorderRadius.circular(10),
      ),
      child: Row(children: [
        Icon(icon, color: AppColors.primary, size: 20),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title, style: const TextStyle(color: Colors.white, fontSize: 13)),
              const SizedBox(height: 2),
              Text(value,
                  style: TextStyle(color: valueColor, fontSize: 11, fontFamily: 'monospace'),
                  overflow: TextOverflow.ellipsis),
            ],
          ),
        ),
      ]),
    );
  }
}
