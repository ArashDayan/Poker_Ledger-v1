import 'package:flutter/material.dart';

import '../core/theme/app_theme.dart';
import '../models/player.dart';
import '../services/table_service.dart';

/// Fixed seat anchors for the reference table photograph.
///
/// WHY THESE ARE HARD-CODED AND NEVER RECALCULATED
/// The table is a real photographic render with ten seat positions
/// physically printed on the felt. The pods therefore have to land on the
/// rail beside their own printed number — which is a property of the
/// IMAGE, not something that can be derived from a seat count. Spreading
/// six pods evenly around the oval (as the old CustomPaint table did)
/// would put seat 4 next to the printed "6" and make the felt lie.
///
/// So the geometry is constant for every table size. A six-seat table
/// uses anchors 1-6 and leaves 7-10 dimmed in place; it does not
/// redistribute. See [PokerTableView.activeSeats].
///
/// Coordinates are fractions of the ROTATED (portrait) image, measured
/// against the render itself: pixel-detected the printed numbers, then
/// placed each pod on the rail band nearest its number and verified the
/// overlay visually.
class TableAnchors {
  const TableAnchors._();

  /// The source image is landscape 1536x1024; rotated a quarter turn for
  /// portrait it is 1024x1536. Locking this ratio is what stops the
  /// table stretching on different phones.
  static const double aspectRatio = 1024 / 1536;

  /// seat number -> (x, y) as a fraction of the rotated image.
  static const Map<int, Offset> seats = {
    1: Offset(0.262, 0.290),
    2: Offset(0.470, 0.080),
    3: Offset(0.668, 0.084),
    4: Offset(0.830, 0.212),
    5: Offset(0.848, 0.382),
    6: Offset(0.848, 0.616),
    7: Offset(0.830, 0.788),
    8: Offset(0.668, 0.916),
    9: Offset(0.470, 0.920),
    10: Offset(0.262, 0.710),
  };

  /// The dealer's chip tray, on the LEFT in portrait.
  static const Offset dealer = Offset(0.385, 0.500);

  /// Highest seat the artwork can show. A table configured for more than
  /// this still renders ten pods; nothing is invented beyond the felt.
  static const int maxSeats = 10;
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

  /// False when the table is configured for fewer seats than this one.
  ///
  /// The pod still renders, in its own fixed position, but dimmed and
  /// non-tappable — the printed number stays visible on the felt either
  /// way, so hiding the pod would leave an unexplained gap.
  final bool enabled;

  const SeatData({
    required this.seatNumber,
    this.player,
    this.profitLoss = 0,
    this.settled = false,
    this.moneyLabel,
    this.enabled = true,
  });

  bool get isEmpty => player == null;
}

/// The Poker Ledger table: a photographic render of the real table with
/// the interactive seat pods laid over it.
///
/// WHY AN IMAGE RATHER THAN A PAINTER
/// This replaced a ~600-line CustomPaint construction that drew the rail,
/// felt and inlays by hand. It was geometrically correct but read as a
/// diagram — flat, vector, CAD-like. A photographic render carries real
/// depth, felt texture, leather grain and lighting that painted gradients
/// cannot, and it costs one decode instead of a full repaint whenever a
/// seat changes.
///
/// The image is landscape; it is rotated a quarter turn here rather than
/// shipping a second asset, so there is exactly one file to maintain and
/// no risk of the two drifting apart.
///
/// LAYERING
///   background -> table image -> status veil -> dealer box -> seat pods
///
/// Everything above the image is an ordinary Flutter widget, so seats
/// stay tappable and text stays crisp at any density.
class PokerTableView extends StatelessWidget {
  final List<SeatData> seats;
  final int dealerSeat;
  final String tableName;
  final TableStatus status;

  /// Kept for source compatibility. The dealer's tray is physically part
  /// of the photograph on the LEFT, so the box is pinned there and this
  /// flag no longer moves it.
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
    this.dealerOnRight = false,
    this.onDealerTap,
  });

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        // Fit the fixed-aspect table inside whatever space is available,
        // leaving a margin for the pods that overhang the rail. The
        // table's own proportions never change — only its scale — which
        // is what keeps one geometry across every phone and seat count.
        const overhang = 30.0;

        final maxW = constraints.maxWidth;
        final maxH = constraints.maxHeight.isFinite
            ? constraints.maxHeight
            : maxW / TableAnchors.aspectRatio;

        var tableW = maxW - overhang * 2;
        var tableH = tableW / TableAnchors.aspectRatio;
        if (tableH > maxH - overhang * 2) {
          tableH = maxH - overhang * 2;
          tableW = tableH * TableAnchors.aspectRatio;
        }
        tableW = tableW.clamp(80.0, double.infinity);
        tableH = tableH.clamp(120.0, double.infinity);

        // Pods scale with the table so they stay proportionate, but are
        // clamped so they never grow clumsy or shrink below a tappable
        // target on a small screen.
        final seatSize = (tableW * 0.135).clamp(34.0, 52.0);

        return Center(
          child: SizedBox(
            width: tableW + overhang * 2,
            height: tableH + overhang * 2,
            child: Stack(
              clipBehavior: Clip.none,
              children: [
                // The table itself.
                Positioned(
                  left: overhang,
                  top: overhang,
                  width: tableW,
                  height: tableH,
                  child: _TableImage(status: status),
                ),

                if (status.isClosed || status.isPaused)
                  Positioned(
                    left: overhang,
                    top: overhang + tableH * 0.5 - 16,
                    width: tableW,
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

                // Dealer box, over the tray printed on the felt.
                Positioned(
                  left: overhang + tableW * TableAnchors.dealer.dx - 22,
                  top: overhang + tableH * TableAnchors.dealer.dy - 26,
                  child: _DealerBox(
                    seatNumber: dealerSeat,
                    onTap: onDealerTap,
                  ),
                ),

                // Seat pods on their fixed anchors.
                for (final seat in seats)
                  if (TableAnchors.seats.containsKey(seat.seatNumber))
                    _positionSeat(
                      seat: seat,
                      anchor: TableAnchors.seats[seat.seatNumber]!,
                      origin: const Offset(overhang, overhang),
                      tableW: tableW,
                      tableH: tableH,
                      seatSize: seatSize,
                    ),
              ],
            ),
          ),
        );
      },
    );
  }

  /// Places one pod on its fixed anchor. No seat-count arithmetic here —
  /// the anchor is looked up, never derived.
  Widget _positionSeat({
    required SeatData seat,
    required Offset anchor,
    required Offset origin,
    required double tableW,
    required double tableH,
    required double seatSize,
  }) {
    final cx = origin.dx + tableW * anchor.dx;
    final cy = origin.dy + tableH * anchor.dy;

    return Positioned(
      left: cx - seatSize / 2,
      top: cy - seatSize / 2,
      child: SeatWidget(
        data: seat,
        size: seatSize,
        isDealer: seat.seatNumber == dealerSeat,
        tableClosed: status.isClosed,
        onTap: () => onSeatTap(seat),
      ),
    );
  }
}

/// The photographic table, rotated a quarter turn into portrait.
///
/// [RotatedBox] turns the image during layout rather than at paint time,
/// so the rotated bitmap participates in layout normally and costs
/// nothing per frame. [BoxFit.fill] is safe precisely because the parent
/// already sized itself to [TableAnchors.aspectRatio] — the box and the
/// bitmap agree, so nothing is stretched.
class _TableImage extends StatelessWidget {
  final TableStatus status;
  const _TableImage({required this.status});

  @override
  Widget build(BuildContext context) {
    final dim = status.isClosed
        ? 0.45
        : status.isPaused
            ? 0.22
            : 0.0;

    return DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(18),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.55),
            blurRadius: 26,
            spreadRadius: 2,
            offset: const Offset(0, 10),
          ),
        ],
      ),
      child: ColorFiltered(
        colorFilter: ColorFilter.mode(
          Colors.black.withValues(alpha: dim),
          BlendMode.srcATop,
        ),
        child: const RotatedBox(
          quarterTurns: 1,
          child: Image(
            image: AssetImage('assets/images/poker_table.png'),
            fit: BoxFit.fill,
            filterQuality: FilterQuality.medium,
          ),
        ),
      ),
    );
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
    if (!data.enabled) return AppColors.divider;
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

    // LOCKED SEAT — outside the table's configured seat count.
    //
    // It stays visible in its own fixed position, because the felt has
    // all ten numbers printed on it and leaving a gap would orphan one.
    // But it is inert: no GestureDetector is built at all, so there is
    // no tap to fire, no Add Player sheet and no seat sheet.
    //
    // AbsorbPointer rather than IgnorePointer on purpose. IgnorePointer
    // would let the touch fall THROUGH to whatever sits beneath the pod;
    // AbsorbPointer swallows it, so tapping a locked seat does literally
    // nothing. ExcludeSemantics stops screen readers announcing it as an
    // actionable control.
    if (!data.enabled) {
      return ExcludeSemantics(
        child: AbsorbPointer(
          child: Opacity(opacity: 0.28, child: _pod(ring, player)),
        ),
      );
    }

    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: _pod(ring, player),
    );
  }

  Widget _pod(Color ring, Player? player) {
    return SizedBox(
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
    );
  }
}

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
