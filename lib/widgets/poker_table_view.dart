import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../core/theme/app_theme.dart';
import '../models/enums.dart';
import '../models/player.dart';
import '../services/player_registry_service.dart';
import '../services/table_service.dart';
import 'player_type_badge.dart';

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

  /// The asset is the table in its natural landscape orientation, with
  /// the studio backdrop cut away and cropped to the table itself
  /// (1501x812). It is drawn WITHOUT rotation, so the felt reads the
  /// same way up as the physical table: dealer nearest the banker at the
  /// bottom, seats climbing away around the rail.
  ///
  /// Locking this ratio is what stops the table stretching on different
  /// phones — the box and the bitmap always agree.
  static const double aspectRatio = 1501 / 812;

  /// seat number -> (x, y) as a fraction of the table image.
  ///
  /// Derived from the previously verified positions by a -90 degree
  /// rotation ((x,y) -> (y, 1-x)) and then re-mapped onto the cropped
  /// asset, so every pod still lands on the rail beside its own printed
  /// number. Verified visually against the artwork.
  static const Map<int, Offset> seats = {
    1: Offset(0.285, 0.785),
    2: Offset(0.070, 0.523),
    3: Offset(0.074, 0.273),
    4: Offset(0.205, 0.069),
    5: Offset(0.379, 0.046),
    6: Offset(0.618, 0.046),
    7: Offset(0.794, 0.069),
    8: Offset(0.925, 0.273),
    9: Offset(0.929, 0.523),
    10: Offset(0.715, 0.785),
  };

  /// The dealer's chip tray, at the BOTTOM centre of the table.
  static const Offset dealer = Offset(0.500, 0.630);

  /// Highest seat the artwork can show. A table configured for more than
  /// this still renders ten pods; nothing is invented beyond the felt.
  static const int maxSeats = 10;

  /// Extreme anchor positions, used to work out how far the outermost
  /// pods reach past the table box so the layout can reserve exactly
  /// that much and no more.
  ///
  /// Hard-coded rather than folded over [seats] on every layout pass:
  /// the map is `const`, so these can never drift out of step, and it
  /// keeps a hot path allocation-free.
  ///   x: seat 2 (0.070) .. seat 9 (0.929)
  ///   y: seat 5/6 (0.046) .. seat 1/10 (0.785)
  static const double minX = 0.070;
  static const double maxX = 0.929;
  static const double minY = 0.046;
  static const double maxY = 0.785;
}

/// Height of the name plate that hangs beneath an occupied pod. The
/// lowest seats need this much clearance or a player's name is clipped
/// by the bottom of the widget.
const double _plateHeight = 26.0;

/// Pod diameter for a given table width.
///
/// Scales with the table so seats stay proportionate, but clamped: never
/// so large it crowds the felt, never below the ~34px that keeps it a
/// comfortable tap target on a small phone.
double _seatSizeFor(double tableW) =>
    (tableW * 0.135).clamp(34.0, 52.0);

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
        // WIDTH-FIRST SIZING.
        //
        // The table is the whole point of this screen, so it takes as
        // much width as the phone can give it. Vertical slack is left
        // as empty space above and below rather than being used to
        // shrink the table — a landscape table in a portrait window
        // will always leave bands, and filling them would mean a
        // smaller, harder-to-read table.
        //
        // The previous version reserved a flat 30px on every side for
        // pods overhanging the rail. That was a guess, and on the
        // horizontal axis it was simply wrong: seats 2/3 sit at x=0.070
        // and 8/9 at x=0.929, so with a pod half-width of at most 26px
        // they never reach the table's own left/right edges. The flat
        // margin therefore threw away ~60px of width for nothing —
        // about 16% of the table on a 393px screen.
        //
        // So the margins are now MEASURED from the real anchor extents
        // and the real pod size, per axis, instead of assumed.
        final maxW = constraints.maxWidth;
        final maxH = constraints.maxHeight.isFinite
            ? constraints.maxHeight
            : maxW / TableAnchors.aspectRatio;

        // Breathing room so the widest pod never sits flush against the
        // screen edge, even when the maths says it would just fit.
        const edgeGuard = 4.0;

        // How far pods stick out past the table box, for a candidate
        // width. Depends on the width itself (pods scale with it), so
        // it is resolved by iteration below rather than in one pass.
        ({double l, double r, double t, double b}) overhangFor(double w) {
          final h = w / TableAnchors.aspectRatio;
          final s = _seatSizeFor(w);
          return (
            l: math.max(0.0, s / 2 - TableAnchors.minX * w),
            r: math.max(0.0, (TableAnchors.maxX * w + s / 2) - w),
            t: math.max(0.0, s / 2 - TableAnchors.minY * h),
            // The name plate hangs below the pod, so the lowest seats
            // need room for it too or a player's name gets clipped.
            b: math.max(
                0.0, (TableAnchors.maxY * h + s / 2 + _plateHeight) - h),
          );
        }

        // Start from the full width and give back only what the pods
        // actually need. Two passes settle it: the first sizes the pods,
        // the second accounts for the overhang they produce.
        var tableW = maxW - edgeGuard * 2;
        for (var i = 0; i < 3; i++) {
          final o = overhangFor(tableW);
          final fitW = maxW - o.l - o.r - edgeGuard * 2;
          final fitH = (maxH - o.t - o.b) * TableAnchors.aspectRatio;
          // Height only constrains the table when it genuinely cannot
          // fit — which is what keeps every seat on screen on a short
          // window without shrinking the table on a normal phone.
          tableW = math.min(fitW, fitH);
        }
        tableW = math.max(tableW, 80.0);

        final tableH = tableW / TableAnchors.aspectRatio;
        final seatSize = _seatSizeFor(tableW);
        final pad = overhangFor(tableW);

        return Center(
          child: SizedBox(
            width: tableW + pad.l + pad.r,
            height: tableH + pad.t + pad.b,
            child: Stack(
              clipBehavior: Clip.none,
              children: [
                // The table itself.
                Positioned(
                  left: pad.l,
                  top: pad.t,
                  width: tableW,
                  height: tableH,
                  child: _TableImage(status: status),
                ),

                if (status.isClosed || status.isPaused)
                  Positioned(
                    left: pad.l,
                    top: pad.t + tableH * 0.5 - 16,
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
                  left: pad.l + tableW * TableAnchors.dealer.dx - 22,
                  top: pad.t + tableH * TableAnchors.dealer.dy - 26,
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
                      origin: Offset(pad.l, pad.t),
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

/// The photographic table, drawn in its natural orientation.
///
/// NO ROTATION. The asset is already the right way up for the phone —
/// dealer tray at the bottom — so the previous `RotatedBox` is gone.
/// Rotating the bitmap while leaving the anchors alone is exactly how
/// the seats and the felt fall out of step, so orientation is expressed
/// in ONE place: the artwork plus [TableAnchors], which were derived
/// together.
///
/// TRANSPARENCY. The asset is RGBA with the studio backdrop cut away, so
/// only the table itself paints and the app's dark background shows
/// through around it. Two things that would have re-introduced a
/// rectangle are therefore deliberately absent:
///
///   * no `DecoratedBox`/`boxShadow` wrapper — a box shadow is cast by
///     the WIDGET's rectangle, not the table silhouette, which drew a
///     hard rectangular halo around the oval;
///   * no opaque background colour of any kind.
///
/// [BoxFit.fill] stays safe because the parent already sized itself to
/// [TableAnchors.aspectRatio] — box and bitmap agree, so nothing is
/// stretched.
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

    const image = Image(
      image: AssetImage('assets/images/poker_table.png'),
      fit: BoxFit.fill,
      filterQuality: FilterQuality.medium,
    );

    // srcATop multiplies by the source alpha, so the veil follows the
    // table's own shape and cannot tint the transparent surround.
    if (dim == 0) return image;
    return ColorFiltered(
      colorFilter: ColorFilter.mode(
        Colors.black.withValues(alpha: dim),
        BlendMode.srcATop,
      ),
      child: image,
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

  /// Classification of the seated player, or null for an empty seat.
  ///
  /// Resolved through the registry so a person classified in the Player
  /// Bank shows correctly here even if this session's row predates the
  /// change. Read-only — the table never writes a classification.
  PlayerTag? get _seatTag {
    final p = data.player;
    return p == null ? null : PlayerRegistryService.tagFor(p);
  }

  bool get _seatBlacklisted {
    final p = data.player;
    return p != null && PlayerRegistryService.isBlacklisted(p);
  }

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
    // 0.55 rather than the original 0.28: at the lower value the pod
    // almost vanished against the felt, so a 9-seat table looked like it
    // was missing seat 10 rather than showing it locked. This is still
    // clearly muted against an active seat — which sits at full opacity
    // with a coloured ring — so it reads as "present but unavailable",
    // never as a live seat.
    if (!data.enabled) {
      return ExcludeSemantics(
        child: AbsorbPointer(
          child: Opacity(opacity: 0.55, child: _pod(ring, player)),
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
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    // Classification icon, not the full label: the plate
                    // is 8.5pt and already tight, so "Problem Player"
                    // would either overflow or crush the name. The icon
                    // gives the banker the same at-a-glance read without
                    // displacing the name as the primary element.
                    if (_seatTag != null) ...[
                      Icon(_seatTag!.icon, size: 8.5, color: _seatTag!.color),
                      const SizedBox(width: 2.5),
                    ],
                    Flexible(
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
                    if (_seatBlacklisted) ...[
                      const SizedBox(width: 2.5),
                      const Icon(Icons.block,
                          size: 8.5, color: AppColors.danger),
                    ],
                  ],
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
