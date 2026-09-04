import 'package:flutter/material.dart';

import '../core/localization/app_localizations.dart';
import '../core/theme/app_theme.dart';
import '../core/utils/currency_formatter.dart';
import '../models/enums.dart';
import '../services/dual_verification_service.dart';
import 'signature_pad.dart';

/// The two collected authorisation actors for a sensitive operation.
///
/// The sheet requires BOTH a second-verifier identity (operator-entered
/// free text, matching the existing `operatorName`/floor-identity
/// convention) and the second signature. This is deliberately not a new
/// identity architecture: it is the same operator-entered name field the
/// transfer/cash-out workflows already use for the primary operator, so
/// the audit event can identify both authorising actors instead of only
/// recording an anonymous second signature.
class SecondVerificationResult {
  final String name;
  final String signature;

  const SecondVerificationResult({required this.name, required this.signature});

  /// Sentinel for "dual verification is not required for this amount".
  const SecondVerificationResult.none()
      : name = '',
        signature = '';

  bool get isRequired => name.isNotEmpty || signature.isNotEmpty;
}

/// Collects the SECOND authorisation for a sensitive/high-value
/// operation. The primary authorisation is captured by the operation's
/// own normal flow (quick transaction signature, transfer sheet, etc.).
///
/// Returns a [SecondVerificationResult] whose [name] and [signature]
/// identify the second verifier, or null if the operator cancelled. It
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
  final _verifierController = TextEditingController();
  String _signature = '';

  @override
  void dispose() {
    _verifierController.dispose();
    super.dispose();
  }

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
              TextField(
                controller: _verifierController,
                textCapitalization: TextCapitalization.words,
                onChanged: (_) => setState(() {}),
                decoration: InputDecoration(
                  labelText: tr('dual_verification_verifier_name'),
                  hintText: tr('dual_verification_verifier_name_hint'),
                  border: const OutlineInputBorder(),
                ),
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
                      onPressed:
                          _signature.trim().isEmpty ||
                                  _verifierController.text.trim().isEmpty
                              ? null
                              : () => Navigator.pop(
                                    context,
                                    SecondVerificationResult(
                                      name:
                                          _verifierController.text.trim(),
                                      signature: _signature,
                                    ),
                                  ),
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

/// Convenience wrapper for callers that need the second-verifier result.
Future<SecondVerificationResult?> showDualVerificationSheet(
  BuildContext context, {
  required double amount,
  required CurrencyFormatter formatter,
  required String operationLabel,
}) {
  return showModalBottomSheet<SecondVerificationResult>(
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
/// Returns `SecondVerificationResult.none()` when no second
/// authorisation is required. When one IS required it returns the
/// captured identity + signature, or null if the second verifier
/// cancelled — the caller should abort the operation on null.
Future<SecondVerificationResult?> collectSecondVerifierIfRequired(
  BuildContext context, {
  required double amount,
  required AppCurrency currency,
  required String operationLabel,
}) async {
  if (!DualVerificationService.requiresSecond(amount)) {
    return const SecondVerificationResult.none();
  }
  return showDualVerificationSheet(
    context,
    amount: amount,
    formatter: CurrencyFormatter(currency),
    operationLabel: operationLabel,
  );
}
