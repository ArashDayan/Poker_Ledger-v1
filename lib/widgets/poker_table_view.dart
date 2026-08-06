import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../core/theme/app_theme.dart';
import '../models/player.dart';
import '../services/table_service.dart';

/// Perspective projection shared by the felt painter and seat placement.
///
/// The table is modelled as a flat racetrack in "world" space and then
/// projected to give a slightly angled top-down view — the way a table
/// looks from a standing dealer's eye height rather than straight down
/// from the ceiling. A true 90-degree overhead view reads as a diagram;
/// this small amount of tilt is what makes it read as a real table.
///
/// The outline and the seats MUST both use this, otherwise seats drift
/// off the rail whenever the projection is adjusted.
class TablePerspective {
  /// Far-edge width as a fraction of the near edge. 1.0 would be a flat
  /// overhead view; lower tilts further. 0.80 reads as three-dimensional
  /// without squashing the far seats into each other.
  static const double depth = 0.80;

  final double halfW;
  final double halfH;
  final Offset centre;

  const TablePerspective({
    required this.halfW,
    required this.halfH,
    required this.centre,
  });

  /// Projects a world point (origin at table centre, +y toward the
  /// viewer) onto the screen.
  Offset project(double tx, double ty) {
    // u: 0 at the far edge, 1 at the near edge.
    final u = ((ty / halfH) + 1) / 2;
    // Horizontal foreshortening grows linearly with depth.
    final scale = depth + (1 - depth) * u;
    // Vertical position is the normalised integral of that scale, which
    // compresses the far half — so rows bunch slightly toward the top,
    // exactly as they do in life.
    final y = (depth * u + (1 - depth) * u * u / 2) / ((1 + depth) / 2);
    return Offset(centre.dx + tx * scale, centre.dy + halfH * (2 * y - 1));
  }

  /// A point on the flat racetrack outline in world space.
  /// [t] runs 0..1 clockwise from bottom-centre.
  Offset outlinePoint(double t) {
    final r = halfW;
    final straight = math.max(0.0, 2 * halfH - 2 * halfW);
    final arc = math.pi * r;
    final perimeter = straight * 2 + arc * 2;
    final d = t * perimeter;

    final quarter = arc / 2;
    final rightEnd = quarter + straight;
    final topEnd = rightEnd + arc;
    final leftEnd = topEnd + straight;

    if (d < quarter) {
      final a = (d / quarter) * (math.pi / 2);
      return Offset(r * math.sin(a), straight / 2 + r * math.cos(a));
    }
    if (d < rightEnd) {
      return Offset(r, straight / 2 - (d - quarter));
    }
    if (d < topEnd) {
      final a = ((d - rightEnd) / arc) * math.pi;
      return Offset(r * math.cos(a), -straight / 2 - r * math.sin(a));
    }
    if (d < leftEnd) {
      return Offset(-r, -straight / 2 + (d - topEnd));
    }
    final a = ((d - leftEnd) / quarter) * (math.pi / 2);
    return Offset(-r * math.cos(a), straight / 2 + r * math.sin(a));
  }

  /// The projected outline as a closed path. [inset] shrinks the table
  /// in world space first, so the rail, felt and every inner ring share
  /// one shape and stay concentric under perspective.
  Path outlinePath({double inset = 0}) {
    final source = inset <= 0
        ? this
        : TablePerspective(
            halfW: math.max(halfW - inset, 1),
            halfH: math.max(halfH - inset, 1),
            centre: centre,
          );
    final path = Path();
    const steps = 160;
    for (var i = 0; i <= steps; i++) {
      final w = source.outlinePoint(i / steps);
      // Project through THIS perspective, not the shrunken one, so an
      // inset ring keeps the same viewing angle as the outer rail.
      final p = project(w.dx, w.dy);
      if (i == 0) {
        path.moveTo(p.dx, p.dy);
      } else {
        path.lineTo(p.dx, p.dy);
      }
    }
    path.close();
    return path;
  }
}

/// Everything one seat needs to render. Assembled by the caller so this
/// widget stays free of business logic — it draws, it does not calculate.
class SeatData {
  final int seatNumber;
  final Player? player;

  /// Net result, used only to tint the seat ring.
  final double profitLoss;

  /// True once the player has cashed out / left.
  final bool settled;

  /// Formatted money line (already privacy-masked by the caller).
  final String? moneyLabel;

  const SeatData({
    required this.seatNumber,
    this.player,
    this.profitLoss = 0,
    this.settled = false,
    this.moneyLabel,
  });

  bool get isEmpty => player == null;
}

/// A premium poker table laid out for a phone held in portrait.
///
/// DESIGN
/// Emerald felt, black leather rail, thin gold inlays, seen from a
/// slightly angled top-down viewpoint. The felt carries only the
/// furniture a real Texas Hold'em table has — five community-card
/// placeholders, a dealer-button spot, the betting arc, and one small
/// gold "POKER LEDGER" wordmark pressed into the cloth.
///
/// Deliberately free of real-world clutter — no cup holders, no LED
/// strips, no third-party logos, no visible hardware — because this is a
/// banking tool for running a game, not a casino advertisement.
///
/// ANIMATION HOOKS
/// Seats render through [SeatWidget], which already wraps its pod in an
/// [AnimatedContainer], and [onSeatTap] is the single interaction entry
/// point. A future chip-slide or deal animation can drive those without
/// touching any of the geometry here.
class PokerTableView extends StatelessWidget {
  final List<SeatData> seats;
  final int dealerSeat;
  final String tableName;
  final TableStatus status;

  /// Where the dealer box sits: true = right edge, false = left edge.
  final bool dealerOnRight;

  final void Function(SeatData seat) onSeatTap;
  final VoidCallback? onDealerTap;

  const PokerTableView({
    super.key,
    required this.seats,
    required this.dealerSeat,
    required this.tableName,
    required this.onSeatTap,
    this.status = TableStatus.active,
    this.dealerOnRight = true,
    this.onDealerTap,
  });

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        // Seat pods overhang the rail, so the felt is inset by half a pod
        // plus room for the name plate. Sizing from BOTH axes keeps the
        // whole table on one screen instead of overflowing a short phone.
        const seatSize = 44.0;
        const plateHeight = 24.0;
        const inset = seatSize / 2 + 10;

        final maxW = constraints.maxWidth;
        final maxH = constraints.maxHeight.isFinite
            ? constraints.maxHeight
            : maxW * 1.5;

        // Fill the space actually available rather than deriving height
        // from width alone — that left ~140px of dead screen on a tall
        // phone. Width still caps the table, and the aspect is clamped
        // so it can never become a circle on a short screen or an
        // unusable ribbon on a very tall one.
        final maxHalfW = (maxW - inset * 2) / 2;
        final maxHalfH = (maxH - inset * 2 - plateHeight) / 2;
        var halfW = maxHalfW;
        var halfH = maxHalfH;
        final aspect = halfH / halfW;
        if (aspect > 1.55) {
          halfH = halfW * 1.55;
        } else if (aspect < 1.15) {
          halfW = halfH / 1.15;
        }
        halfW = math.max(halfW, 70);
        halfH = math.max(halfH, 100);

        final totalW = halfW * 2 + inset * 2;
        final totalH = halfH * 2 + inset * 2 + plateHeight;

        final perspective = TablePerspective(
          halfW: halfW,
          halfH: halfH,
          centre: Offset(totalW / 2, inset + halfH),
        );
        // Perspective shifts the true middle of the felt upward, so
        // anything centred on the table must use the PROJECTED centre
        // rather than the middle of the bounding box.
        final feltCentre = perspective.project(0, 0);

        return Center(
          child: SizedBox(
            width: totalW,
            height: totalH,
            child: Stack(
              alignment: Alignment.center,
              clipBehavior: Clip.none,
              children: [
                // Rail + felt, drawn through the same projection the
                // seats use so the two can never drift apart.
                Positioned.fill(
                  child: CustomPaint(
                    painter: _TablePainter(
                      perspective: perspective,
                      status: status,
                    ),
                  ),
                ),

                if (status.isClosed || status.isPaused) ...[
                  Positioned.fill(
                    child: IgnorePointer(
                      child: CustomPaint(
                        painter: _StatusVeilPainter(
                          perspective: perspective,
                          closed: status.isClosed,
                        ),
                      ),
                    ),
                  ),
                  Positioned(
                    left: 0,
                    right: 0,
                    top: feltCentre.dy + halfH * 0.34,
                    child: IgnorePointer(
                      child: Center(
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 12, vertical: 5),
                          decoration: BoxDecoration(
                            color: AppColors.background.withValues(alpha: 0.88),
                            borderRadius: BorderRadius.circular(20),
                            border: Border.all(
                              color: status.isClosed
                                  ? AppColors.danger
                                  : AppColors.warning,
                            ),
                          ),
                          child: Text(
                            status.isClosed ? 'CLOSED' : 'PAUSED',
                            style: TextStyle(
                              fontSize: 11,
                              fontWeight: FontWeight.bold,
                              letterSpacing: 1.4,
                              color: status.isClosed
                                  ? AppColors.danger
                                  : AppColors.warning,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ],

                // Dealer position — a fixed box on one side, the way a
                // real room seats its dealer.
                //
                // Placed at the NEAR end rather than the centre: the rail
                // bulges widest at mid-height, so a centred box collides
                // with the side seats. Down here it sits in the gap
                // between the bottom seats and the edge.
                Positioned(
                  left: dealerOnRight ? null : 2,
                  right: dealerOnRight ? 2 : null,
                  top: feltCentre.dy + halfH * 0.62,
                  child: _DealerBox(
                    seatNumber: dealerSeat,
                    onTap: onDealerTap,
                  ),
                ),

                // Seats, placed on the projected rail.
                for (var i = 0; i < seats.length; i++)
                  ..._positionSeat(
                    seat: seats[i],
                    index: i,
                    count: seats.length,
                    perspective: perspective,
                    seatSize: seatSize,
                  ),
              ],
            ),
          ),
        );
      },
    );
  }

  /// Places one seat on the projected rail.
  List<Widget> _positionSeat({
    required SeatData seat,
    required int index,
    required int count,
    required TablePerspective perspective,
    required double seatSize,
  }) {
    // Seats are spaced by ARC LENGTH along the flat racetrack and only
    // then projected. Spacing in world space first is what keeps them
    // evenly distributed around the rail — spacing on the already
    // projected shape would bunch them at the far end.
    //
    // Seat 1 starts at bottom-centre (nearest the banker) and runs
    // clockwise, matching how a real table is numbered.
    final t = (index + 0.5) / count;
    final world = perspective.outlinePoint(t);
    final p = perspective.project(world.dx, world.dy);

    // Far seats render slightly smaller, which sells the depth without
    // making them awkward to tap.
    final depthFactor = 0.86 +
        0.14 * (((world.dy / perspective.halfH) + 1) / 2).clamp(0.0, 1.0);
    final size = seatSize * depthFactor;

    return [
      Positioned(
        left: p.dx - size / 2,
        top: p.dy - size / 2,
        child: SeatWidget(
          data: seat,
          size: size,
          isDealer: seat.seatNumber == dealerSeat,
          tableClosed: status.isClosed,
          onTap: () => onSeatTap(seat),
        ),
      ),
    ];
  }
}

class SeatWidget extends StatelessWidget {
  final SeatData data;
  final double size;
  final bool isDealer;
  final bool tableClosed;
  final VoidCallback onTap;

  const SeatWidget({
    super.key,
    required this.data,
    required this.size,
    required this.onTap,
    this.isDealer = false,
    this.tableClosed = false,
  });

  Color get _ring {
    if (tableClosed) return AppColors.divider;
    if (data.isEmpty) return AppColors.divider;
    if (data.settled) return AppColors.accentGreen;
    if (data.profitLoss > 0) return AppColors.accentGreen;
    if (data.profitLoss < 0) return AppColors.danger;
    return AppColors.textSecondary;
  }

  @override
  Widget build(BuildContext context) {
    final ring = _ring;
    final player = data.player;

    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: SizedBox(
        width: size,
        // Extra height for the name plate below the pod.
        height: size + 26,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // AnimatedContainer so a future "chips arriving" pulse only
            // needs to change these values.
            AnimatedContainer(
              duration: const Duration(milliseconds: 220),
              curve: Curves.easeOut,
              width: size,
              height: size,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                gradient: LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: data.isEmpty
                      ? [AppColors.surface, AppColors.background]
                      : [AppColors.surfaceElevated, AppColors.surface],
                ),
                border: Border.all(color: ring, width: data.settled ? 2.2 : 1.6),
                boxShadow: [
                  BoxShadow(
                    color: ring.withValues(alpha: data.isEmpty ? 0.10 : 0.30),
                    blurRadius: 8,
                    spreadRadius: 0.5,
                  ),
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.35),
                    blurRadius: 6,
                    offset: const Offset(0, 3),
                  ),
                ],
              ),
              child: Center(
                child: data.isEmpty
                    ? Icon(Icons.add,
                        size: size * 0.36, color: AppColors.textSecondary)
                    : Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            player!.name.isNotEmpty
                                ? player.name[0].toUpperCase()
                                : '?',
                            style: TextStyle(
                              fontSize: size * 0.33,
                              fontWeight: FontWeight.bold,
                              height: 1.0,
                            ),
                          ),
                          Text(
                            '${data.seatNumber}',
                            style: TextStyle(
                              fontSize: size * 0.18,
                              fontWeight: FontWeight.bold,
                              height: 1.3,
                              color: AppColors.gold.withValues(alpha: 0.85),
                            ),
                          ),
                        ],
                      ),
              ),
            ),
            // Name plate. Sits outside the pod so the pod can stay small
            // without truncating names — the reason seats read clearly at
            // 46px.
            if (!data.isEmpty) ...[
              const SizedBox(height: 3),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1.5),
                decoration: BoxDecoration(
                  color: AppColors.background.withValues(alpha: 0.85),
                  borderRadius: BorderRadius.circular(5),
                  border: Border.all(color: ring.withValues(alpha: 0.45)),
                ),
                child: Text(
                  player!.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    fontSize: 8.5,
                    fontWeight: FontWeight.bold,
                    height: 1.1,
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// The felt bed, rail and centre branding.
class _DealerBox extends StatelessWidget {
  final int seatNumber;
  final VoidCallback? onTap;

  const _DealerBox({required this.seatNumber, this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: 44,
        padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 4),
        decoration: BoxDecoration(
          color: AppColors.surfaceElevated,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: AppColors.gold.withValues(alpha: 0.6)),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.4),
              blurRadius: 8,
              offset: const Offset(0, 3),
            ),
          ],
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 22,
              height: 22,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                gradient: const LinearGradient(
                  colors: [Color(0xFFFFF6D8), Color(0xFFD4AF37)],
                ),
              ),
              child: const Text(
                'D',
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w900,
                  color: Color(0xFF12100E),
                ),
              ),
            ),
            const SizedBox(height: 4),
            Text(
              'S$seatNumber',
              style: const TextStyle(
                fontSize: 9,
                fontWeight: FontWeight.bold,
                color: AppColors.gold,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Paints the table: black leather rail, thin gold inlay, emerald felt
/// and a soft overhead light — all through the shared perspective, so
/// the shape is a genuine angled view rather than a flat capsule.
class _TablePainter extends CustomPainter {
  final TablePerspective perspective;
  final TableStatus status;

  _TablePainter({required this.perspective, required this.status});

  @override
  void paint(Canvas canvas, Size size) {
    final railPath = perspective.outlinePath();
    final feltPath = perspective.outlinePath(inset: perspective.halfW * 0.085);
    final centre = perspective.project(0, 0);
    final bounds = railPath.getBounds();

    // Grounding shadow, so the table sits in a room rather than floating.
    canvas.drawPath(
      railPath.shift(const Offset(0, 10)),
      Paint()
        ..color = Colors.black.withValues(alpha: 0.55)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 22),
    );

    // Black leather rail. A diagonal sheen reads as padded hide.
    canvas.drawPath(
      railPath,
      Paint()
        ..shader = ui.Gradient.linear(
          Offset(bounds.left, bounds.top),
          Offset(bounds.right, bounds.bottom),
          const [Color(0xFF23282B), Color(0xFF0C0F10), Color(0xFF191E20)],
          const [0.0, 0.55, 1.0],
        ),
    );

    // The near edge of a padded rail catches the overhead light.
    canvas.save();
    canvas.clipPath(railPath);
    canvas.drawPath(
      railPath,
      Paint()
        ..shader = ui.Gradient.linear(
          Offset(centre.dx, bounds.top),
          Offset(centre.dx, bounds.top + bounds.height * 0.35),
          [Colors.white.withValues(alpha: 0.10), Colors.white.withValues(alpha: 0.0)],
        ),
    );
    canvas.restore();

    // Rail stitching: a faint dashed seam just inside the leather edge,
    // the detail that most distinguishes an upholstered rail from a
    // painted band. Drawn as short strokes along the projected outline.
    final stitchPath =
        perspective.outlinePath(inset: perspective.halfW * 0.030);
    final stitchPaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 0.9
      ..strokeCap = StrokeCap.round
      ..color = Colors.white.withValues(alpha: 0.07);
    for (final metric in stitchPath.computeMetrics()) {
      const dash = 4.0;
      const skip = 5.0;
      var d = 0.0;
      while (d < metric.length) {
        canvas.drawPath(
          metric.extractPath(d, math.min(d + dash, metric.length)),
          stitchPaint,
        );
        d += dash + skip;
      }
    }

    // Thin gold inlays. Two hairlines rather than one thick band —
    // restraint is what makes gold read as luxury instead of costume.
    canvas.drawPath(
      perspective.outlinePath(inset: perspective.halfW * 0.070),
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.6
        ..color = AppColors.gold.withValues(alpha: 0.75),
    );
    canvas.drawPath(
      railPath,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.0
        ..color = AppColors.gold.withValues(alpha: 0.30),
    );

    // Emerald felt, lit from above and falling away at the near edge.
    canvas.drawPath(
      feltPath,
      Paint()
        ..shader = ui.Gradient.radial(
          Offset(centre.dx, centre.dy - perspective.halfH * 0.30),
          perspective.halfH * 1.15,
          const [
            Color(0xFF35A972),
            Color(0xFF1E8455),
            AppColors.feltGreen,
            Color(0xFF08281A),
          ],
          const [0.0, 0.35, 0.66, 1.0],
        ),
    );

    // Felt nap: very faint concentric banding, the way stretched cloth
    // catches light. Subtle enough to read as texture, not pattern.
    canvas.save();
    canvas.clipPath(feltPath);
    for (var i = 1; i <= 3; i++) {
      canvas.drawPath(
        perspective.outlinePath(
            inset: perspective.halfW * (0.085 + 0.085 * i)),
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1
          ..color = Colors.white.withValues(alpha: 0.022),
      );
    }
    canvas.restore();

    // Inner shadow where felt meets rail, so the playing surface sits
    // below the rail rather than flush with it.
    canvas.save();
    canvas.clipPath(feltPath);
    canvas.drawPath(
      feltPath,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = perspective.halfW * 0.10
        ..color = Colors.black.withValues(alpha: 0.30)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 9),
    );
    canvas.restore();

    // Dealer arc: one thin gold line marking the betting boundary. The
    // only piece of table furniture kept, because it orients the eye —
    // everything purely decorative was removed.
    final arc = Path();
    const steps = 60;
    for (var i = 0; i <= steps; i++) {
      final a = math.pi * (i / steps);
      final p = perspective.project(
        perspective.halfW * 0.60 * math.cos(a),
        perspective.halfH * 0.46 * math.sin(a),
      );
      if (i == 0) {
        arc.moveTo(p.dx, p.dy);
      } else {
        arc.lineTo(p.dx, p.dy);
      }
    }
    canvas.drawPath(
      arc,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.1
        ..color = AppColors.gold.withValues(alpha: 0.16),
    );

    // Felt furniture. Everything below is printed INTO the cloth: it is
    // clipped to the felt, drawn through the same projection as the rail
    // and kept low-contrast so it reads as embossing rather than UI.
    canvas.save();
    canvas.clipPath(feltPath);
    final fade = status.isClosed ? 0.45 : 1.0;
    _drawWordmark(canvas, fade);
    _drawCommunityCards(canvas, fade);
    _drawDealerSpot(canvas, fade);
    canvas.restore();
  }

  /// "POKER LEDGER" set on a gentle arc above the community cards.
  ///
  /// Each glyph is placed individually along a shallow curve and given a
  /// dark offset copy underneath, which is what produces the pressed-into-
  /// the-felt look. Kept small and low-opacity on purpose — this is a
  /// maker's mark, not signage.
  void _drawWordmark(Canvas canvas, double fade) {
    const text = 'POKER LEDGER';
    final fontSize = (perspective.halfW * 0.088).clamp(8.0, 17.0);
    final letterSpacing = fontSize * 0.34;

    // Measure first so the whole word can be centred on the arc.
    final widths = <double>[];
    final painters = <TextPainter>[];
    for (final ch in text.split('')) {
      final tp = TextPainter(
        text: TextSpan(
          text: ch,
          style: TextStyle(
            fontSize: fontSize,
            fontWeight: FontWeight.w700,
            letterSpacing: 0,
            color: AppColors.gold.withValues(alpha: 0.62 * fade),
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      painters.add(tp);
      widths.add(tp.width);
    }
    final total = widths.fold<double>(0, (a, b) => a + b) +
        letterSpacing * (text.length - 1);

    // Arc geometry in world space: a wide, shallow curve that follows the
    // far shoulder of the table.
    final radius = perspective.halfH * 1.30;
    final centreY = -perspective.halfH * 0.30 + radius;
    final half = total / 2;

    var cursor = -half;
    for (var i = 0; i < painters.length; i++) {
      final tp = painters[i];
      final at = cursor + widths[i] / 2;
      cursor += widths[i] + letterSpacing;

      final angle = at / radius;
      final wx = radius * math.sin(angle);
      final wy = centreY - radius * math.cos(angle);
      final p = perspective.project(wx, wy);

      canvas.save();
      canvas.translate(p.dx, p.dy);
      canvas.rotate(angle * 0.85);
      // Foreshorten the glyph vertically so it lies ON the cloth.
      canvas.scale(1.0, 0.74);

      final shadow = TextPainter(
        text: TextSpan(
          text: text[i],
          style: TextStyle(
            fontSize: fontSize,
            fontWeight: FontWeight.w700,
            color: Colors.black.withValues(alpha: 0.32 * fade),
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      shadow.paint(
        canvas,
        Offset(-tp.width / 2 + 0.7, -tp.height / 2 + 1.0),
      );
      tp.paint(canvas, Offset(-tp.width / 2, -tp.height / 2));
      canvas.restore();
    }

    // A hairline flourish either side of the word, the way a printed felt
    // frames its mark.
    final rulePaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.0
      ..color = AppColors.gold.withValues(alpha: 0.22 * fade);
    for (final sign in [-1.0, 1.0]) {
      final a1 = sign * (half + letterSpacing * 1.2) / radius;
      final a2 = sign * (half + letterSpacing * 3.6) / radius;
      final p1 = perspective.project(
          radius * math.sin(a1), centreY - radius * math.cos(a1));
      final p2 = perspective.project(
          radius * math.sin(a2), centreY - radius * math.cos(a2));
      canvas.drawLine(p1, p2, rulePaint);
    }
  }

  /// Five empty community-card slots — flop, turn, river.
  ///
  /// Each slot is a projected quad rather than a rounded rect, so the
  /// cards share the table's viewing angle instead of sitting flat on
  /// top of it. They are placeholders only: no ranks, no suits, nothing
  /// that implies the app is dealing a hand.
  void _drawCommunityCards(Canvas canvas, double fade) {
    final cardW = perspective.halfW * 0.135;
    final cardH = cardW * 1.40;
    final gap = perspective.halfW * 0.035;
    // Wider break between the flop and the turn, exactly as a dealer
    // spreads them.
    final split = gap * 2.6;

    final totalW = cardW * 5 + gap * 3 + split;
    final top = perspective.halfH * 0.02;
    var x = -totalW / 2;

    for (var i = 0; i < 5; i++) {
      _drawCardSlot(canvas, x, top, cardW, cardH, fade);
      x += cardW + (i == 2 ? split : gap);
    }
  }

  void _drawCardSlot(
    Canvas canvas,
    double wx,
    double wy,
    double w,
    double h,
    double fade,
  ) {
    final tl = perspective.project(wx, wy);
    final tr = perspective.project(wx + w, wy);
    final br = perspective.project(wx + w, wy + h);
    final bl = perspective.project(wx, wy + h);

    final path = Path()
      ..moveTo(tl.dx, tl.dy)
      ..lineTo(tr.dx, tr.dy)
      ..lineTo(br.dx, br.dy)
      ..lineTo(bl.dx, bl.dy)
      ..close();

    // Recessed well: a touch darker than the felt around it.
    canvas.drawPath(
      path,
      Paint()..color = Colors.black.withValues(alpha: 0.26 * fade),
    );
    // Thin gold outline, matching the rail inlays.
    canvas.drawPath(
      path,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.1
        ..strokeJoin = StrokeJoin.round
        ..color = AppColors.gold.withValues(alpha: 0.42 * fade),
    );
    // Highlight on the near edge, so the slot reads as cut into the cloth.
    canvas.drawLine(
      bl,
      br,
      Paint()
        ..strokeWidth = 1.0
        ..color = Colors.white.withValues(alpha: 0.07 * fade),
    );
  }

  /// The dealer-button rest: a small marked spot on the felt beside the
  /// dealer's position. Purely a table marking — the interactive dealer
  /// control remains the widget in the stack above.
  void _drawDealerSpot(Canvas canvas, double fade) {
    final centre = perspective.project(
      -perspective.halfW * 0.56,
      perspective.halfH * 0.36,
    );
    final r = perspective.halfW * 0.062;

    // Projected as an ellipse: a circle on an angled table is not round.
    final rect = Rect.fromCenter(
      center: centre,
      width: r * 2,
      height: r * 2 * TablePerspective.depth,
    );
    canvas.drawOval(
      rect,
      Paint()..color = Colors.black.withValues(alpha: 0.16 * fade),
    );
    canvas.drawOval(
      rect,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.0
        ..color = AppColors.gold.withValues(alpha: 0.30 * fade),
    );

    final tp = TextPainter(
      text: TextSpan(
        text: 'D',
        style: TextStyle(
          fontSize: (r * 1.05).clamp(6.0, 13.0),
          fontWeight: FontWeight.w800,
          color: AppColors.gold.withValues(alpha: 0.34 * fade),
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    canvas.save();
    canvas.translate(centre.dx, centre.dy);
    canvas.scale(1.0, 0.78);
    tp.paint(canvas, Offset(-tp.width / 2, -tp.height / 2));
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant _TablePainter old) =>
      old.status != status ||
      old.perspective.halfW != perspective.halfW ||
      old.perspective.halfH != perspective.halfH;
}

/// Dims the felt when a table is paused or closed, following the same
/// projected outline so the veil never spills past the rail.
class _StatusVeilPainter extends CustomPainter {
  final TablePerspective perspective;
  final bool closed;

  _StatusVeilPainter({required this.perspective, required this.closed});

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawPath(
      perspective.outlinePath(),
      Paint()..color = Colors.black.withValues(alpha: closed ? 0.52 : 0.26),
    );
  }

  @override
  bool shouldRepaint(covariant _StatusVeilPainter old) =>
      old.closed != closed;
}
