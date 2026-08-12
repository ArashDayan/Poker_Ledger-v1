import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../core/localization/app_localizations.dart';
import '../../core/localization/enum_labels.dart';
import '../../core/theme/app_theme.dart';
import '../../core/utils/currency_formatter.dart';
import '../../models/enums.dart';
import '../../models/financial_event.dart';
import '../../services/financial_ledger_service.dart';

/// Player Account: derived Outstanding Balance plus history.
///
/// Step 3 adds Credit repayment only. Cash-in / credit / marker at the
/// table are captured next to chip Buy-in, not invented here. Front
/// Money and settlement stay later steps.
///
/// Every amount goes through [CurrencyFormatter.format] so Privacy Mode
/// cannot leak a figure here.
class PlayerAccountScreen extends StatefulWidget {
  final String personId;
  final String? displayName;
  final AppCurrency? sessionCurrency;
  final String? sessionId;

  const PlayerAccountScreen({
    super.key,
    required this.personId,
    this.displayName,
    this.sessionCurrency,
    this.sessionId,
  });

  @override
  State<PlayerAccountScreen> createState() => _PlayerAccountScreenState();
}

class _PlayerAccountScreenState extends State<PlayerAccountScreen> {
  @override
  Widget build(BuildContext context) {
    final account = FinancialLedgerService.accountFor(widget.personId);
    final name = widget.displayName ?? account.displayName;

    return Scaffold(
      appBar: AppBar(title: Text(tr('player_account'))),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
        children: [
          Text(
            name,
            style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 4),
          Text(
            tr('financial_account_chip_note'),
            style: const TextStyle(
                fontSize: 12, color: AppColors.textSecondary, height: 1.35),
          ),
          const SizedBox(height: 16),
          if (!account.hasHistory)
            _notRecordedCard()
          else ...[
            ...account.balances.map(_balanceCard),
            if (account.balances.any((b) => b.playerOwes)) ...[
              const SizedBox(height: 8),
              OutlinedButton.icon(
                onPressed: _repayCredit,
                icon: const Icon(Icons.south_west, size: 18),
                label: Text(tr('record_credit_repaid')),
              ),
            ],
            const SizedBox(height: 22),
            Row(
              children: [
                Container(width: 3, height: 13, color: AppColors.gold),
                const SizedBox(width: 9),
                Text(
                  tr('financial_history'),
                  style: const TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.bold,
                    letterSpacing: 1.2,
                    color: AppColors.textSecondary,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            if (account.events.isEmpty)
              Text(tr('no_financial_events'),
                  style: const TextStyle(color: AppColors.textSecondary))
            else
              ...account.events.map(_eventRow),
          ],
        ],
      ),
    );
  }

  Future<void> _repayCredit() async {
    final account = FinancialLedgerService.accountFor(widget.personId);
    final owing = account.balances.where((b) => b.playerOwes).toList();
    if (owing.isEmpty) return;
    final balance = owing.first;
    final currency = widget.sessionCurrency ?? balance.currency;
    final fmt = CurrencyFormatter(currency);
    final ctrl = TextEditingController(
      text: balance.amountMajor
          .toStringAsFixed(currency == AppCurrency.usd ? 2 : 0),
    );
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(tr('record_credit_repaid')),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(tr('credit_repaid_hint'),
                style: const TextStyle(
                    fontSize: 12.5, color: AppColors.textSecondary)),
            const SizedBox(height: 12),
            TextField(
              controller: ctrl,
              keyboardType:
                  const TextInputType.numberWithOptions(decimal: true),
              decoration: InputDecoration(
                labelText: tr('amount'),
                prefixText: fmt.symbol == r'$' ? r'$ ' : null,
                suffixText: fmt.symbol == r'$' ? null : fmt.symbol,
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: Text(tr('cancel'))),
          ElevatedButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: Text(tr('confirm'))),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    final amount = double.tryParse(ctrl.text.replaceAll(',', ''));
    if (amount == null || amount <= 0) return;
    try {
      await FinancialLedgerService.record(
        personId: widget.personId,
        currency: currency,
        type: FinancialEventType.creditRepaid,
        amount: amount,
        sessionId: widget.sessionId,
      );
      if (mounted) setState(() {});
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('$e')));
      }
    }
  }

  Widget _notRecordedCard() {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: AppColors.surfaceElevated,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppColors.divider),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(tr('outstanding_balance'),
              style: const TextStyle(
                  fontSize: 11,
                  letterSpacing: 1.1,
                  color: AppColors.textSecondary)),
          const SizedBox(height: 8),
          Text(tr('not_recorded'),
              style: const TextStyle(
                  fontSize: 26, fontWeight: FontWeight.bold)),
          const SizedBox(height: 8),
          Text(tr('not_recorded_hint'),
              style: const TextStyle(
                  fontSize: 12.5, color: AppColors.textSecondary, height: 1.35)),
        ],
      ),
    );
  }

  Widget _balanceCard(OutstandingBalance b) {
    final fmt = CurrencyFormatter(b.currency);
    final Color color;
    final String caption;
    final String figure;
    if (b.isNotRecorded) {
      color = AppColors.textSecondary;
      caption = tr('not_recorded');
      figure = tr('not_recorded');
    } else if (b.isSettled) {
      color = AppColors.accentGreen;
      caption = tr('financial_settled');
      figure = fmt.format(0);
    } else if (b.playerOwes) {
      color = AppColors.danger;
      caption = tr('player_owes_banker');
      figure = fmt.format(b.amountMajor);
    } else {
      color = AppColors.gold;
      caption = tr('banker_holds_money');
      figure = fmt.format(b.amountMajor.abs());
    }

    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.all(18),
        decoration: BoxDecoration(
          gradient: AppColors.heroGradient,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: AppColors.divider),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '${tr('outstanding_balance')} · ${_currencyLabel(b.currency)}',
              style: const TextStyle(
                  fontSize: 11,
                  letterSpacing: 1.1,
                  color: AppColors.textSecondary),
            ),
            const SizedBox(height: 8),
            FittedBox(
              fit: BoxFit.scaleDown,
              alignment: AlignmentDirectional.centerStart,
              child: Text(figure,
                  style: TextStyle(
                      fontSize: 28,
                      fontWeight: FontWeight.bold,
                      color: color)),
            ),
            const SizedBox(height: 4),
            Text(caption,
                style: TextStyle(fontSize: 12.5, color: color)),
          ],
        ),
      ),
    );
  }

  Widget _eventRow(FinancialEvent e) {
    final fmt = CurrencyFormatter(e.currency);
    final contribution = FinancialLedgerService.contributionOf(e);
    final isReversal = e.isReversal;
    final muted = isReversal || contribution == 0 && !e.isReversal &&
        (e.type == FinancialEventType.cashInForChips ||
            e.type == FinancialEventType.cashOutForChips);
    final amountText = contribution == 0
        ? fmt.format(e.amountMajor)
        : '${contribution > 0 ? '+' : '−'}${fmt.format(e.amountMajor)}';
    final amountColor = contribution > 0
        ? AppColors.danger
        : contribution < 0
            ? AppColors.gold
            : AppColors.textSecondary;

    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 12),
        decoration: BoxDecoration(
          color: AppColors.surfaceElevated,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: AppColors.divider),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    isReversal
                        ? '${tr('fin_reversal_of')} ${e.type.localizedLabel}'
                        : e.type.localizedLabel,
                    style: TextStyle(
                      fontWeight: FontWeight.bold,
                      fontSize: 13.5,
                      decoration:
                          isReversal ? TextDecoration.lineThrough : null,
                      color: muted
                          ? AppColors.textSecondary
                          : AppColors.textPrimary,
                    ),
                  ),
                  const SizedBox(height: 3),
                  Text(
                    DateFormat.yMMMd().add_jm().format(e.occurredAt),
                    style: const TextStyle(
                        fontSize: 11, color: AppColors.textSecondary),
                  ),
                  if (e.paymentMethod != null) ...[
                    const SizedBox(height: 2),
                    Text(e.paymentMethod!.localizedLabel,
                        style: const TextStyle(
                            fontSize: 11, color: AppColors.textSecondary)),
                  ],
                  if (e.reason != null && e.reason!.isNotEmpty) ...[
                    const SizedBox(height: 2),
                    Text(e.reason!,
                        style: const TextStyle(
                            fontSize: 11, color: AppColors.textSecondary)),
                  ],
                  if (e.note != null && e.note!.isNotEmpty) ...[
                    const SizedBox(height: 2),
                    Text(e.note!,
                        style: const TextStyle(
                            fontSize: 11, color: AppColors.textSecondary)),
                  ],
                  if (e.linkedTransactionId != null) ...[
                    const SizedBox(height: 2),
                    Text(tr('audit_linked_tx'),
                        style: const TextStyle(
                            fontSize: 10.5, color: AppColors.textSecondary)),
                  ],
                  if (e.isBackdated || isReversal)
                    Padding(
                      padding: const EdgeInsets.only(top: 4),
                      child: Wrap(
                        spacing: 6,
                        children: [
                          if (e.isBackdated) _badge(tr('backdated')),
                          if (isReversal) _badge(tr('reversed_event')),
                        ],
                      ),
                    ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Text(amountText,
                    style: TextStyle(
                        fontWeight: FontWeight.bold,
                        fontSize: 13.5,
                        color: amountColor)),
                const SizedBox(height: 2),
                Text(_currencyLabel(e.currency),
                    style: const TextStyle(
                        fontSize: 9.5, color: AppColors.textSecondary)),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _badge(String label) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: AppColors.warning.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(5),
        border: Border.all(color: AppColors.warning.withValues(alpha: 0.5)),
      ),
      child: Text(label,
          style: const TextStyle(
              fontSize: 9.5,
              fontWeight: FontWeight.bold,
              letterSpacing: 0.4,
              color: AppColors.warning)),
    );
  }

  String _currencyLabel(AppCurrency currency) =>
      currency == AppCurrency.usd ? 'USD' : tr('toman');
}
