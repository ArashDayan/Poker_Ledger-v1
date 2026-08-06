import 'package:flutter/material.dart';

import '../../core/theme/app_theme.dart';
import '../../widgets/poker_chip_logo.dart';

/// Brand splash shown while the app settles on launch.
///
/// Implemented in-app rather than via a native splash package: adding
/// `flutter_native_splash` would mean a new dependency and regenerating
/// platform folders this repo doesn't check in. This gives the same
/// first impression — the brand mark on felt, then a fade into the app —
/// with no build-system changes.
///
/// It is deliberately brief and never blocks: [onFinished] fires after
/// the animation regardless, so a slow frame can't strand the banker on
/// a logo screen when they need to record a buy-in.
class SplashScreen extends StatefulWidget {
  final Widget child;
  const SplashScreen({super.key, required this.child});

  @override
  State<SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends State<SplashScreen>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  late final Animation<double> _logoFade;
  late final Animation<double> _logoScale;
  late final Animation<double> _textFade;
  bool _done = false;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1500),
    );

    _logoFade = CurvedAnimation(
      parent: _controller,
      curve: const Interval(0.0, 0.45, curve: Curves.easeOut),
    );
    _logoScale = Tween<double>(begin: 0.86, end: 1.0).animate(
      CurvedAnimation(
        parent: _controller,
        curve: const Interval(0.0, 0.6, curve: Curves.easeOutBack),
      ),
    );
    _textFade = CurvedAnimation(
      parent: _controller,
      curve: const Interval(0.35, 0.7, curve: Curves.easeOut),
    );

    _controller.forward().whenComplete(() {
      if (mounted) setState(() => _done = true);
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 420),
      child: _done
          ? widget.child
          : Scaffold(
              key: const ValueKey('splash'),
              backgroundColor: AppColors.background,
              body: Container(
                decoration: const BoxDecoration(
                  gradient: RadialGradient(
                    center: Alignment(0, -0.25),
                    radius: 1.1,
                    colors: [
                      Color(0xFF1A3A2C),
                      AppColors.background,
                    ],
                    stops: [0.0, 0.95],
                  ),
                ),
                child: Center(
                  child: AnimatedBuilder(
                    animation: _controller,
                    builder: (context, _) => Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        FadeTransition(
                          opacity: _logoFade,
                          child: ScaleTransition(
                            scale: _logoScale,
                            child: const PokerChipLogo(size: 190),
                          ),
                        ),
                        const SizedBox(height: 26),
                        FadeTransition(
                          opacity: _textFade,
                          child: Column(
                            children: [
                              const PokerLedgerWordmark(fontSize: 22),
                              const SizedBox(height: 8),
                              const GoldDivider(width: 120),
                              const SizedBox(height: 10),
                              Text(
                                'Track Every Chip. Trust Every Session.',
                                style: TextStyle(
                                  fontSize: 11.5,
                                  letterSpacing: 0.4,
                                  color: AppColors.textSecondary
                                      .withValues(alpha: 0.9),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
    );
  }
}
