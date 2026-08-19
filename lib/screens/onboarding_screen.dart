import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/browser_settings.dart';
import '../theme/manga_theme.dart';
import '../widgets/manga_container.dart';

/// First-launch walkthrough. Manga-ink style, 4 pages + finish.
class OnboardingScreen extends StatefulWidget {
  const OnboardingScreen({super.key, required this.onFinished});

  final VoidCallback onFinished;

  @override
  State<OnboardingScreen> createState() => _OnboardingScreenState();
}

class _OnboardingScreenState extends State<OnboardingScreen> {
  final PageController _pageController = PageController();
  int _page = 0;

  static const _pages = <_OnboardPage>[
    _OnboardPage(
      icon: Icons.shield_outlined,
      title: 'PRIVATE. FAST.\nYOURS.',
      body:
          'INK is a privacy-first browser. No telemetry, no account, no tracking by design.',
      accent: 'Zero data sold. Ever.',
    ),
    _OnboardPage(
      icon: Icons.search,
      title: 'SEARCH WITHOUT\nTHE SURVEILLANCE',
      body:
          'Type anything that isn’t a URL and it goes to SearXNG — a metasearch engine that doesn’t profile you.',
      accent: 'You can change the instance in Settings.',
    ),
    _OnboardPage(
      icon: Icons.block,
      title: 'ADS & TRACKERS\nBLOCKED',
      body:
          'Strong domain-based blocking is on by default. Lists are human-readable and editable.',
      accent: 'You stay in control of what loads.',
    ),
    _OnboardPage(
      icon: Icons.lock_outline,
      title: 'YOUR BROWSER,\nYOUR RULES',
      body:
          'Force HTTPS, block WebRTC IP leaks, fingerprint guard, optional biometric lock, and clear-on-exit.',
      accent: 'Everything you expect. Nothing you don’t.',
    ),
  ];

  @override
  void dispose() {
    _pageController.dispose();
    super.dispose();
  }

  Future<void> _finish() async {
    final settings = context.read<BrowserSettings>();
    await settings.completeOnboarding();
    widget.onFinished();
  }

  void _next() {
    if (_page < _pages.length - 1) {
      _pageController.nextPage(
        duration: const Duration(milliseconds: 280),
        curve: Curves.easeOutCubic,
      );
    } else {
      _finish();
    }
  }

  @override
  Widget build(BuildContext context) {
    final paper = MangaTheme.paperOf(context);
    final ink = MangaTheme.inkOf(context);
    final isLast = _page == _pages.length - 1;

    return Scaffold(
      backgroundColor: paper,
      body: SafeArea(
        child: Column(
          children: [
            // Skip
            Align(
              alignment: Alignment.centerRight,
              child: TextButton(
                onPressed: _finish,
                child: Text(
                  'SKIP',
                  style: TextStyle(
                    fontWeight: FontWeight.w800,
                    letterSpacing: 1.2,
                    color: MangaTheme.inkDimOf(context),
                  ),
                ),
              ),
            ),

            Expanded(
              child: PageView.builder(
                controller: _pageController,
                itemCount: _pages.length,
                onPageChanged: (i) => setState(() => _page = i),
                itemBuilder: (context, i) {
                  final p = _pages[i];
                  return Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 28),
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        MangaContainer(
                          padding: const EdgeInsets.all(28),
                          child: Icon(
                            p.icon,
                            size: 72,
                            color: MangaTheme.crimson,
                          ),
                        ),
                        const SizedBox(height: 36),
                        Text(
                          p.title,
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            fontSize: 28,
                            fontWeight: FontWeight.w900,
                            height: 1.15,
                            letterSpacing: 0.5,
                            color: ink,
                          ),
                        ),
                        const SizedBox(height: 20),
                        Text(
                          p.body,
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            fontSize: 16,
                            height: 1.45,
                            fontWeight: FontWeight.w600,
                            color: MangaTheme.inkDimOf(context),
                          ),
                        ),
                        const SizedBox(height: 16),
                        Text(
                          p.accent,
                          textAlign: TextAlign.center,
                          style: const TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.w800,
                            color: MangaTheme.crimson,
                            letterSpacing: 0.3,
                          ),
                        ),
                      ],
                    ),
                  );
                },
              ),
            ),

            // Dots
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: List.generate(_pages.length, (i) {
                final active = i == _page;
                return AnimatedContainer(
                  duration: const Duration(milliseconds: 200),
                  margin: const EdgeInsets.symmetric(horizontal: 4),
                  width: active ? 28 : 10,
                  height: 10,
                  decoration: BoxDecoration(
                    color: active ? MangaTheme.crimson : ink.withOpacity(0.25),
                    border: Border.all(color: ink, width: 2),
                  ),
                );
              }),
            ),
            const SizedBox(height: 28),

            // CTA
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
              child: SizedBox(
                width: double.infinity,
                height: 56,
                child: ElevatedButton(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: MangaTheme.crimson,
                    foregroundColor: paper,
                    elevation: 0,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.zero,
                      side: BorderSide(color: ink, width: 3),
                    ),
                    shadowColor: ink,
                  ),
                  onPressed: _next,
                  child: Text(
                    isLast ? 'START BROWSING' : 'NEXT',
                    style: const TextStyle(
                      fontWeight: FontWeight.w900,
                      letterSpacing: 1.4,
                      fontSize: 16,
                    ),
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

class _OnboardPage {
  const _OnboardPage({
    required this.icon,
    required this.title,
    required this.body,
    required this.accent,
  });

  final IconData icon;
  final String title;
  final String body;
  final String accent;
}
