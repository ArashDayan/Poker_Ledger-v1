import 'package:flutter/material.dart';
import '../core/localization/app_localizations.dart';
import '../core/theme/app_theme.dart';
import '../core/utils/currency_formatter.dart';
import '../models/enums.dart';
import '../services/session_service.dart';
import 'signature_pad.dart';

/// Result of a quick transaction sheet: the confirmed amount and (when
/// required) the captured signature.
class QuickTransactionResult {
  final double amount;
  final String? signature;
  const QuickTransactionResult({required this.amount, this.signature});
}

/// The fast-entry sheet used everywhere a banker needs to confirm an
/// amount in as few taps as possible: pre-filled amount (last used for
/// this player, or the session default), one tap to accept it as-is, a
/// compact signature pad only when the transaction type requires one.
/// This is the primary speed lever for the "2-4 taps" requirement — full
/// screens (PlayerActionScreen, edit dialogs) remain available for
/// anything that needs more detail.
///
/// Two safety nets live here, both non-blocking:
/// - The Confirm button disables itself the instant it's tapped, so a
///   double-tap under real table pressure can't submit twice.
/// - If [sessionId] is given and the amount looks wildly larger than
///   anything recorded so far tonight (the classic extra-zero typo), a
///   single "does this look right?" step is inserted before it's
///   returned — one tap to confirm, one tap to go back and fix it.
Future<QuickTransactionResult?> showQuickTransactionSheet(
  BuildContext context, {
  required String title,
  required TransactionType type,
  double? initialAmount,
  required CurrencyFormatter formatter,
  bool allowZero = false,
  String? sessionId,
}) {
  final ctrl = TextEditingController(
    text: initialAmount != null && initialAmount > 0 ? initialAmount.toStringAsFixed(0) : '',
  );
  String signature = '';
  bool submitting = false;
  // Re-entry (Phase 7) also requires the host signature: it is a
  // counted amount of carried chips being committed to the table.
  final requiresSignature =
      type == TransactionType.buyIn ||
      type == TransactionType.rebuy ||
      type == TransactionType.cashOut ||
      type == TransactionType.reentry;

  return showModalBottomSheet<QuickTransactionResult>(
    context: context,
    isScrollControlled: true,
    builder: (ctx) => Padding(
      padding: EdgeInsets.only(
        left: 16,
        right: 16,
        top: 16,
        bottom: MediaQuery.of(ctx).viewInsets.bottom + 16,
      ),
      child: StatefulBuilder(
        builder: (ctx, setSheetState) => SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(title, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
              const SizedBox(height: 14),
              TextField(
                controller: ctrl,
                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                autofocus: initialAmount == null || initialAmount <= 0,
                style: const TextStyle(fontSize: 26, fontWeight: FontWeight.bold),
                decoration: InputDecoration(
                  labelText: tr('amount'),
                  prefixText: formatter.symbol == '\$' ? '\$ ' : null,
                  suffixText: formatter.symbol == '\$' ? null : formatter.symbol,
                ),
              ),
              if (type == TransactionType.cashOut)
                Padding(
                  padding: EdgeInsets.only(top: 6),
                  child: Text(tr('zero_cashout_valid'),
                      style: TextStyle(fontSize: 11, color: AppColors.textSecondary)),
                ),
              if (requiresSignature) ...[
                const SizedBox(height: 16),
                SignaturePad(onChanged: (sig) => setSheetState(() => signature = sig)),
              ],
              const SizedBox(height: 16),
              ElevatedButton(
                onPressed: submitting
                    ? null
                    : () async {
                        final raw = ctrl.text.replaceAll(',', '').trim();
                        final amount = double.tryParse(raw);
                        if (amount == null || (amount < 0) || (amount == 0 && !allowZero)) {
                          ScaffoldMessenger.of(ctx).showSnackBar(
                            SnackBar(content: Text(tr('enter_valid_amount'))),
                          );
                          return;
                        }
                        if (requiresSignature && signature.isEmpty) {
                          ScaffoldMessenger.of(ctx).showSnackBar(
                            SnackBar(content: Text(tr('signature_required'))),
                          );
                          return;
                        }
                        setSheetState(() => submitting = true);

                        if (sessionId != null && SessionService.isAmountOutlier(sessionId, amount)) {
                          final proceed = await showDialog<bool>(
                            context: ctx,
                            builder: (dctx) => AlertDialog(
                              title: Text(tr('unusually_large')),
                              content: Text(
                                // formatRaw: this dialog exists to make the
                                // banker read the number, so Privacy Mode
                                // must not blank out the very thing being
                                // double-checked.
                                '${formatter.formatRaw(amount)} is much larger than anything '
                                "recorded so far tonight. Double-check it isn't an extra zero "
                                'before confirming.',
                              ),
                              actions: [
                                TextButton(
                                  onPressed: () => Navigator.pop(dctx, false),
                                  child: Text(tr('let_me_fix_it')),
                                ),
                                ElevatedButton(
                                  onPressed: () => Navigator.pop(dctx, true),
                                  child: Text(tr('its_correct')),
                                ),
                              ],
                            ),
                          );
                          if (proceed != true) {
                            setSheetState(() => submitting = false);
                            return;
                          }
                        }

                        if (!ctx.mounted) return;
                        Navigator.pop(
                          ctx,
                          QuickTransactionResult(
                            amount: amount,
                            signature: requiresSignature ? signature : null,
                          ),
                        );
                      },
                child: submitting
                    ? const SizedBox(
                        height: 20, width: 20, child: CircularProgressIndicator(strokeWidth: 2))
                    : Text(tr('confirm')),
              ),
            ],
          ),
        ),
      ),
    ),
  );
}
