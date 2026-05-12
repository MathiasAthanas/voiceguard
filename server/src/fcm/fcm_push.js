/**
 * FCM Push Notification sender (Firebase Admin SDK).
 *
 * Requires a Firebase service-account JSON file. Set the environment variable:
 *   GOOGLE_APPLICATION_CREDENTIALS=./firebase-service-account.json
 *
 * Download the JSON from Firebase Console → Project Settings → Service Accounts
 * → Generate new private key. Place the file in the server root directory.
 */

const logger = require('../utils/logger');

let _messaging = null;

function _initMessaging() {
  if (_messaging) return _messaging;

  try {
    // firebase-admin auto-reads GOOGLE_APPLICATION_CREDENTIALS env var
    const admin = require('firebase-admin');

    if (admin.apps.length === 0) {
      admin.initializeApp({
        credential: admin.credential.applicationDefault(),
      });
    }

    _messaging = admin.messaging();
    logger.info('FCM: Firebase Admin initialised — push notifications enabled');
  } catch (err) {
    logger.warn(
      `FCM: Firebase Admin NOT initialised (${err.message}). ` +
        'Set GOOGLE_APPLICATION_CREDENTIALS to enable push notifications.'
    );
    _messaging = null;
  }

  return _messaging;
}

/**
 * Send a high-priority VoIP data-only notification to a device.
 *
 * @param {string} fcmToken  - Target device's FCM registration token
 * @param {string} callerId  - UserId of the caller
 * @param {string} roomId    - Signaling room created for this call
 */
async function sendVoIPPush(fcmToken, callerId, roomId) {
  if (!fcmToken) return;

  const messaging = _initMessaging();
  if (!messaging) return;

  const message = {
    token: fcmToken,
    // data-only so onBackgroundMessage fires even when app is killed
    data: {
      type: 'incoming_voip_call',
      callerId,
      roomId,
    },
    android: {
      priority: 'high',
      ttl: 30 * 1000, // 30 seconds — discard if undelivered
    },
  };

  try {
    const response = await messaging.send(message);
    logger.info(`FCM: push sent to ${callerId} → ${response}`);
  } catch (err) {
    logger.warn(`FCM: push failed for token ...${fcmToken.slice(-8)}: ${err.message}`);
  }
}

module.exports = { sendVoIPPush };
