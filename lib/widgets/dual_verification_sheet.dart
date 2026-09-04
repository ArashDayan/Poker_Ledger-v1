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

  /// First operator identity + signature, collected only in the
  /// always-on mode ([DualVerificationSheet.collectOperator]) used by
  /// the finalised D1/D2 decisions.
  final String operatorName;
  final String operatorSignature;

  /// Mandatory adjustment reason, collected only in the always-on mode
  /// ([DualVerificationSheet.requireReason]).
  final String reason;

  const SecondVerificationResult({
    required this.name,
    required this.signature,
    this.operatorName = '',
    this.operatorSignature = '',
    this.reason = '',
  });

  /// Sentinel for "dual verification is not required for this amount".
  const SecondVerificationResult.none()
      : name = '',
        signature = '',
        operatorName = '',
        operatorSignature = '',
        reason = '';

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
  /// Amount + formatter drive the subtitle in the threshold-based
  /// mode. Both are optional: the always-on mode (D1/D2) passes
  /// [amountText] instead -- a manual inventory adjustment shows a
  /// chip count, not a currency amount.
  final double? amount;
  final CurrencyFormatter? formatter;
  final String operationLabel;

  /// Pre-formatted subtitle (e.g. "100 -> 80 x 200" or "+1 x 200"),
  /// preferred over [amount]/[formatter] when given.
  final String? amountText;

  /// Always-on mode (D1/D2): also collect the FIRST operator's name
  /// and signature alongside the second verifier.
  final bool collectOperator;

  /// Always-on mode (D1/D2): collect the mandatory adjustment reason.
  final bool requireReason;

  final String? reasonHint;

  const DualVerificationSheet({
    super.key,
    this.amount,
    this.formatter,
    required this.operationLabel,
    this.amountText,
    this.collectOperator = false,
    this.requireReason = false,
    this.reasonHint,
  });

  @override
  State<DualVerificationSheet> createState() =>
      _DualVerificationSheetState();
}

class _DualVerificationSheetState extends State<DualVerificationSheet> {
  final _verifierController = TextEditingController();
  final _operatorController = TextEditingController();
  final _reasonController = TextEditingController();
  String _signature = '';
  String _operatorSignature = '';

  @override
  void dispose() {
    _verifierController.dispose();
    _operatorController.dispose();
    _reasonController.dispose();
    super.dispose();
  }

  bool get _canConfirm {
    if (_signature.trim().isEmpty) return false;
    if (_verifierController.text.trim().isEmpty) return false;
    if (widget.collectOperator &&
        (_operatorSignature.trim().isEmpty ||
            _operatorController.text.trim().isEmpty)) {
      return false;
    }
    if (widget.requireReason && _reasonController.text.trim().isEmpty) {
      return false;
    }
    return true;
  }

  /// Subtitle: the pre-formatted always-mode text, else the formatted
  /// currency amount, else just the operation label.
  String get _subtitle {
    final text = widget.amountText;
    if (text != null && text.isNotEmpty) {
      return '${widget.operationLabel} · $text';
    }
    final fmt = widget.formatter;
    final amount = widget.amount;
    if (fmt != null && amount != null) {
      return '${widget.operationLabel} · ${fmt.formatRaw(amount)}';
    }
    return widget.operationLabel;
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
                _subtitle,
                style: TextStyle(
                    fontSize: 12.5, color: AppColors.textSecondary),
              ),
              const SizedBox(height: 8),
              Text(
                tr(widget.requireReason
                    ? 'dual_verification_always_hint'
                    : 'dual_verification_hint'),
                style: const TextStyle(
                    fontSize: 11.5, color: AppColors.warning),
              ),
              const SizedBox(height: 14),
              if (widget.requireReason) ...[
                TextField(
                  controller: _reasonController,
                  minLines: 1,
                  maxLines: 2,
                  onChanged: (_) => setState(() {}),
                  decoration: InputDecoration(
                    labelText: tr('adjustment_reason_label'),
                    hintText: widget.reasonHint ?? tr('adjustment_reason_hint'),
                    border: const OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 14),
              ],
              if (widget.collectOperator) ...[
                TextField(
                  controller: _operatorController,
                  textCapitalization: TextCapitalization.words,
                  onChanged: (_) => setState(() {}),
                  decoration: InputDecoration(
                    labelText: tr('dual_verification_operator_name'),
                    hintText: tr('dual_verification_operator_name_hint'),
                    border: const OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 14),
                SignaturePad(
                  caption: tr('dual_verification_operator_signature'),
                  onChanged: (sig) =>
                      setState(() => _operatorSignature = sig),
                ),
                const SizedBox(height: 14),
              ],
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
              SignaturePad(
                caption: tr('dual_verification_verifier_signature'),
                onChanged: (sig) => setState(() => _signature = sig),
              ),
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
                      onPressed: !_canConfirm
                          ? null
                          : () => Navigator.pop(
                                context,
                                SecondVerificationResult(
                                  name: _verifierController.text.trim(),
                                  signature: _signature,
                                  operatorName:
                                      _operatorController.text.trim(),
                                  operatorSignature: _operatorSignature,
                                  reason: _reasonController.text.trim(),
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

/// ALWAYS-ON two-person collection (finalised decisions D1/D2): manual
/// chip-bank inventory adjustments and the standalone player-holding
/// reconciliation. No threshold is consulted -- the sheet is shown for
/// every call. Collects the mandatory reason, the FIRST operator's name
/// + signature and the SECOND verifier's name + signature, returning
/// the [DualAuthorization] the service boundaries require, or null if
/// the operator cancelled (callers must abort).
Future<DualAuthorization?> collectDualAuthorization(
  BuildContext context, {
  required String operationLabel,
  String? amountText,
  String? reasonHint,
}) async {
  final result = await showModalBottomSheet<SecondVerificationResult>(
    context: context,
    isScrollControlled: true,
    builder: (_) => DualVerificationSheet(
      operationLabel: operationLabel,
      amountText: amountText,
      collectOperator: true,
      requireReason: true,
      reasonHint: reasonHint,
    ),
  );
  if (result == null) return null;
  return DualAuthorization(
    reason: result.reason,
    operatorName: result.operatorName,
    operatorSignatureBase64: result.operatorSignature,
    secondVerifierName: result.name,
    secondVerifierSignature: result.signature,
  );
}
