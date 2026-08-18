import 'package:flutter/material.dart';

import '../core/localization/app_localizations.dart';
import '../core/player_result_visual.dart';
import '../core/theme/app_theme.dart';
import '../core/utils/currency_formatter.dart';
import '../screens/player_account/player_account_screen.dart';
import '../services/rebate_service.dart';
import '../services/session_settlement_view.dart';

/// Three separate settlement blocks. Never adds them into one number.
class SessionSettlementSummary extends StatelessWidget {
  final SessionSettlementView view;
  final CurrencyFormatter formatter;
  final bool showPlayers;

  const SessionSettlementSummary({
    super.key,
    required this.view,
    required this.formatter,
    this.showPlayers = true,
  });

  @override
  Widget build(BuildContext context) {
    final fmt = formatter;
    final fin = view.financial;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _section(tr('settle_poker_chips'), [
          _row(tr('settle_buy_in'), fmt.format(view.buyIn)),
          _row(tr('settle_rebuy'), fmt.format(view.rebuy)),
          _row(tr('money_in_buyin_rebuy'), fmt.format(view.chipBalance.moneyIn)),
          _row(tr('settle_cash_out'), fmt.format(view.cashOut)),
          _row(tr('rake_collected'), fmt.format(view.rake), color: AppColors.gold),
          _row(tr('dealer_tips'), fmt.format(view.dealerTips),
              color: AppColors.warning),
          _row(tr('money_out_cashout_rake_tips'),
              fmt.format(view.chipBalance.moneyOut)),
          _row(tr('host_profit'), fmt.format(view.hostProfit),
              color: AppColors.accentGreen),
          _row(tr('settle_current_pot'), fmt.format(view.moneyStillInPlay)),
          if (view.cashDrop > 0)
            _row(tr('cash_drops'), fmt.format(view.cashDrop)),
        ]),
        const SizedBox(height: 12),
        _section(tr('settle_financial_account'), [
          _row(tr('settle_credit_issued'), fmt.format(fin.creditIssued)),
          _row(tr('settle_credit_repaid'), fmt.format(fin.creditRepaid)),
          _row(tr('settle_unbacked'), fmt.format(fin.cashOutUnbacked)),
          _row(tr('settle_cash_in_for_chips'), fmt.format(fin.cashInForChips)),
          _row(tr('settle_cash_out_for_chips'), fmt.format(fin.cashOutForChips)),
        ]),
        const SizedBox(height: 12),
        _section(tr('settle_deposit'), [
          _row(tr('settle_deposit_in'), fmt.format(fin.depositIn)),
          _row(tr('settle_deposit_used'), fmt.format(fin.depositUsedForChips)),
          _row(tr('settle_deposit_returned'), fmt.format(fin.depositReturned)),
          _row(tr('settle_deposit_remaining'), fmt.format(fin.depositRemaining),
              color: fin.hasDepositRemaining ? AppColors.gold : null),
        ]),
        if (_sessionRebate != null) ...[
          const SizedBox(height: 12),
          _section(tr('rebate_title'), [
            _row(tr('rebate_own_cash_in'),
                fmt.format(_sessionRebate!.playerCashIn)),
            _row(tr('rebate_original_loss'),
                fmt.format(_sessionRebate!.originalLoss)),
            _row(tr('rebate_granted'), fmt.format(_sessionRebate!.granted)),
            _row(tr('rebate_lost_in_play'),
                fmt.format(_sessionRebate!.lostInPlay)),
            _row(tr('rebate_clawback'), fmt.format(_sessionRebate!.clawback)),
            _row(tr('rebate_waived'), fmt.format(_sessionRebate!.waived)),
            _row(tr('rebate_remaining_loss'),
                fmt.format(_sessionRebate!.remainingLoss)),
            _row(tr('rebate_paid_out'), fmt.format(_sessionRebate!.paidOut)),
            _row(tr('rebate_actual_paid'),
                fmt.format(_sessionRebate!.actualCashPaid)),
            _row(tr('rebate_house_retained'),
                fmt.format(_sessionRebate!.houseRetained)),
            if (_chipRec != null && _chipRec!.issuedMinor > 0) ...[
              _row(tr('rebate_chips_issued'),
                  fmt.format(_chipRec!.issuedMajor)),
              _row(tr('rebate_books_residual'),
                  fmt.format(_chipRec!.residualAfterDiscount)),
              _row(tr('rebate_implied_in_play'),
                  fmt.format(_chipRec!.impliedStillInPlay)),
            ],
          ]),
          if (_chipRec != null && _chipRec!.issuedMinor > 0) ...[
            const SizedBox(height: 10),
            _warn(_chipRec!.explainsGap
                ? tr('settle_rebate_chips_explained')
                : tr('settle_warn_rebate_chips')),
          ],
        ],
        if (fin.hasDepositRemaining || fin.hasOpenCredit) ...[
          const SizedBox(height: 10),
          if (fin.hasDepositRemaining)
            _warn(tr('settle_warn_deposit')),
          if (fin.hasOpenCredit) ...[
            if (fin.hasDepositRemaining) const SizedBox(height: 6),
            _warn(fin.cashOutUnbackedMinor > 0
                ? tr('settle_warn_unbacked')
                : tr('settle_warn_credit')),
          ],
        ],
        if (showPlayers) ...[
          const SizedBox(height: 16),
          Text(tr('players'),
              style:
                  const TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
          const SizedBox(height: 8),
          for (final p in view.players) _playerCard(context, p, fmt),
        ],
      ],
    );
  }

  RebateSnapshot? get _sessionRebate {
    RebateSnapshot? acc;
    for (final row in view.players) {
      final personId = row.player.personId;
      if (personId == null || personId.isEmpty) continue;
      final snap = RebateService.snapshot(
        sessionId: view.sessionId,
        personId: personId,
        currency: view.currency,
      );
      if (!snap.hasActivity) continue;
      acc = acc == null
          ? snap
          : RebateSnapshot(
              currency: view.currency,
              playerCashInMinor:
                  acc.playerCashInMinor + snap.playerCashInMinor,
              playerCashOutMinor:
                  acc.playerCashOutMinor + snap.playerCashOutMinor,
              grossLossMinor: acc.grossLossMinor + snap.grossLossMinor,
              grantedMinor: acc.grantedMinor + snap.grantedMinor,
              returnedMinor: acc.returnedMinor + snap.returnedMinor,
              clawbackMinor: acc.clawbackMinor + snap.clawbackMinor,
              waivedMinor: acc.waivedMinor + snap.waivedMinor,
              paidOutMinor: acc.paidOutMinor + snap.paidOutMinor,
              exposedMinor: acc.exposedMinor + snap.exposedMinor,
              actualCashPaidMinor:
                  acc.actualCashPaidMinor + snap.actualCashPaidMinor,
              houseRetainedMinor:
                  acc.houseRetainedMinor + snap.houseRetainedMinor,
              originalLossMinor:
                  acc.originalLossMinor + snap.originalLossMinor,
              remainingLossMinor:
                  acc.remainingLossMinor + snap.remainingLossMinor,
              chipGrantMinor: acc.chipGrantMinor + snap.chipGrantMinor,
              cashGrantMinor: acc.cashGrantMinor + snap.cashGrantMinor,
              recorded: true,
            );
    }
    return acc;
  }

  DiscountChipReconciliation? get _chipRec {
    if ((_sessionRebate?.chipGrantMinor ?? 0) <= 0 &&
        RebateService.chipGrantsIssuedMinor(
                view.sessionId, view.currency) <=
            0) {
      return null;
    }
    return RebateService.chipReconciliation(
      sessionId: view.sessionId,
      currency: view.currency,
      rawDiscrepancy: view.chipBalance.discrepancy,
      moneyStillInPlay: view.moneyStillInPlay,
    );
  }

  Widget _section(String title, List<Widget> rows) {
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 10),
      decoration: BoxDecoration(
        color: AppColors.surfaceElevated,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AppColors.divider),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(title,
              style: const TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.bold,
                  letterSpacing: 1.1,
                  color: AppColors.textSecondary)),
          const SizedBox(height: 8),
          ...rows,
        ],
      ),
    );
  }

  Widget _row(String label, String value, {Color? color}) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        children: [
          Expanded(
            child: Text(label,
                style: const TextStyle(
                    fontSize: 12.5, color: AppColors.textSecondary)),
          ),
          Text(value,
              style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.bold,
                  color: color ?? AppColors.textPrimary)),
        ],
      ),
    );
  }

  Widget _playerRebateLine(String personId, CurrencyFormatter fmt) {
    final snap = RebateService.snapshot(
      sessionId: view.sessionId,
      personId: personId,
      currency: view.currency,
    );
    if (snap.grantedMinor <= 0) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(top: 2),
      child: Text(
        '${tr('rebate_granted')} ${fmt.format(snap.granted)}'
        ' · ${tr('rebate_lost_in_play')} ${fmt.format(snap.lostInPlay)}'
        ' · ${tr('rebate_clawback')} ${fmt.format(snap.clawback)}'
        ' · ${tr('rebate_waived')} ${fmt.format(snap.waived)}'
        ' · ${tr('rebate_actual_paid')} ${fmt.format(snap.actualCashPaid)}',
        style: const TextStyle(fontSize: 11, color: AppColors.textSecondary),
      ),
    );
  }

  Widget _warn(String text) {
    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: AppColors.warning.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: AppColors.warning),
      ),
      child: Text(text,
          style: const TextStyle(fontSize: 12, color: AppColors.warning)),
    );
  }

  Widget _playerCard(
    BuildContext context,
    PlayerSettlementRow row,
    CurrencyFormatter fmt,
  ) {
    final pl = row.chipProfitLoss;
    final player = row.player;
    final visual = PlayerResultVisuals.of(
      occupied: true,
      hasCashedOut: row.hasCashedOut,
      profitLoss: pl,
    );
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Material(
        color: AppColors.surfaceElevated,
        borderRadius: BorderRadius.circular(14),
        child: InkWell(
          borderRadius: BorderRadius.circular(14),
          onTap: player.personId == null || player.personId!.isEmpty
              ? null
              : () => Navigator.of(context).push(MaterialPageRoute(
                    builder: (_) => PlayerAccountScreen(
                      personId: player.personId!,
                      displayName: player.name,
                      sessionCurrency: view.currency,
                      sessionId: view.sessionId,
                    ),
                  )),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 11),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: AppColors.divider),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        '${tr('seat')} ${player.seatNumber} · ${player.name}',
                        style: const TextStyle(
                            fontWeight: FontWeight.bold, fontSize: 13.5),
                      ),
                    ),
                    Text(
                      '${pl >= 0 ? '+' : ''}${fmt.format(pl)}',
                      style: TextStyle(
                        fontWeight: FontWeight.bold,
                        color: PlayerResultVisuals.amountColor(visual),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                Text(
                  '${tr('settle_buy_in')} ${fmt.format(row.buyIn)}'
                  ' · ${tr('settle_rebuy')} ${fmt.format(row.rebuy)}'
                  ' · ${tr('settle_cash_out')} ${fmt.format(row.cashOut)}',
                  style: const TextStyle(
                      fontSize: 11, color: AppColors.textSecondary),
                ),
                const SizedBox(height: 2),
                Text(
                  row.hasCashedOut
                      ? tr('settle_cashed_out')
                      : tr('settle_not_cashed_out'),
                  style: TextStyle(
                    fontSize: 11,
                    color: row.hasCashedOut
                        ? AppColors.accentGreen
                        : AppColors.warning,
                  ),
                ),
                if (row.financial.recorded) ...[
                  const SizedBox(height: 2),
                  Text(
                    '${tr('settle_deposit_remaining')}: '
                    '${fmt.format(row.financial.depositRemaining)}'
                    ' · ${tr('settle_cash_in_for_chips')}: '
                    '${fmt.format(row.financial.cashInForChips)}',
                    style: const TextStyle(
                        fontSize: 11, color: AppColors.textSecondary),
                  ),
                ],
                if (row.player.personId != null &&
                    row.player.personId!.isNotEmpty)
                  _playerRebateLine(row.player.personId!, fmt),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
