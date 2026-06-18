import 'dart:async';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../core/constants/app_colors.dart';
import '../../core/constants/app_constants.dart';
import '../../core/models/contact_model.dart';
import '../../core/services/audio_capture_service.dart';
import '../../core/services/verification_service.dart';

enum EnrollState { idle, recording, processing, done, error }

class EnrollScreen extends StatefulWidget {
  final ContactModel contact;

  const EnrollScreen({super.key, required this.contact});

  @override
  State<EnrollScreen> createState() => _EnrollScreenState();
}

class _EnrollScreenState extends State<EnrollScreen> {
  EnrollState _state = EnrollState.idle;
  final AudioCaptureService _audioCapture = AudioCaptureService();
  final List<String> _recordedFiles = [];
  int _currentSample = 0;
  String? _errorMessage;
  int _countdown = 0;
  Timer? _countdownTimer;

  final List<String> _phrases = [
    'My name is ${AppConstants.appName} and I authorize this call',
    'The quick brown fox jumps over the lazy dog',
    'Voice verification is active and working correctly',
  ];

  Future<void> _startRecording() async {
    final hasPermission = await _audioCapture.hasPermission();
    if (!hasPermission) {
      setState(() {
        _state = EnrollState.error;
        _errorMessage = 'Microphone permission denied';
      });
      return;
    }

    setState(() {
      _state = EnrollState.recording;
      _errorMessage = null;
      _countdown = AppConstants.enrollmentDurationSeconds;
    });

    // Start live countdown
    _countdownTimer?.cancel();
    _countdownTimer = Timer.periodic(const Duration(seconds: 1), (t) {
      if (!mounted) { t.cancel(); return; }
      setState(() => _countdown--);
      if (_countdown <= 0) t.cancel();
    });

    final path = await _audioCapture.recordSingleClip(
      durationSeconds: AppConstants.enrollmentDurationSeconds,
    );

    _countdownTimer?.cancel();

    if (path == null) {
      setState(() {
        _state = EnrollState.error;
        _errorMessage = 'Recording failed. Please try again.';
      });
      return;
    }

    _recordedFiles.add(path);
    _currentSample++;

    if (_currentSample >= AppConstants.recommendedEnrollmentSamples) {
      await _submitEnrollment();
    } else {
      setState(() => _state = EnrollState.idle);
    }
  }

  Future<void> _submitEnrollment() async {
    setState(() => _state = EnrollState.processing);

    final verificationService = context.read<VerificationService>();
    final success = await verificationService.enrollContact(
      contactId: widget.contact.name,
      audioPaths: _recordedFiles,
    );

    // Clean up temp WAV files regardless of outcome
    for (final p in _recordedFiles) {
      _audioCapture.deleteFile(p);
    }
    _recordedFiles.clear();

    if (success) {
      setState(() => _state = EnrollState.done);
    } else {
      setState(() {
        _state = EnrollState.error;
        _errorMessage = 'Enrollment failed. Check that the AI backend is running.';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        title: Text('Enroll ${widget.contact.name}'),
        backgroundColor: AppColors.surface,
      ),
      body: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            const SizedBox(height: 24),

            // Avatar
            CircleAvatar(
              radius: 44,
              backgroundColor: AppColors.primary.withValues(alpha: 0.2),
              child: Text(
                widget.contact.initials,
                style: const TextStyle(
                  fontSize: 36,
                  color: AppColors.primary,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),

            const SizedBox(height: 16),

            Text(
              widget.contact.name,
              style: const TextStyle(
                fontSize: 22,
                color: Colors.white,
                fontWeight: FontWeight.bold,
              ),
            ),

            const SizedBox(height: 8),

            Text(
              'Sample ${_currentSample + 1} of ${AppConstants.recommendedEnrollmentSamples}',
              style: const TextStyle(color: Colors.white54),
            ),

            const SizedBox(height: 32),

            // Progress indicators
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: List.generate(
                AppConstants.recommendedEnrollmentSamples,
                (i) => Container(
                  margin: const EdgeInsets.symmetric(horizontal: 4),
                  width: 40,
                  height: 6,
                  decoration: BoxDecoration(
                    color: i < _currentSample ? AppColors.verified : AppColors.surface,
                    borderRadius: BorderRadius.circular(3),
                  ),
                ),
              ),
            ),

            const SizedBox(height: 40),

            // Phrase to read
            if (_state != EnrollState.done && _currentSample < _phrases.length)
              Container(
                padding: const EdgeInsets.all(20),
                decoration: BoxDecoration(
                  color: AppColors.surface,
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: AppColors.primary.withValues(alpha: 0.3)),
                ),
                child: Column(
                  children: [
                    const Text(
                      'Say this phrase clearly:',
                      style: TextStyle(color: Colors.white54, fontSize: 13),
                    ),
                    const SizedBox(height: 12),
                    Text(
                      _phrases[_currentSample.clamp(0, _phrases.length - 1)],
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 16,
                        height: 1.5,
                        fontStyle: FontStyle.italic,
                      ),
                      textAlign: TextAlign.center,
                    ),
                  ],
                ),
              ),

            const SizedBox(height: 40),

            // State-based UI
            _buildStateWidget(),

            // Error message
            if (_errorMessage != null) ...[
              const SizedBox(height: 16),
              Text(
                _errorMessage!,
                style: const TextStyle(color: AppColors.danger),
                textAlign: TextAlign.center,
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildStateWidget() {
    switch (_state) {
      case EnrollState.idle:
        return Column(
          children: [
            GestureDetector(
              onTap: _startRecording,
              child: Container(
                width: 80,
                height: 80,
                decoration: BoxDecoration(
                  color: AppColors.primary,
                  shape: BoxShape.circle,
                  boxShadow: [
                    BoxShadow(
                      color: AppColors.primary.withValues(alpha: 0.4),
                      blurRadius: 20,
                      spreadRadius: 4,
                    ),
                  ],
                ),
                child: const Icon(Icons.mic, color: Colors.white, size: 36),
              ),
            ),
            const SizedBox(height: 16),
            Text(
              'Tap to record (${AppConstants.enrollmentDurationSeconds}s)',
              style: const TextStyle(color: Colors.white54),
            ),
          ],
        );

      case EnrollState.recording:
        return Column(
          children: [
            Stack(
              alignment: Alignment.center,
              children: [
                SizedBox(
                  width: 88,
                  height: 88,
                  child: CircularProgressIndicator(
                    value: _countdown / AppConstants.enrollmentDurationSeconds,
                    strokeWidth: 4,
                    backgroundColor: Colors.white10,
                    color: AppColors.danger,
                  ),
                ),
                Container(
                  width: 72,
                  height: 72,
                  decoration: const BoxDecoration(
                    color: AppColors.danger,
                    shape: BoxShape.circle,
                  ),
                  child: Center(
                    child: Text(
                      '$_countdown',
                      style: const TextStyle(
                          color: Colors.white,
                          fontSize: 26,
                          fontWeight: FontWeight.bold),
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            const Text(
              '🔴 Recording — speak clearly',
              style: TextStyle(
                  color: AppColors.danger, fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 4),
            const Text(
              'Keep quiet surroundings for best results',
              style: TextStyle(color: Colors.white38, fontSize: 12),
            ),
          ],
        );

      case EnrollState.processing:
        return const Column(
          children: [
            CircularProgressIndicator(color: AppColors.primary),
            SizedBox(height: 16),
            Text('Processing voice...', style: TextStyle(color: Colors.white54)),
          ],
        );

      case EnrollState.done:
        return Column(
          children: [
            const Icon(Icons.check_circle, color: AppColors.verified, size: 64),
            const SizedBox(height: 16),
            Text(
              '${widget.contact.name} enrolled successfully!',
              style: const TextStyle(color: AppColors.verified, fontSize: 16, fontWeight: FontWeight.w600),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 24),
            ElevatedButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Done'),
            ),
          ],
        );

      case EnrollState.error:
        return Column(
          children: [
            const Icon(Icons.error_outline, color: AppColors.danger, size: 64),
            const SizedBox(height: 16),
            ElevatedButton(
              onPressed: () => setState(() {
                _state = EnrollState.idle;
                _errorMessage = null;
              }),
              child: const Text('Try Again'),
            ),
          ],
        );
    }
  }

  @override
  void dispose() {
    _countdownTimer?.cancel();
    _audioCapture.dispose();
    super.dispose();
  }
}
