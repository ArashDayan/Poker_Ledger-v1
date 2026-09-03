import 'package:flutter/material.dart';

import '../core/localization/app_localizations.dart';
import '../core/theme/app_theme.dart';
import '../core/utils/currency_formatter.dart';
import '../models/enums.dart';
import '../services/dual_verification_service.dart';
import 'signature_pad.dart';

/// Collects the SECOND authorisation for a sensitive/high-value
/// operation. The primary authorisation is captured by the operation's
/// own normal flow (quick transaction signature, transfer sheet, etc.).
///
/// Returns the second signature, or null if the operator cancelled. It
/// never writes anything itself; the caller records the two-authorisation
/// event via [DualVerificationService].
class DualVerificationSheet extends StatefulWidget {
  final double amount;
  final CurrencyFormatter formatter;
  final String operationLabel;

  const DualVerificationSheet({
    super.key,
    required this.amount,
    required this.formatter,
    required this.operationLabel,
  });

  @override
  State<DualVerificationSheet> createState() =>
      _DualVerificationSheetState();
}

class _DualVerificationSheetState extends State<DualVerificationSheet> {
  String _signature = '';

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Padding(
        padding: EdgeInsets.only(
          left: 18,
          right: 18,
          top: 18,
          bottom: MediaQuery.of(context).viewInsets.bottom + 20,
        ),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                tr('dual_verification_title'),
                style: const TextStyle(
                    fontSize: 17, fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 6),
              Text(
                '${widget.operationLabel} · ${widget.formatter.formatRaw(widget.amount)}',
                style: TextStyle(
                    fontSize: 12.5, color: AppColors.textSecondary),
              ),
              const SizedBox(height: 8),
              Text(
                tr('dual_verification_hint'),
                style: const TextStyle(
                    fontSize: 11.5, color: AppColors.warning),
              ),
              const SizedBox(height: 14),
              SignaturePad(onChanged: (sig) => setState(() => _signature = sig)),
              const SizedBox(height: 14),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton(
                      onPressed: () => Navigator.pop(context),
                      child: Text(tr('cancel')),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    flex: 2,
                    child: ElevatedButton(
                      onPressed: _signature.trim().isEmpty
                          ? null
                          : () => Navigator.pop(context, _signature),
                      child: Text(tr('confirm_second')),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Convenience wrapper for callers that only need a nullable signature.
Future<String?> showDualVerificationSheet(
  BuildContext context, {
  required double amount,
  required CurrencyFormatter formatter,
  required String operationLabel,
}) {
  return showModalBottomSheet<String>(
    context: context,
    isScrollControlled: true,
    builder: (_) => DualVerificationSheet(
      amount: amount,
      formatter: formatter,
      operationLabel: operationLabel,
    ),
  );
}

/// Convenience used by quick-action screens.
///
/// Returns `''` when no second authorisation is required. When one IS
/// required it returns the captured signature or null if the second
/// signer cancelled — the caller should abort the operation on null.
Future<String?> collectSecondVerifierIfRequired(
  BuildContext context, {
  required double amount,
  required AppCurrency currency,
  required String operationLabel,
}) async {
  if (!DualVerificationService.requiresSecond(amount)) return '';
  return showDualVerificationSheet(
    context,
    amount: amount,
    formatter: CurrencyFormatter(currency),
    operationLabel: operationLabel,
  );
}
