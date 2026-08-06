import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/localization/app_localizations.dart';
import '../../core/theme/app_theme.dart';
import '../../core/utils/currency_formatter.dart';
import '../../providers/session_provider.dart';
import '../../services/tournament_service.dart';

/// Prize distribution editor.
///
/// Percentages must total exactly 100 before they can be saved — a prize
/// structure that pays out 97% or 103% of the pool is a dispute waiting
/// to happen, so the save button stays disabled until the numbers are
/// right and the running total is shown live.
class PayoutEditorScreen extends StatefulWidget {
  const PayoutEditorScreen({super.key});

  @override
  State<PayoutEditorScreen> createState() => _PayoutEditorScreenState();
}

class _PayoutEditorScreenState extends State<PayoutEditorScreen> {
  late List<double> _pcts;

  @override
  void initState() {
    super.initState();
    _pcts = [...context.read<SessionProvider>().payoutTable.map((p) => p.percentage)];
    if (_pcts.isEmpty) _pcts = [100];
  }

  double get _total => _pcts.fold(0.0, (a, b) => a + b);
  bool get _valid => (_total - 100).abs() < 0.01;

  @override
  Widget build(BuildContext context) {
    final provider = context.watch<SessionProvider>();
    final session = provider.current!;
    final fmt = CurrencyFormatter(session.currency);
    final pool = provider.prizePool;

    return Scaffold(
      appBar: AppBar(title: Text(tr('payouts'))),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
        children: [
          Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: AppColors.surfaceElevated,
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: AppColors.gold.withValues(alpha: 0.3)),
            ),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(tr('prize_pool'),
                          style: const TextStyle(
                              fontSize: 11, color: AppColors.textSecondary)),
                      const SizedBox(height: 3),
                      Text(fmt.format(pool),
                          style: const TextStyle(
                              fontSize: 20,
                              fontWeight: FontWeight.bold,
                              color: AppColors.gold)),
                    ],
                  ),
                ),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Text(tr('total'),
                        style: const TextStyle(
                            fontSize: 11, color: AppColors.textSecondary)),
                    const SizedBox(height: 3),
                    Text(
                      '${_total.toStringAsFixed(1)}%',
                      style: TextStyle(
                        fontSize: 20,
                        fontWeight: FontWeight.bold,
                        color:
                            _valid ? AppColors.accentGreen : AppColors.danger,
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
          if (!_valid) ...[
            const SizedBox(height: 10),
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: AppColors.danger.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: AppColors.danger.withValues(alpha: 0.5)),
              ),
              child: Row(
                children: [
                  const Icon(Icons.warning_amber_rounded,
                      size: 16, color: AppColors.danger),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(tr('payouts_must_total_100'),
                        style: const TextStyle(fontSize: 11.5)),
                  ),
                ],
              ),
            ),
          ],
          const SizedBox(height: 16),
          for (var i = 0; i < _pcts.length; i++) _spotRow(i, pool, fmt),
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: () => setState(() => _pcts.add(0)),
                  icon: const Icon(Icons.add, size: 17),
                  label: Text(tr('add_place')),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: () => setState(() {
                    _pcts = TournamentService.defaultPayouts(
                        provider.players.length);
                  }),
                  icon: const Icon(Icons.auto_fix_high, size: 17),
                  label: Text(tr('suggest')),
                ),
              ),
            ],
          ),
          const SizedBox(height: 22),
          ElevatedButton(
            onPressed: _valid
                ? () async {
                    await provider.savePayoutPercentages(_pcts);
                    if (context.mounted) Navigator.pop(context);
                  }
                : null,
            child: Text(tr('save')),
          ),
        ],
      ),
    );
  }

  Widget _spotRow(int i, double pool, CurrencyFormatter fmt) {
    final amount = pool * _pcts[i] / 100;
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Row(
        children: [
          Container(
            width: 34,
            height: 34,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: (i == 0 ? AppColors.gold : AppColors.textSecondary)
                  .withValues(alpha: 0.14),
              border: Border.all(
                color: i == 0 ? AppColors.gold : AppColors.divider,
              ),
            ),
            child: Text('${i + 1}',
                style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.bold,
                    color:
                        i == 0 ? AppColors.gold : AppColors.textSecondary)),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Slider(
              value: _pcts[i].clamp(0, 100),
              max: 100,
              divisions: 200,
              label: '${_pcts[i].toStringAsFixed(1)}%',
              onChanged: (v) => setState(() => _pcts[i] = v),
            ),
          ),
          SizedBox(
            width: 52,
            child: Text('${_pcts[i].toStringAsFixed(1)}%',
                textAlign: TextAlign.end,
                style: const TextStyle(
                    fontSize: 12.5, fontWeight: FontWeight.bold)),
          ),
          const SizedBox(width: 8),
          SizedBox(
            width: 78,
            child: Text(fmt.format(amount),
                textAlign: TextAlign.end,
                style: const TextStyle(
                    fontSize: 11.5, color: AppColors.gold)),
          ),
          IconButton(
            visualDensity: VisualDensity.compact,
            icon: const Icon(Icons.close, size: 16),
            onPressed: _pcts.length <= 1
                ? null
                : () => setState(() => _pcts.removeAt(i)),
          ),
        ],
      ),
    );
  }
}
