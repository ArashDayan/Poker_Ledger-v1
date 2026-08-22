import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../core/localization/app_localizations.dart';
import '../core/utils/currency_formatter.dart';
import '../models/chip_movement.dart';
import '../models/enums.dart';
import '../providers/chip_bank_provider.dart';
import '../services/chip_tracking_service.dart';
import 'chip_distribution_sheet.dart';

/// The one place every money screen goes to record physical chips.
///
/// WHY THIS EXISTS
/// The chip step used to live inline in the full player-action screen,
/// so the five faster paths a banker actually uses at a live table — the
/// seat quick-actions, the players-tab chips, the Action screen, and
/// add-player-with-buy-in — recorded money without ever touching the
/// chip ledger. The Bank then silently disagreed with reality.
///
/// Everything here is additive and non-blocking: the money transaction is
/// always written first and is never rolled back by a chip failure.
class ChipFlow {
  ChipFlow._();

  /// Chip tracking only applies to movements that physically hand chips
  /// across the table. Cash drop is money-only; rake has its own entry
  /// point because it can be table-level.
  static bool appliesTo(TransactionType type) =>
      type == TransactionType.buyIn ||
      type == TransactionType.rebuy ||
      type == TransactionType.cashOut ||
      type == TransactionType.rakeCollection ||
      // Dealer tips physically leave the table for the Bank, exactly
      // like rake, so they need the same denomination step.
      type == TransactionType.dealerTips;

  /// Buy-ins and rebuys take chips OUT of the bank; cash-outs and rake
  /// bring them back IN.
  static bool leavesBank(TransactionType type) =>
      type == TransactionType.buyIn || type == TransactionType.rebuy;

  static ChipMovementReason reasonFor(TransactionType type) {
    switch (type) {
      case TransactionType.rebuy:
        return ChipMovementReason.rebuy;
      case TransactionType.cashOut:
        return ChipMovementReason.cashOut;
      case TransactionType.rakeCollection:
        return ChipMovementReason.rake;
      case TransactionType.dealerTips:
        return ChipMovementReason.dealerTips;
      default:
        return ChipMovementReason.buyIn;
    }
  }

  /// Whether the banker has any inventory configured at all. With no
  /// denominations defined there is nothing to compose, so every caller
  /// silently skips the step.
  static bool isConfigured(BuildContext context) {
    try {
      context.read<ChipBankProvider>().refresh();
    } catch (_) {}
    return ChipBankService.allChips().isNotEmpty;
  }

  /// Asks the banker for a chip composition.
  ///
  /// Returns the chosen denominations, an empty map to skip, or null if
  /// the sheet was dismissed. A value mismatch produces a confirmation,
  /// never a refusal — the money must be recordable even when the chip
  /// maths is awkward mid-game.
  /// [source] — where the chips physically come from (Phase 2b,
  /// direction-correct composition). null = the Bank (buy-in / rebuy /
  /// float flows). Pass the person's location for return /
  /// redemption-shaped flows and the table's location for table-level
  /// rake: the sheet then suggests from and validates against that
  /// location, never against the bank.
  static Future<Map<String, int>?> ask(
    BuildContext context, {
    required double amount,
    required AppCurrency currency,
    Map<String, int>? initial,
    ChipLocation? source,
  }) async {
    if (!isConfigured(context)) return <String, int>{};

    final result = await showModalBottomSheet<Map<String, int>>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => ChipDistributionSheet(
        targetAmount: amount,
        currency: currency,
        initial: initial,
        source: source,
      ),
    );
    if (result == null || result.isEmpty) return result;

    final chipValue = ChipTrackingService.valueOf(result);
    if ((chipValue - amount).abs() < 0.005) return result;

    if (!context.mounted) return null;
    final fmt = CurrencyFormatter(currency);
    final proceed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(tr('chip_mismatch_title')),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(tr('chip_mismatch_body')),
            const SizedBox(height: 12),
            Text('${tr('target_amount')}: ${fmt.formatRaw(amount)}'),
            Text('${tr('chip_total')}: ${fmt.formatRaw(chipValue)}'),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(tr('cancel')),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(tr('record_anyway')),
          ),
        ],
      ),
    );
    // Declining drops the chip step only; the money entry continues.
    return proceed == true ? result : <String, int>{};
  }

  /// Writes the composition to the chip ledger, linked to the money
  /// transaction.
  ///
  /// Fully guarded: a chip failure surfaces to the banker but can never
  /// roll back or corrupt the financial record, which is already stored
  /// by the time this runs.
  ///
  /// [holderRefId] is the chip-holder reference (Phase 2a: the
  /// personId, or the seat row id for a legacy unlinked seat). Null
  /// means a table-level movement (e.g. rake collected from the table
  /// rather than a named player).
  static Future<void> apply(
    BuildContext context, {
    required Map<String, int>? distribution,
    required TransactionType type,
    required String sessionId,
    required String transactionId,
    String? holderRefId,
    String? tableId,
  }) async {
    if (distribution == null || distribution.isEmpty) return;

    // Where the chips sit when they are not in the Bank. A rake taken
    // from the table itself has no player, so it comes off the table.
    final counterparty = holderRefId != null
        ? ChipLocation.player(holderRefId)
        : (tableId != null ? ChipLocation.table(tableId) : ChipLocation.bank);

    // Rake and cash-out move chips INTO the bank; buy-in/rebuy out of it.
    final out = leavesBank(type);
    final from = out ? ChipLocation.bank : counterparty;
    final to = out ? counterparty : ChipLocation.bank;

    if (from == to) return; // nothing meaningful to record

    try {
      await context.read<ChipBankProvider>().recordDistribution(
            distribution: distribution,
            from: from,
            to: to,
            reason: reasonFor(type),
            sessionId: sessionId,
            transactionId: transactionId,
          );
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('$e')));
      }
    }
  }

  /// Convenience for the common case: ask, then apply.
  ///
  /// Call AFTER the money transaction is stored, passing its id.
  static Future<void> askAndApply(
    BuildContext context, {
    required double amount,
    required AppCurrency currency,
    required TransactionType type,
    required String sessionId,
    required String transactionId,
    String? holderRefId,
    String? tableId,
  }) async {
    final dist = await ask(context, amount: amount, currency: currency);
    if (!context.mounted) return;
    await apply(
      context,
      distribution: dist,
      type: type,
      sessionId: sessionId,
      transactionId: transactionId,
      holderRefId: holderRefId,
      tableId: tableId,
    );
  }

  /// Replaces the chip composition already recorded for a transaction.
  ///
  /// Reverses what is in force and applies the correction, so the end
  /// state matches what a correct original entry would have produced
  /// while the log still shows the mistake and the fix.
  static Future<void> edit(
    BuildContext context, {
    required String transactionId,
    required Map<String, int> distribution,
    required TransactionType type,
    required String sessionId,
    String? holderRefId,
    String? tableId,
  }) async {
    final counterparty = holderRefId != null
        ? ChipLocation.player(holderRefId)
        : (tableId != null ? ChipLocation.table(tableId) : ChipLocation.bank);
    final out = leavesBank(type);

    await ChipTrackingService.editDistribution(
      transactionId: transactionId,
      distribution: distribution,
      from: out ? ChipLocation.bank : counterparty,
      to: out ? counterparty : ChipLocation.bank,
      reason: reasonFor(type),
      sessionId: sessionId,
    );
    if (context.mounted) context.read<ChipBankProvider>().refresh();
  }
}
