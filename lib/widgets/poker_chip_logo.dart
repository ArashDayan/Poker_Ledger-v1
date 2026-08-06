import 'dart:math' as math;

import 'package:flutter/material.dart';

/// The Poker Ledger brand mark.
///
/// This renders the supplied brand asset at `assets/images/logo.png` —
/// the real designed logo, not generated artwork. Everything in the app
/// (home hero, session AppBar, splash, poker table centre, launcher
/// icon) draws from that one file, so replacing it updates the whole app.
///
/// A painted fallback is kept ONLY as a safety net for the case where
/// the asset is missing or fails to decode. Without it a missing file
/// would render as a grey box or throw during layout; with it the app
/// still shows a recognisable chip. It is never used when the real asset
/// is present.
class PokerChipLogo extends StatelessWidget {
  final double size;

  /// Kept for API compatibility with existing call sites.
  final bool showFelt;

  const PokerChipLogo({super.key, this.size = 96, this.showFelt = true});

  /// The single source of truth for the brand asset path.
  static const String assetPath = 'assets/images/logo.png';

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: size,
      height: size,
      child: Image.asset(
        assetPath,
        width: size,
        height: size,
        fit: BoxFit.contain,
        filterQuality: FilterQuality.high,
        // If the brand asset is missing or corrupt, fall back to the
        // painted chip rather than showing a broken-image box.
        errorBuilder: (_, __, ___) => CustomPaint(
          size: Size(size, size),
          painter: _FallbackChipPainter(showFelt: showFelt),
        ),
      ),
    );
  }
}

/// Minimal painted chip used only if [PokerChipLogo.assetPath] cannot be
/// loaded. Deliberately simple — it exists to avoid a broken UI, not to
/// compete with the real brand mark.
class _FallbackChipPainter extends CustomPainter {
  final bool showFelt;
  _FallbackChipPainter({required this.showFelt});

  static const _gold = Color(0xFFD4AF37);
  static const _goldLight = Color(0xFFFFF3C4);
  static const _felt = Color(0xFF1B7A4C);
  static const _feltDark = Color(0xFF093A24);

  @override
  void paint(Canvas canvas, Size size) {
    final s = math.min(size.width, size.height);
    final c = Offset(size.width / 2, size.height / 2);
    final r = s / 2;
    final rect = Rect.fromCircle(center: c, radius: r);

    final gold = Paint()
      ..shader = const LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: [_goldLight, _gold, Color(0xFF8A6A18)],
      ).createShader(rect);

    canvas.drawCircle(c, r, gold);
    canvas.drawCircle(c, r * 0.965, Paint()..color = const Color(0xFF0B1A13));

    // Eight gold edge inlays.
    canvas.save();
    canvas.clipPath(Path()..addOval(Rect.fromCircle(center: c, radius: r * 0.965)));
    for (var k = 0; k < 8; k++) {
      final a = k * math.pi / 4;
      canvas.save();
      canvas.translate(c.dx + r * 0.9 * math.sin(a), c.dy - r * 0.9 * math.cos(a));
      canvas.rotate(a);
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromCenter(center: Offset.zero, width: r * 0.38, height: r * 0.3),
          Radius.circular(r * 0.08),
        ),
        gold,
      );
      canvas.restore();
    }
    canvas.restore();

    if (showFelt) {
      canvas.drawCircle(
        c,
        r * 0.86,
        Paint()
          ..shader = const RadialGradient(
            center: Alignment(-0.3, -0.45),
            colors: [_felt, _feltDark],
          ).createShader(Rect.fromCircle(center: c, radius: r * 0.86)),
      );
    }

    canvas.drawCircle(
      c,
      r * 0.66,
      Paint()
        ..shader = gold.shader
        ..style = PaintingStyle.stroke
        ..strokeWidth = math.max(1.5, s / 90),
    );
  }

  @override
  bool shouldRepaint(covariant _FallbackChipPainter old) =>
      old.showFelt != showFelt;
}

/// Gold gradient wordmark used beneath the chip on the home hero.
class PokerLedgerWordmark extends StatelessWidget {
  final double fontSize;
  const PokerLedgerWordmark({super.key, this.fontSize = 25});

  @override
  Widget build(BuildContext context) {
    return ShaderMask(
      shaderCallback: (rect) => const LinearGradient(
        colors: [Color(0xFFFFF3C4), Color(0xFFD4AF37), Color(0xFFB8922C)],
      ).createShader(rect),
      child: Text(
        'POKER LEDGER',
        style: TextStyle(
          fontSize: fontSize,
          fontWeight: FontWeight.w800,
          letterSpacing: fontSize * 0.2,
          color: Colors.white,
        ),
      ),
    );
  }
}

/// Convenience: the chip mark plus the wordmark and tagline.
class PokerLedgerHero extends StatelessWidget {
  final double logoSize;
  final Color subTextColor;

  const PokerLedgerHero({
    super.key,
    this.logoSize = 170,
    this.subTextColor = const Color(0xFF9AA6A0),
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        PokerChipLogo(size: logoSize),
        SizedBox(height: logoSize * 0.12),
        PokerLedgerWordmark(fontSize: logoSize * 0.15),
        const SizedBox(height: 6),
        Text(
          'Track Every Chip. Trust Every Session.',
          style: TextStyle(fontSize: 12, color: subTextColor, letterSpacing: 0.3),
        ),
      ],
    );
  }
}

/// Decorative gold divider used under the hero.
class GoldDivider extends StatelessWidget {
  final double width;
  const GoldDivider({super.key, this.width = 120});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: width,
      height: 1.2,
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          colors: [Colors.transparent, Color(0xFFD4AF37), Colors.transparent],
        ),
      ),
    );
  }
}
