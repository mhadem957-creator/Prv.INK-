import 'dart:io';

import 'package:android_intent_plus/android_intent.dart';
import 'package:flutter/foundation.dart';

/// Deep-links into Android system settings screens.
class SystemSettingsService {
  static Future<void> openPrivateDnsSettings() async {
    if (!Platform.isAndroid) return;
    try {
      const intent = AndroidIntent(
        action: 'android.settings.WIFI_PRIVATE_DNS_SETTINGS',
      );
      await intent.launch();
    } catch (e) {
      debugPrint('Could not open Private DNS settings, trying fallback: $e');
      try {
        const fallback = AndroidIntent(
          action: 'android.settings.NETWORK_OPERATOR_SETTINGS',
        );
        await fallback.launch();
      } catch (e2) {
        debugPrint('Could not open network settings either: $e2');
      }
    }
  }

  /// Opens the system VPN screen so the user can hide their real IP.
  static Future<void> openVpnSettings() async {
    if (!Platform.isAndroid) return;
    try {
      const intent = AndroidIntent(
        action: 'android.settings.VPN_SETTINGS',
      );
      await intent.launch();
    } catch (e) {
      debugPrint('VPN settings failed: $e');
      try {
        const fallback = AndroidIntent(
          action: 'android.settings.SETTINGS',
        );
        await fallback.launch();
      } catch (e2) {
        debugPrint('Could not open settings: $e2');
      }
    }
  }
}
