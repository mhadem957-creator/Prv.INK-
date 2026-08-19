import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:provider/provider.dart';

import '../models/browser_settings.dart';
import '../models/browser_tab.dart';
import '../services/history_service.dart';
import '../theme/manga_theme.dart';
import 'privacy_scripts.dart';
import 'webview_privacy.dart';

/// Callbacks that the parent [BrowserScreen] needs to react to WebView events.
typedef WebViewScrollCallback = void Function(int x, int y);
typedef WebViewDownloadCallback = Future<void> Function(
  String url,
  String? suggestedFileName,
);

/// Encapsulates a single tab's [InAppWebView] with all privacy + download logic.
class InkWebView extends StatefulWidget {
  const InkWebView({
    super.key,
    required this.tab,
    required this.isActive,
    required this.onUrlChanged,
    required this.onLoadingChanged,
    required this.onProgressChanged,
    required this.onScrollChanged,
    required this.onDownloadRequest,
    required this.shouldOverrideUrlLoading,
  });

  final BrowserTab tab;
  final bool isActive;

  /// Called when the loaded URL changes (only for the active tab the parent cares about).
  final void Function(String url, String displayUrl) onUrlChanged;

  final void Function(bool isLoading) onLoadingChanged;
  final void Function(double progress) onProgressChanged;
  final WebViewScrollCallback onScrollChanged;
  final WebViewDownloadCallback onDownloadRequest;

  final Future<NavigationActionPolicy?> Function(
    InAppWebViewController controller,
    NavigationAction action,
  ) shouldOverrideUrlLoading;

  @override
  State<InkWebView> createState() => _InkWebViewState();
}

class _InkWebViewState extends State<InkWebView> {
  @override
  Widget build(BuildContext context) {
    final settings = context.read<BrowserSettings>();
    final tab = widget.tab;

    return InAppWebView(
      initialUrlRequest: URLRequest(
        url: WebUri(
          tab.url.isEmpty || WebViewPrivacy.isHomeUrl(tab.url)
              ? 'about:blank'
              : tab.url,
        ),
      ),
      initialSettings: InAppWebViewSettings(
        javaScriptEnabled: settings.javascriptEnabled,
        cacheEnabled: true,
        supportZoom: true,
        transparentBackground: true,
        mediaPlaybackRequiresUserGesture: settings.mediaRequiresGesture,
        userAgent: settings.desktopMode ? desktopUserAgent : null,
        useShouldOverrideUrlLoading: true,
        useOnDownloadStart: true,
        supportMultipleWindows: !settings.blockPopups,
        mixedContentMode: MixedContentMode.MIXED_CONTENT_COMPATIBILITY_MODE,
        useOnLoadResource: false,
        verticalScrollBarEnabled: true,
        preferredContentMode: UserPreferredContentMode.MOBILE,
        allowsInlineMediaPlayback: true,
        allowsBackForwardNavigationGestures: true,
        domStorageEnabled: true,
        databaseEnabled: true,
        thirdPartyCookiesEnabled: true,
        loadWithOverviewMode: true,
        useWideViewPort: true,
        builtInZoomControls: true,
        displayZoomControls: false,
        safeBrowsingEnabled: false,
        allowFileAccess: true,
        allowContentAccess: true,
        hardwareAcceleration: true,
      ),
      onWebViewCreated: (controller) async {
        tab.controller = controller;
        await WebViewPrivacy.onWebViewCreated(controller, settings);
      },
      shouldOverrideUrlLoading: widget.shouldOverrideUrlLoading,
      onLoadStart: (controller, url) {
        final u = url?.toString() ?? '';

        if (u == 'about:blank' || u.startsWith('data:')) {
          if (widget.isActive) widget.onLoadingChanged(true);
          return;
        }

        if (WebViewPrivacy.isHomeUrl(u) ||
            tab.url == 'about:ink' ||
            tab.url == 'about:home') {
          if (WebViewPrivacy.isHomeUrl(u) || u.startsWith('https://ink.local')) {
            tab.url = 'about:ink';
            tab.title = 'Ink';
          }
          if (widget.isActive) {
            widget.onLoadingChanged(true);
            widget.onUrlChanged('about:ink', '');
          }
          return;
        }

        tab.url = u;
        if (!widget.isActive) return;
        widget.onLoadingChanged(true);
        widget.onUrlChanged(tab.url, WebViewPrivacy.displayUrl(tab.url));
      },
      onLoadStop: (controller, url) async {
        final u = url?.toString() ?? '';

        if (u == 'about:blank' ||
            u.startsWith('data:') ||
            WebViewPrivacy.isHomeUrl(u) ||
            tab.url == 'about:ink' ||
            tab.url == 'about:home') {
          if (WebViewPrivacy.isHomeUrl(u) ||
              u.startsWith('https://ink.local') ||
              tab.url == 'about:ink' ||
              tab.url == 'about:home') {
            tab.url = 'about:ink';
            tab.title = 'Ink';
          }
          if (!mounted || !widget.isActive) return;
          widget.onLoadingChanged(false);
          widget.onUrlChanged('about:ink', '');
          return;
        }

        tab.url = u.isNotEmpty ? u : tab.url;
        tab.title = await controller.getTitle() ?? tab.url;

        await WebViewPrivacy.onLoadStop(
          controller,
          tab.url,
          settings,
          onTitleChanged: (t) => tab.title = t,
        );

        // Record history (skipped when incognito / disabled)
        await HistoryService.instance.add(
          url: tab.url,
          title: tab.title,
          incognito: settings.incognitoMode || !settings.saveHistory,
        );

        if (!mounted || !widget.isActive) return;
        widget.onLoadingChanged(false);
        widget.onUrlChanged(tab.url, WebViewPrivacy.displayUrl(tab.url));
      },
      onProgressChanged: (controller, progress) {
        if (!widget.isActive) return;
        widget.onProgressChanged(progress / 100);
      },
      onScrollChanged: (controller, x, y) {
        widget.onScrollChanged(x, y);
      },
      onReceivedError: (controller, request, error) {
        if (!widget.isActive) return;
        widget.onLoadingChanged(false);
      },
      onTitleChanged: (controller, title) {
        if (title != null) tab.title = title;
      },
      onDownloadStartRequest: (controller, request) async {
        final url = request.url.toString();
        final suggested = request.suggestedFilename;
        await widget.onDownloadRequest(url, suggested);
      },
    );
  }
}

/// Simple confirmation dialog used before starting a download.
Future<bool?> showDownloadConfirmDialog(BuildContext context, String displayName) {
  return showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      backgroundColor: MangaTheme.paperOf(context),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.zero,
        side: BorderSide(color: MangaTheme.inkOf(context), width: 4),
      ),
      title: const Text(
        'DOWNLOAD?',
        style: TextStyle(fontWeight: FontWeight.w900, letterSpacing: 1),
      ),
      content: Text(
        displayName,
        style: const TextStyle(fontWeight: FontWeight.w600),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx, false),
          child: const Text('CANCEL', style: TextStyle(fontWeight: FontWeight.w800)),
        ),
        ElevatedButton(
          onPressed: () => Navigator.pop(ctx, true),
          child: const Text('DOWNLOAD'),
        ),
      ],
    ),
  );
}
