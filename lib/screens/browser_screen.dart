import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show SystemNavigator;
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:provider/provider.dart';

import '../browser/ink_webview.dart';
import '../browser/webview_privacy.dart';
import '../models/browser_settings.dart';
import '../models/browser_tab.dart';
import '../services/download_service.dart';
import '../services/history_service.dart';
import '../services/search_service.dart';
import '../services/storage_service.dart';
import '../theme/manga_theme.dart';
import '../widgets/ink_home_page.dart';
import '../widgets/manga_bottom_bar.dart';
import '../widgets/manga_url_bar.dart';
import 'downloads_screen.dart';
import 'history_screen.dart';
import 'settings_screen.dart';
import 'tabs_screen.dart';

/// Main browser screen: tab management + chrome UI + coordination.
///
/// Heavy WebView logic lives in [InkWebView] and [WebViewPrivacy].
class BrowserScreen extends StatefulWidget {
  const BrowserScreen({super.key});

  @override
  State<BrowserScreen> createState() => _BrowserScreenState();
}

class _BrowserScreenState extends State<BrowserScreen> {
  final List<BrowserTab> _tabs = [];
  int _currentIndex = 0;
  final TextEditingController _urlController = TextEditingController();
  final FocusNode _urlFocusNode = FocusNode();
  bool _isLoading = false;
  double _progress = 0;

  /// Address bar + progress chrome visibility (hide on scroll down).
  bool _chromeVisible = true;
  int _lastScrollY = 0;

  /// Double-back-to-exit tracking for the system back button.
  DateTime? _lastBackPress;

  BrowserTab get _currentTab => _tabs[_currentIndex];

  void _safeSetState(VoidCallback fn) {
    if (!mounted) return;
    setState(fn);
  }

  @override
  void initState() {
    super.initState();
    DownloadService.instance.initialize();
    HistoryService.instance.load();
    _urlFocusNode.addListener(_onUrlFocusChange);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final settings = context.read<BrowserSettings>();
      final home = settings.homePage.trim().isEmpty
          ? 'about:ink'
          : settings.homePage;
      _openNewTab(url: home);
    });
  }

  void _onUrlFocusChange() {
    if (_urlFocusNode.hasFocus && !_chromeVisible) {
      _safeSetState(() => _chromeVisible = true);
    }
  }

  void _handleWebScroll(int x, int y) {
    // Always show near the top, or while typing a URL.
    if (y <= 48 || _urlFocusNode.hasFocus) {
      if (!_chromeVisible) {
        _safeSetState(() => _chromeVisible = true);
      }
      _lastScrollY = y;
      return;
    }
    final dy = y - _lastScrollY;
    if (dy > 24 && _chromeVisible) {
      _safeSetState(() => _chromeVisible = false);
      _lastScrollY = y;
    } else if (dy < -24 && !_chromeVisible) {
      _safeSetState(() => _chromeVisible = true);
      _lastScrollY = y;
    } else if (dy.abs() > 80) {
      _lastScrollY = y;
    }
  }

  @override
  void dispose() {
    try {
      if (mounted) {
        final settings = context.read<BrowserSettings>();
        if (settings.clearDataOnExit) {
          StorageService.clearAllBrowsingData();
        }
      }
    } catch (_) {}
    _urlFocusNode.removeListener(_onUrlFocusChange);
    _urlController.dispose();
    _urlFocusNode.dispose();
    super.dispose();
  }

  // ---------------------------------------------------------------------------
  // Tab management
  // ---------------------------------------------------------------------------

  void _openNewTab({String? url}) {
    final settings = context.read<BrowserSettings>();
    final tab = BrowserTab(
      id: DateTime.now().microsecondsSinceEpoch.toString(),
      url: url ?? settings.homePage,
    );
    setState(() {
      _tabs.add(tab);
      _currentIndex = _tabs.length - 1;
      _urlController.text = tab.url;
      _chromeVisible = true;
      _lastScrollY = 0;
    });
  }

  Future<void> _closeTab(int index) async {
    if (_tabs.length == 1) {
      setState(() {
        _tabs[0] = BrowserTab(
          id: _tabs[0].id,
          url: 'about:ink',
          title: 'Ink',
        );
        _currentIndex = 0;
        _urlController.text = '';
        _chromeVisible = true;
      });
      return;
    }
    setState(() {
      _tabs.removeAt(index);
      if (_currentIndex >= _tabs.length) {
        _currentIndex = _tabs.length - 1;
      } else if (index < _currentIndex) {
        _currentIndex--;
      }
      _urlController.text = WebViewPrivacy.displayUrl(_currentTab.url);
      _chromeVisible = true;
    });
  }

  void _switchTab(int index) {
    if (index < 0 || index >= _tabs.length) return;
    setState(() {
      _currentIndex = index;
      _urlController.text = WebViewPrivacy.displayUrl(_currentTab.url);
      _chromeVisible = true;
      _lastScrollY = 0;
      _isLoading = false;
    });
  }

  // ---------------------------------------------------------------------------
  // Navigation / URL handling
  // ---------------------------------------------------------------------------

  Future<void> _handleSubmitted(String input) async {
    final trimmed = input.trim();
    if (trimmed.isEmpty ||
        trimmed == 'about:ink' ||
        trimmed == 'about:home' ||
        trimmed == 'ink://home') {
      setState(() {
        _currentTab.url = 'about:ink';
        _currentTab.title = 'Ink';
        _currentTab.controller = null;
        _urlController.text = '';
        _isLoading = false;
        _chromeVisible = true;
      });
      _urlFocusNode.unfocus();
      return;
    }

    final settings = context.read<BrowserSettings>();
    final searchService = SearchService(
      settings.searxngUrl,
      safeSearch: settings.safeSearch,
    );
    var resolved = searchService.resolveInput(trimmed);
    if (resolved.isEmpty) return;
    if (settings.forceHttps && resolved.startsWith('http://')) {
      resolved = 'https://${resolved.substring(7)}';
    }

    _urlFocusNode.unfocus();
    final controller = _currentTab.controller;
    if (controller != null) {
      await controller.loadUrl(urlRequest: URLRequest(url: WebUri(resolved)));
    } else {
      setState(() => _currentTab.url = resolved);
    }
  }

  Future<NavigationActionPolicy?> _shouldOverrideUrlLoading(
    InAppWebViewController controller,
    NavigationAction action,
  ) async {
    final url = action.request.url?.toString() ?? '';
    if (url.isEmpty) return NavigationActionPolicy.ALLOW;

    final downloadService = DownloadService.instance;
    if (downloadService.isDownloadableUrl(url)) {
      final confirmed = await showDownloadConfirmDialog(
        context,
        Uri.parse(url).pathSegments.isNotEmpty
            ? Uri.parse(url).pathSegments.last
            : url,
      );
      if (confirmed == true) {
        final taskId = await downloadService.enqueue(url: url);
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(
                taskId != null
                    ? 'Download started: ${Uri.parse(url).pathSegments.isNotEmpty ? Uri.parse(url).pathSegments.last : "file"}'
                    : 'Download failed — check storage permission',
              ),
              action: SnackBarAction(
                label: 'VIEW',
                textColor: MangaTheme.crimson,
                onPressed: _showDownloadsScreen,
              ),
            ),
          );
        }
      }
      return NavigationActionPolicy.CANCEL;
    }
    return NavigationActionPolicy.ALLOW;
  }

  Future<void> _onDownloadRequest(String url, String? suggested) async {
    final displayName = (suggested != null && suggested.isNotEmpty)
        ? suggested
        : (Uri.tryParse(url)?.pathSegments.isNotEmpty == true
            ? Uri.parse(url).pathSegments.last
            : 'file');
    final confirmed = await showDownloadConfirmDialog(context, displayName);
    if (confirmed == true) {
      final taskId = await DownloadService.instance.enqueue(
        url: url,
        fileName: suggested,
      );
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              taskId != null
                  ? 'Download started: $displayName'
                  : 'Download failed to start',
            ),
            action: SnackBarAction(
              label: 'VIEW',
              textColor: MangaTheme.crimson,
              onPressed: _showDownloadsScreen,
            ),
          ),
        );
      }
    }
  }

  // ---------------------------------------------------------------------------
  // Chrome actions
  // ---------------------------------------------------------------------------

  Future<void> _goBack() async {
    final controller = _currentTab.controller;
    if (controller != null && await controller.canGoBack()) {
      await controller.goBack();
    }
  }

  Future<void> _goForward() async {
    final controller = _currentTab.controller;
    if (controller != null && await controller.canGoForward()) {
      await controller.goForward();
    }
  }

  Future<void> _reloadOrStop() async {
    final controller = _currentTab.controller;
    if (controller == null) return;
    if (_isLoading) {
      await controller.stopLoading();
    } else {
      await controller.reload();
    }
  }

  Future<void> _goHome() async {
    final settings = context.read<BrowserSettings>();
    await _handleSubmitted(settings.homePage);
  }

  /// Phone system back button / gesture:
  /// 1) WebView history back if possible
  /// 2) If not on home page → go home
  /// 3) If multiple tabs → close current tab
  /// 4) Double-press back within 2s → exit app
  Future<void> _onSystemBack() async {
    final controller = _currentTab.controller;
    if (controller != null) {
      try {
        if (await controller.canGoBack()) {
          await controller.goBack();
          return;
        }
      } catch (_) {}
    }

    final url = _currentTab.url.trim().toLowerCase();
    final onHome = url.isEmpty ||
        url == 'about:ink' ||
        url == 'about:blank' ||
        url.startsWith('ink://');
    if (!onHome) {
      _handleSubmitted('about:ink');
      return;
    }

    if (_tabs.length > 1) {
      await _closeTab(_currentIndex);
      return;
    }

    final now = DateTime.now();
    if (_lastBackPress != null &&
        now.difference(_lastBackPress!) < const Duration(seconds: 2)) {
      SystemNavigator.pop();
      return;
    }
    _lastBackPress = now;
    if (!mounted) return;
    ScaffoldMessenger.of(context).hideCurrentSnackBar();
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('اضغط مرة أخرى للخروج'),
        duration: Duration(seconds: 2),
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // Navigation to secondary screens
  // ---------------------------------------------------------------------------

  void _showTabsScreen() {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => TabsScreen(
          tabs: _tabs,
          currentIndex: _currentIndex,
          onSelect: (i) {
            Navigator.pop(context);
            _switchTab(i);
          },
          onClose: _closeTab,
          onNewTab: () {
            Navigator.pop(context);
            _openNewTab();
          },
        ),
      ),
    );
  }

  void _showSettingsScreen() {
    Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => const SettingsScreen()),
    );
  }

  void _showHistoryScreen() {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => HistoryScreen(
          onOpenUrl: (url) {
            _handleSubmitted(url);
          },
        ),
      ),
    );
  }

  void _showDownloadsScreen() {
    Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => const DownloadsScreen()),
    );
  }

  // ---------------------------------------------------------------------------
  // Build
  // ---------------------------------------------------------------------------

  Widget _buildTab(int index) {
    final tab = _tabs[index];
    if (WebViewPrivacy.isHomeUrl(tab.url)) {
      return KeyedSubtree(
        key: ValueKey('home-${tab.id}'),
        child: InkHomePage(
          onSearch: (q) {
            if (index == _currentIndex) _handleSubmitted(q);
          },
          onOpenUrl: (url) {
            if (index == _currentIndex) _handleSubmitted(url);
          },
        ),
      );
    }
    return KeyedSubtree(
      key: ValueKey(tab.id),
      child: InkWebView(
        tab: tab,
        isActive: index == _currentIndex,
        onUrlChanged: (url, display) {
          if (index != _currentIndex) return;
          _urlController.text = display;
        },
        onLoadingChanged: (loading) {
          if (index != _currentIndex) return;
          _safeSetState(() => _isLoading = loading);
        },
        onProgressChanged: (p) {
          if (index != _currentIndex) return;
          _safeSetState(() => _progress = p);
        },
        onScrollChanged: (x, y) {
          if (index != _currentIndex) return;
          _handleWebScroll(x, y);
        },
        onDownloadRequest: _onDownloadRequest,
        shouldOverrideUrlLoading: _shouldOverrideUrlLoading,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_tabs.isEmpty) {
      return Scaffold(
        backgroundColor: MangaTheme.paperOf(context),
        body: const Center(
          child: CircularProgressIndicator(color: MangaTheme.crimson),
        ),
      );
    }

    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (bool didPop, dynamic result) async {
        if (didPop) return;
        await _onSystemBack();
      },
      child: Scaffold(
        backgroundColor: MangaTheme.paperOf(context),
        body: Stack(
          children: [
            Positioned.fill(
              child: IndexedStack(
                index: _currentIndex,
                children: [
                  for (int i = 0; i < _tabs.length; i++) _buildTab(i),
                ],
              ),
            ),
            // Top chrome
            AnimatedSlide(
              duration: const Duration(milliseconds: 220),
              curve: Curves.easeOutCubic,
              offset: _chromeVisible ? Offset.zero : const Offset(0, -1),
              child: AnimatedOpacity(
                duration: const Duration(milliseconds: 180),
                opacity: _chromeVisible ? 1 : 0,
                child: Material(
                  elevation: 0,
                  color: MangaTheme.paperOf(context),
                  child: SafeArea(
                    bottom: false,
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        SizedBox(
                          height: kToolbarHeight,
                          child: Row(
                            children: [
                              const SizedBox(width: 8),
                              Expanded(
                                child: MangaUrlBar(
                                  controller: _urlController,
                                  focusNode: _urlFocusNode,
                                  isSecure:
                                      _currentTab.url.startsWith('https://'),
                                  onSubmitted: _handleSubmitted,
                                ),
                              ),
                              IconButton(
                                icon: Icon(
                                  Icons.add,
                                  color: MangaTheme.inkOf(context),
                                ),
                                tooltip: 'New tab',
                                onPressed: () => _openNewTab(),
                              ),
                              IconButton(
                                icon: Icon(
                                  Icons.settings_outlined,
                                  color: MangaTheme.inkOf(context),
                                ),
                                tooltip: 'Settings',
                                onPressed: _showSettingsScreen,
                              ),
                            ],
                          ),
                        ),
                        if (_isLoading)
                          LinearProgressIndicator(
                            value: _progress <= 0 ? null : _progress,
                            minHeight: 3,
                            backgroundColor: MangaTheme.paperMutedOf(context),
                            color: MangaTheme.crimson,
                          ),
                        Container(
                          height: 3,
                          color: MangaTheme.inkOf(context),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
            // Bottom chrome
            Align(
              alignment: Alignment.bottomCenter,
              child: AnimatedSlide(
                duration: const Duration(milliseconds: 220),
                curve: Curves.easeOutCubic,
                offset: _chromeVisible ? Offset.zero : const Offset(0, 1),
                child: AnimatedOpacity(
                  duration: const Duration(milliseconds: 180),
                  opacity: _chromeVisible ? 1 : 0,
                  child: MangaBottomBar(
                    onBack: _goBack,
                    onForward: _goForward,
                    onReload: _reloadOrStop,
                    onHome: _goHome,
                    isLoading: _isLoading,
                    tabCount: _tabs.length,
                    onTabsPressed: _showTabsScreen,
                    onHistoryPressed: _showHistoryScreen,
                    onDownloadsPressed: _showDownloadsScreen,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
