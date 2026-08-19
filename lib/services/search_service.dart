import '../utils/validators.dart';

/// Resolves address-bar input into either a navigable URL or a broad
/// internet search URL (SearXNG / bangs / DuckDuckGo fallback).
class SearchService {
  SearchService(this.searxngBaseUrl, {this.safeSearch = 0});

  final String searxngBaseUrl;
  final int safeSearch;

  /// Engines covering virtually every kind of public web content.
  static const String preferredEngines = [
    'google',
    'duckduckgo',
    'brave',
    'bing',
    'qwant',
    'startpage',
    'wikipedia',
    'wikidata',
    'youtube',
    'reddit',
    'github',
    'stackoverflow',
    'apple app store',
    'google play store',
  ].join(',');

  /// DuckDuckGo-style bangs → specialized destinations.
  static const Map<String, String> bangs = {
    '!g': 'https://www.google.com/search?q=',
    '!google': 'https://www.google.com/search?q=',
    '!ddg': 'https://duckduckgo.com/?q=',
    '!duckduckgo': 'https://duckduckgo.com/?q=',
    '!bing': 'https://www.bing.com/search?q=',
    '!y': 'https://www.youtube.com/results?search_query=',
    '!yt': 'https://www.youtube.com/results?search_query=',
    '!youtube': 'https://www.youtube.com/results?search_query=',
    '!w': 'https://en.wikipedia.org/wiki/Special:Search?search=',
    '!wiki': 'https://en.wikipedia.org/wiki/Special:Search?search=',
    '!gh': 'https://github.com/search?q=',
    '!github': 'https://github.com/search?q=',
    '!so': 'https://stackoverflow.com/search?q=',
    '!reddit': 'https://www.reddit.com/search/?q=',
    '!r': 'https://www.reddit.com/search/?q=',
    '!img': 'https://duckduckgo.com/?ia=images&iax=images&q=',
    '!images': 'https://duckduckgo.com/?ia=images&iax=images&q=',
    '!maps': 'https://www.openstreetmap.org/search?query=',
    '!tw': 'https://x.com/search?q=',
    '!x': 'https://x.com/search?q=',
    '!amazon': 'https://www.amazon.com/s?k=',
    '!apk': 'https://www.google.com/search?q=',
    '!news': 'https://news.google.com/search?q=',
  };

  String resolveInput(String rawInput) {
    final input = rawInput.trim();
    if (input.isEmpty) return '';

    // Bang shortcuts: "!yt lo-fi mix"
    final bangHit = _resolveBang(input);
    if (bangHit != null) return bangHit;

    if (UrlValidator.isLikelyUrl(input)) {
      return UrlValidator.normalize(input);
    }
    return buildSearchUrl(input);
  }

  String? _resolveBang(String input) {
    final lower = input.toLowerCase();
    // longest bang first so !google wins over !g when both match start
    final keys = bangs.keys.toList()
      ..sort((a, b) => b.length.compareTo(a.length));
    for (final bang in keys) {
      if (lower == bang || lower.startsWith('$bang ')) {
        final query = input.substring(bang.length).trim();
        if (query.isEmpty) return null;
        return '${bangs[bang]}${Uri.encodeQueryComponent(query)}';
      }
    }
    return null;
  }

  /// Broad multi-engine search via the configured SearXNG instance.
  String buildSearchUrl(String query) {
    final cleaned = query.trim().replaceAll(RegExp(r'\s+'), ' ');
    final encoded = Uri.encodeQueryComponent(cleaned);
    final root = _searchRoot(searxngBaseUrl);
    final ss = safeSearch.clamp(0, 2);

    // categories empty → instance default (usually all general sources)
    // engines list maximizes coverage across the public web
    return '$root$encoded'
        '&language=auto'
        '&time_range='
        '&safesearch=$ss'
        '&engines=$preferredEngines';
  }

  /// Direct DuckDuckGo fallback (used if user prefers or instance is down).
  static String duckDuckGoUrl(String query) {
    final encoded = Uri.encodeQueryComponent(query.trim());
    return 'https://duckduckgo.com/?q=$encoded&ia=web';
  }

  static String googleUrl(String query) {
    final encoded = Uri.encodeQueryComponent(query.trim());
    return 'https://www.google.com/search?q=$encoded&hl=en';
  }

  String _searchRoot(String base) {
    final b = base.trim();
    if (b.isEmpty) return 'https://searx.be/search?q=';
    if (RegExp(r'[?&][a-zA-Z_]+=$').hasMatch(b)) return b;
    if (b.endsWith('?') || b.endsWith('&')) return '${b}q=';
    if (b.contains('?')) return '$b&q=';
    return '$b?q=';
  }
}
