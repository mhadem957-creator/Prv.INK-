import 'package:flutter_inappwebview/flutter_inappwebview.dart';

import '../models/browser_settings.dart';
import '../services/adblock_service.dart';
import 'privacy_scripts.dart';

/// Helpers that inject privacy / theming scripts into a WebView.
class WebViewPrivacy {
  WebViewPrivacy._();

  static bool isSearxUrl(String? url) {
    if (url == null || url.isEmpty) return false;
    final u = url.toLowerCase();
    return u.contains('searx') || (u.contains('/search?') && u.contains('q='));
  }

  static bool isHomeUrl(String? url) {
    if (url == null || url.isEmpty) return false;
    final s = url.trim().toLowerCase();
    return s == 'about:ink' ||
        s == 'about:home' ||
        s == 'ink://home' ||
        s.startsWith('https://ink.local') ||
        s.startsWith('http://ink.local');
  }

  /// Human-friendly text for the address bar.
  static String displayUrl(String url) {
    if (url == 'about:ink' ||
        url == 'about:home' ||
        url.startsWith('https://ink.local')) {
      return '';
    }
    if (isSearxUrl(url)) {
      try {
        final q = Uri.parse(url).queryParameters['q'];
        if (q != null && q.isNotEmpty) return q;
      } catch (_) {}
      return 'Search';
    }
    return url;
  }

  static Future<void> cloakSearx(InAppWebViewController controller) async {
    try {
      await controller.evaluateJavascript(source: searxCloakRuntimeJs);
    } catch (_) {}
  }

  static Future<void> injectPrivacyGuards(
    InAppWebViewController controller,
    BrowserSettings settings,
  ) async {
    try {
      if (settings.blockWebRtc) {
        await controller.evaluateJavascript(source: webrtcBlockJs);
      }
      if (settings.fingerprintGuard) {
        await controller.evaluateJavascript(source: fingerprintGuardJs);
      }
    } catch (_) {}
  }

  static Future<void> injectForceDark(InAppWebViewController controller) async {
    try {
      await controller.evaluateJavascript(source: forceDarkJs);
    } catch (_) {}
  }

  static Future<void> injectHideMedia(InAppWebViewController controller) async {
    try {
      await controller.evaluateJavascript(source: hideMediaJs);
    } catch (_) {}
  }

  static Future<void> applyContentBlockers(
    InAppWebViewController controller,
    BrowserSettings settings,
  ) async {
    final blockers = await AdBlockService.instance.buildContentBlockers(
      blockAds: settings.adBlockEnabled,
      blockTrackers: settings.trackerBlockEnabled,
    );
    await controller.setSettings(
      settings: InAppWebViewSettings(contentBlockers: blockers),
    );
  }

  /// Early scripts that run at document start.
  static Future<void> onWebViewCreated(
    InAppWebViewController controller,
    BrowserSettings settings,
  ) async {
    try {
      await controller.addUserScript(
        userScript: UserScript(
          source: searxCloakJs,
          injectionTime: UserScriptInjectionTime.AT_DOCUMENT_START,
        ),
      );
    } catch (_) {}
    await applyContentBlockers(controller, settings);
    await injectPrivacyGuards(controller, settings);
  }

  /// Scripts that run after a page finishes loading.
  static Future<void> onLoadStop(
    InAppWebViewController controller,
    String url,
    BrowserSettings settings, {
    required void Function(String title) onTitleChanged,
  }) async {
    if (isSearxUrl(url) && settings.cloakSearchBranding) {
      await cloakSearx(controller);
      onTitleChanged('Ink Search');
    }
    await injectPrivacyGuards(controller, settings);
    if (settings.forceDarkPages) {
      await injectForceDark(controller);
    }
    if (!settings.loadImages) {
      await injectHideMedia(controller);
    }
  }
}
