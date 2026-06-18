import 'dart:async';

import 'package:flutter/foundation.dart';

/// Callback fired when the user taps an incoming VoIP notification.
typedef OnIncomingVoIPNotification = void Function(
  String callerId,
  String roomId,
);

/// Push-notification service placeholder.
///
/// Firebase dependencies and Android Google Services config are not currently
/// installed in this Flutter project. This class keeps the app compile-safe
/// while preserving the API used by the rest of the app. Wire Firebase back in
/// only after adding firebase_core, firebase_messaging,
/// flutter_local_notifications, google-services.json, and the Android Gradle
/// Google Services plugin together.
class FcmService {
  FcmService._();

  static final FcmService instance = FcmService._();

  final StreamController<String> _tokenController =
      StreamController<String>.broadcast();

  String? _token;

  String? get token => _token;

  Stream<String> get tokenStream => _tokenController.stream;

  OnIncomingVoIPNotification? onIncomingVoIPCall;

  Future<void> init() async {
    debugPrint('FCM disabled: Firebase dependencies are not configured.');
  }

  Future<void> cancelIncomingCallNotification() async {}

  void dispose() {
    _tokenController.close();
  }
}
