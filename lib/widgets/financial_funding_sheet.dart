import 'package:flutter/material.dart';

import '../core/localization/app_localizations.dart';
import '../core/theme/app_theme.dart';
import '../core/utils/currency_formatter.dart';
import '../services/financial_capture.dart';
import 'signature_pad.dart';

/// Asks how chips just issued were funded. Never infers from Buy-in.
///
/// Dismissing the sheet returns [ChipFunding.notRecorded] so a cancelled
/// prompt cannot invent a payment. Marker collects a signature here.
Future<ChipFundingChoice> askChipFunding(
  BuildContext context, {
  required CurrencyFormatter formatter,
  required double amount,
}) async {
  final result = await showModalBottomSheet<ChipFundingChoice>(
    context: context,
    isScrollControlled: true,
    builder: (ctx) => _FundingSheet(formatter: formatter, amount: amount),
  );
  return result ??
      const ChipFundingChoice(ChipFunding.notRecorded);
}

class ChipFundingChoice {
  final ChipFunding funding;
  final String? markerSignature;

  const ChipFundingChoice(this.funding, {this.markerSignature});
}

class _FundingSheet extends StatefulWidget {
  final CurrencyFormatter formatter;
  final double amount;

  const _FundingSheet({required this.formatter, required this.amount});

  @override
  State<_FundingSheet> createState() => _FundingSheetState();
}

class _FundingSheetState extends State<_FundingSheet> {
  String _markerSig = '';
  bool _signingMarker = false;

  @override
  Widget build(BuildContext context) {
    final fmt = widget.formatter;
    return Padding(
      padding: EdgeInsets.only(
        left: 16,
        right: 16,
        top: 16,
        bottom: MediaQuery.of(context).viewInsets.bottom + 16,
      ),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(tr('how_was_this_paid'),
                style: const TextStyle(
                    fontSize: 18, fontWeight: FontWeight.bold)),
            const SizedBox(height: 6),
            Text(
              '${tr('amount')}: ${fmt.format(widget.amount)}',
              style: const TextStyle(
                  fontSize: 13, color: AppColors.textSecondary),
            ),
            const SizedBox(height: 4),
            Text(tr('funding_not_inferred'),
                style: const TextStyle(
                    fontSize: 12, color: AppColors.textSecondary, height: 1.35)),
            const SizedBox(height: 14),
            _choice(
              icon: Icons.payments_outlined,
              label: tr('funding_paid_cash'),
              subtitle: tr('funding_paid_cash_hint'),
              onTap: () => Navigator.pop(
                context,
                const ChipFundingChoice(ChipFunding.paidCash),
              ),
            ),
            _choice(
              icon: Icons.handshake_outlined,
              label: tr('funding_credit'),
              subtitle: tr('funding_credit_hint'),
              onTap: () => Navigator.pop(
                context,
                const ChipFundingChoice(ChipFunding.credit),
              ),
            ),
            _choice(
              icon: Icons.draw_outlined,
              label: tr('funding_marker'),
              subtitle: tr('funding_marker_hint'),
              onTap: () => setState(() => _signingMarker = true),
            ),
            _choice(
              icon: Icons.more_horiz,
              label: tr('funding_not_recorded'),
              subtitle: tr('funding_not_recorded_hint'),
              onTap: () => Navigator.pop(
                context,
                const ChipFundingChoice(ChipFunding.notRecorded),
              ),
            ),
            if (_signingMarker) ...[
              const SizedBox(height: 12),
              Text(tr('marker_sign_hint'),
                  style: const TextStyle(
                      fontSize: 12, color: AppColors.textSecondary)),
              const SizedBox(height: 8),
              SignaturePad(
                  onChanged: (sig) => setState(() => _markerSig = sig)),
              const SizedBox(height: 10),
              ElevatedButton(
                onPressed: _markerSig.isEmpty
                    ? null
                    : () => Navigator.pop(
                          context,
                          ChipFundingChoice(ChipFunding.marker,
                              markerSignature: _markerSig),
                        ),
                child: Text(tr('confirm_marker')),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _choice({
    required IconData icon,
    required String label,
    required String subtitle,
    required VoidCallback onTap,
  }) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Material(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(12),
        child: InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: onTap,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 11),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: AppColors.divider),
            ),
            child: Row(
              children: [
                Icon(icon, color: AppColors.gold, size: 22),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(label,
                          style: const TextStyle(
                              fontWeight: FontWeight.bold, fontSize: 14)),
                      const SizedBox(height: 2),
                      Text(subtitle,
                          style: const TextStyle(
                              fontSize: 11.5,
                              color: AppColors.textSecondary,
                              height: 1.3)),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Asks how a chip cash-out was settled. Symmetric with [askChipFunding].
Future<ChipCashOutFunding> askChipCashOutFunding(
  BuildContext context, {
  required CurrencyFormatter formatter,
  required double amount,
}) async {
  if (amount <= 0) return ChipCashOutFunding.notRecorded;

  final result = await showModalBottomSheet<ChipCashOutFunding>(
    context: context,
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
          Text(tr('how_was_cashout_paid'),
              style: const TextStyle(
                  fontSize: 18, fontWeight: FontWeight.bold)),
          const SizedBox(height: 6),
          Text(
            '${tr('amount')}: ${formatter.format(amount)}',
            style: const TextStyle(
                fontSize: 13, color: AppColors.textSecondary),
          ),
          const SizedBox(height: 4),
          Text(tr('cashout_funding_hint'),
              style: const TextStyle(
                  fontSize: 12, color: AppColors.textSecondary, height: 1.35)),
          const SizedBox(height: 14),
          ListTile(
            leading: const Icon(Icons.payments_outlined, color: AppColors.gold),
            title: Text(tr('cashout_paid_cash')),
            subtitle: Text(tr('cashout_paid_cash_hint'),
                style: const TextStyle(fontSize: 12)),
            onTap: () =>
                Navigator.pop(ctx, ChipCashOutFunding.paidCash),
          ),
          ListTile(
            leading:
                const Icon(Icons.warning_amber_outlined, color: AppColors.warning),
            title: Text(tr('cashout_unbacked')),
            subtitle: Text(tr('cashout_unbacked_hint'),
                style: const TextStyle(fontSize: 12)),
            onTap: () =>
                Navigator.pop(ctx, ChipCashOutFunding.unbacked),
          ),
          ListTile(
            leading: const Icon(Icons.more_horiz, color: AppColors.textSecondary),
            title: Text(tr('funding_not_recorded')),
            subtitle: Text(tr('funding_not_recorded_hint'),
                style: const TextStyle(fontSize: 12)),
            onTap: () =>
                Navigator.pop(ctx, ChipCashOutFunding.notRecorded),
          ),
          const SizedBox(height: 8),
        ],
      ),
    ),
  );
  return result ?? ChipCashOutFunding.notRecorded;
}
