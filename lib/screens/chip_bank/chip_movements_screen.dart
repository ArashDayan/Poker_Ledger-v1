import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/localization/app_localizations.dart';
import '../../core/theme/app_theme.dart';
import '../../core/utils/currency_formatter.dart';
import '../../models/chip_movement.dart';
import '../../models/enums.dart';
import '../../providers/chip_bank_provider.dart';
import '../../services/chip_tracking_service.dart';
import '../../services/hive_service.dart';
import '../../services/player_identity_service.dart';

/// Human-readable label for a chip location.
///
/// Resolves player and table ids to names where it can, so the audit log
/// reads "Bank → Ali" rather than "bank → player:9f3c…".
///
/// Phase 2a: holder references are PERSON-scoped, so identity names are
/// tried first; a legacy unlinked seat reference (pre-migration history)
/// still resolves through the session row, and anything else degrades to
/// an id tail rather than a wrong name.
String describeLocation(ChipLocation loc) {
  switch (loc.kind) {
    case ChipLocationKind.bank:
      return tr('location_bank');
    case ChipLocationKind.removed:
      return tr('location_removed');
    case ChipLocationKind.player:
      final ref = loc.refId;
      if (ref == null) return tr('location_player');
      final identity = PlayerIdentityService.byId(ref);
      if (identity != null && identity.displayName.trim().isNotEmpty) {
        return identity.displayName.trim();
      }
      final p = HiveService.players.get(ref);
      if (p != null) return p.name;
      final tail = ref.length >= 4 ? ref.substring(ref.length - 4) : ref;
      return '${tr('location_player')} …$tail';
    case ChipLocationKind.table:
      // Table names live inside the session map rather than their own
      // box, so fall back to the id — still unambiguous for the banker.
      return '${tr('location_table')} ${loc.refId ?? ''}'.trim();
  }
}

String describeReason(ChipMovementReason r) {
  switch (r) {
    case ChipMovementReason.buyIn:
      return tr('reason_buy_in');
    case ChipMovementReason.rebuy:
      return tr('reason_rebuy');
    case ChipMovementReason.addOn:
      return tr('reason_add_on');
    case ChipMovementReason.depositIssuance:
      return tr('reason_deposit_issuance');
    case ChipMovementReason.markerIssuance:
      return tr('reason_marker_issuance');
    case ChipMovementReason.cashOut:
      return tr('reason_cash_out');
    case ChipMovementReason.tableFloat:
      return tr('reason_table_float');
    case ChipMovementReason.rake:
      return tr('reason_rake');
    case ChipMovementReason.adjustment:
      return tr('reason_adjustment');
    case ChipMovementReason.transfer:
      return tr('reason_transfer');
    case ChipMovementReason.dealerTips:
      return tr('dealer_tips');
    case ChipMovementReason.exchange:
      return tr('chip_exchange');
    case ChipMovementReason.reversal:
      return tr('undo');
    case ChipMovementReason.lossRebate:
      return tr('reason_loss_rebate');
    case ChipMovementReason.houseWin:
      return tr('reason_house_win');
  }
}

/// The full chip audit log.
class ChipMovementsScreen extends StatelessWidget {
  final String? sessionId;

  /// Limit to movements touching one place.
  final ChipLocation? location;

  final AppCurrency currency;

  const ChipMovementsScreen({
    super.key,
    this.sessionId,
    this.location,
    this.currency = AppCurrency.usd,
  });

  @override
  Widget build(BuildContext context) {
    context.watch<ChipBankProvider>();

    final movements = location == null
        ? ChipTrackingService.allMovements(sessionId: sessionId)
        : ChipTrackingService.movementsFor(location!, sessionId: sessionId);
    final fmt = CurrencyFormatter(currency);

    return Scaffold(
      appBar: AppBar(title: Text(tr('chip_movements'))),
      body: movements.isEmpty
          ? Center(
              child: Padding(
                padding: const EdgeInsets.all(28),
                child: Text(
                  tr('no_movements_yet'),
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: AppColors.textSecondary),
                ),
              ),
            )
          : ListView.builder(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 28),
              itemCount: movements.length,
              itemBuilder: (_, i) =>
                  ChipMovementTile(movement: movements[i], fmt: fmt),
            ),
    );
  }
}

/// One line of the audit log: when, what, from where, to where.
class ChipMovementTile extends StatelessWidget {
  final ChipMovement movement;
  final CurrencyFormatter fmt;

  const ChipMovementTile({
    super.key,
    required this.movement,
    required this.fmt,
  });

  String _stamp(DateTime d) {
    final l = d.toLocal();
    String two(int n) => n.toString().padLeft(2, '0');
    return '${l.year}-${two(l.month)}-${two(l.day)}  ${two(l.hour)}:${two(l.minute)}';
  }

  @override
  Widget build(BuildContext context) {
    final removed = movement.to.isRemoved;

    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: removed
              ? AppColors.warning.withValues(alpha: 0.5)
              : AppColors.divider,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Row(
                  children: [
                    Flexible(
                      child: Text(
                        describeLocation(movement.from),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.bold,
                            color: AppColors.textPrimary),
                      ),
                    ),
                    const Padding(
                      padding: EdgeInsets.symmetric(horizontal: 6),
                      child: Icon(Icons.arrow_forward,
                          size: 13, color: AppColors.gold),
                    ),
                    Flexible(
                      child: Text(
                        describeLocation(movement.to),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.bold,
                            color: AppColors.textPrimary),
                      ),
                    ),
                  ],
                ),
              ),
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                decoration: BoxDecoration(
                  color: AppColors.surfaceElevated,
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Text(
                  describeReason(movement.reasonEnum),
                  style: const TextStyle(
                      fontSize: 9.5, color: AppColors.textSecondary),
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Row(
            children: [
              Expanded(
                child: Text(
                  '${movement.quantity} × ${fmt.format(movement.chipValue)}',
                  style: const TextStyle(
                      fontSize: 12.5, color: AppColors.accentGreen),
                ),
              ),
              Text(
                fmt.format(movement.totalValue),
                style: const TextStyle(
                    fontSize: 12.5,
                    fontWeight: FontWeight.bold,
                    color: AppColors.accentGreen),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            _stamp(movement.timestamp),
            style: const TextStyle(
                fontSize: 10, color: AppColors.textSecondary),
          ),
          if (movement.note != null)
            Padding(
              padding: const EdgeInsets.only(top: 3),
              child: Text(
                movement.note!,
                style: TextStyle(
                  fontSize: 10.5,
                  fontStyle: FontStyle.italic,
                  color: AppColors.textSecondary.withValues(alpha: 0.85),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
