import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Builds WebView [ContentBlocker] rules from bundled domain lists + user
/// custom domains.
///
/// Lists are derived from EasyList (ads) and EasyPrivacy (trackers)
/// network rules (`||domain^`), plus the original curated INK entries.
/// Cosmetic filters (`##`) are not supported by WebView ContentBlockers.
///
/// Uses flutter_inappwebview's ContentBlocker API
/// (WKContentRuleList on iOS / request filtering on Android).
class AdBlockService {
  AdBlockService._();
  static final AdBlockService instance = AdBlockService._();

  static const String _prefsCustomDomains = 'pref_adblock_custom_domains';

  List<String>? _adDomains;
  List<String>? _trackerDomains;
  List<String> _customDomains = [];

  /// Cached blockers so we don't rebuild on every tab.
  List<ContentBlocker>? _cachedBlockers;
  bool? _cachedBlockAds;
  bool? _cachedBlockTrackers;
  int _cacheVersion = 0;
  int _listVersion = 0;

  int get adDomainCount => _adDomains?.length ?? 0;
  int get trackerDomainCount => _trackerDomains?.length ?? 0;
  int get customDomainCount => _customDomains.length;
  List<String> get customDomains => List.unmodifiable(_customDomains);

  Future<void> _ensureLoaded() async {
    if (_adDomains != null && _trackerDomains != null) return;
    _adDomains = await _loadList('assets/adblock/ad_domains.txt');
    _trackerDomains = await _loadList('assets/adblock/tracker_domains.txt');
    await _loadCustomDomains();
    _listVersion++;
  }

  Future<List<String>> _loadList(String assetPath) async {
    final raw = await rootBundle.loadString(assetPath);
    return raw
        .split('\n')
        .map((line) => line.trim())
        .where((line) => line.isNotEmpty && !line.startsWith('#'))
        .map(_normalizeDomain)
        .where((d) => d.isNotEmpty)
        .toSet() // dedupe
        .toList()
      ..sort();
  }

  Future<void> _loadCustomDomains() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getStringList(_prefsCustomDomains) ?? [];
    _customDomains = raw
        .map(_normalizeDomain)
        .where((d) => d.isNotEmpty)
        .toSet()
        .toList()
      ..sort();
  }

  Future<void> _saveCustomDomains() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(_prefsCustomDomains, _customDomains);
  }

  /// Strip scheme, path, www. and lowercase.
  static String _normalizeDomain(String input) {
    var d = input.trim().toLowerCase();
    if (d.startsWith('http://')) d = d.substring(7);
    if (d.startsWith('https://')) d = d.substring(8);
    if (d.startsWith('www.')) d = d.substring(4);
    // Keep only host part
    final slash = d.indexOf('/');
    if (slash != -1) d = d.substring(0, slash);
    final colon = d.indexOf(':');
    if (colon != -1) d = d.substring(0, colon);
    // Very basic sanity
    if (d.isEmpty || !d.contains('.') || d.startsWith('.')) return '';
    return d;
  }

  /// Add a custom domain to the blocklist. Returns true if added.
  Future<bool> addCustomDomain(String domain) async {
    await _ensureLoaded();
    final d = _normalizeDomain(domain);
    if (d.isEmpty) return false;
    if (_customDomains.contains(d)) return false;
    _customDomains.add(d);
    _customDomains.sort();
    await _saveCustomDomains();
    _invalidateCache();
    return true;
  }

  /// Remove a custom domain. Returns true if removed.
  Future<bool> removeCustomDomain(String domain) async {
    await _ensureLoaded();
    final d = _normalizeDomain(domain);
    final removed = _customDomains.remove(d);
    if (removed) {
      await _saveCustomDomains();
      _invalidateCache();
    }
    return removed;
  }

  void _invalidateCache() {
    _cachedBlockers = null;
    _cachedBlockAds = null;
    _cachedBlockTrackers = null;
    _listVersion++;
  }

  /// Build a better urlFilter for ContentBlocker.
  ///
  /// Uses a pattern that matches the domain as a host component rather than
  /// a free-floating substring (reduces false positives like matching
  /// "ads.com" inside "roads.com").
  static String _urlFilterForDomain(String domain) {
    final escaped = RegExp.escape(domain);
    // Match domain as full host or subdomain:
    //   https://domain/...
    //   https://sub.domain/...
    //   //domain/...
    return r'^https?://([^/]*\.)?' + escaped + r'([:/?]|$)';
  }

  /// Returns the content blocker list for the current toggles.
  /// Results are cached until toggles or lists change.
  Future<List<ContentBlocker>> buildContentBlockers({
    required bool blockAds,
    required bool blockTrackers,
  }) async {
    await _ensureLoaded();

    if (_cachedBlockers != null &&
        _cachedBlockAds == blockAds &&
        _cachedBlockTrackers == blockTrackers &&
        _cacheVersion == _listVersion) {
      return _cachedBlockers!;
    }

    final domains = <String>{
      if (blockAds) ..._adDomains!,
      if (blockTrackers) ..._trackerDomains!,
      // Custom domains always apply when either blocker is on
      if (blockAds || blockTrackers) ..._customDomains,
    };

    final blockers = domains
        .map(
          (domain) => ContentBlocker(
            trigger: ContentBlockerTrigger(
              urlFilter: _urlFilterForDomain(domain),
            ),
            action: const ContentBlockerAction(
              type: ContentBlockerActionType.BLOCK,
            ),
          ),
        )
        .toList();

    _cachedBlockers = blockers;
    _cachedBlockAds = blockAds;
    _cachedBlockTrackers = blockTrackers;
    _cacheVersion = _listVersion;

    if (kDebugMode) {
      debugPrint(
        'INK AdBlock: built ${blockers.length} rules '
        '(ads=${blockAds ? adDomainCount : 0}, '
        'trackers=${blockTrackers ? trackerDomainCount : 0}, '
        'custom=$customDomainCount)',
      );
    }

    return blockers;
  }

  /// Force reload lists from assets (e.g. after an update).
  Future<void> reloadLists() async {
    _adDomains = null;
    _trackerDomains = null;
    _invalidateCache();
    await _ensureLoaded();
  }

  /// Stats useful for Settings UI.
  Future<Map<String, int>> stats() async {
    await _ensureLoaded();
    return {
      'ads': adDomainCount,
      'trackers': trackerDomainCount,
      'custom': customDomainCount,
      'total': adDomainCount + trackerDomainCount + customDomainCount,
    };
  }
}
