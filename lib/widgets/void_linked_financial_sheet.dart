import 'package:flutter/material.dart';

import '../core/localization/app_localizations.dart';
import '../core/theme/app_theme.dart';
import '../models/financial_event.dart';
import '../core/localization/enum_labels.dart';
import '../core/utils/currency_formatter.dart';
import '../services/financial_ledger_service.dart';

/// Banker's choice when voiding a chip row that has linked financial events.
enum VoidChipFinancialChoice {
  chipOnly,
  chipAndReverseLinked,
}

/// Warns and asks. Never reverses by itself.
Future<VoidChipFinancialChoice?> askVoidChipWithLinkedFinancial(
  BuildContext context, {
  required String transactionId,
  required CurrencyFormatter formatter,
}) async {
  final linked = FinancialLedgerService.activeEventsLinkedTo(transactionId);
  if (linked.isEmpty) return VoidChipFinancialChoice.chipOnly;

  return showModalBottomSheet<VoidChipFinancialChoice>(
    context: context,
    isScrollControlled: true,
    builder: (ctx) => Padding(
      padding: EdgeInsets.only(
        left: 16,
        right: 16,
        top: 16,
        bottom: MediaQuery.of(ctx).viewInsets.bottom + 16,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(tr('void_linked_title'),
              style:
                  const TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
          const SizedBox(height: 8),
          Text(tr('void_linked_body'),
              style: const TextStyle(
                  fontSize: 13, color: AppColors.textSecondary, height: 1.35)),
          const SizedBox(height: 12),
          for (final e in linked) _linkedRow(e, formatter),
          const SizedBox(height: 14),
          ElevatedButton(
            onPressed: () => Navigator.pop(
                ctx, VoidChipFinancialChoice.chipAndReverseLinked),
            child: Text(tr('void_chip_and_reverse')),
          ),
          const SizedBox(height: 8),
          OutlinedButton(
            onPressed: () =>
                Navigator.pop(ctx, VoidChipFinancialChoice.chipOnly),
            child: Text(tr('void_chip_only')),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text(tr('cancel')),
          ),
        ],
      ),
    ),
  );
}

Widget _linkedRow(FinancialEvent e, CurrencyFormatter formatter) {
  return Padding(
    padding: const EdgeInsets.only(bottom: 6),
    child: Row(
      children: [
        Expanded(
          child: Text(e.type.localizedLabel,
              style: const TextStyle(fontSize: 13)),
        ),
        Text(formatter.format(e.amountMajor),
            style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13)),
      ],
    ),
  );
}
