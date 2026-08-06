import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../core/house_rules.dart';
import '../core/localization/app_localizations.dart';
import '../core/rake_calculator.dart';
import '../core/theme/app_theme.dart';
import '../core/utils/currency_formatter.dart';
import '../models/enums.dart';
import '../models/player.dart';
import '../providers/session_provider.dart';
import '../services/sound_service.dart';

/// Collect Rake, in both of the modes a banker actually works in.
///
/// MODE 1 — attributed rake ([player] supplied): taken from a specific
/// player's pot. It is recorded against that player so it appears in
/// their history, and still counts toward the session's total rake.
///
/// MODE 2 — general rake ([player] null): table-level house income with
/// no player ownership. Only the session total moves.
///
/// CRITICAL: attributing a rake to a player is a RECORD OF WHOSE POT IT
/// CAME FROM, not a charge against them. Rake never touches
/// `playerProfitLoss` (which counts buy-ins, rebuys and cash-outs only)
/// and never affects the settlement balance. Both modes write the same
/// `rakeCollection` type, so `SessionService.totalRake` picks both up
/// identically — the only difference is whether a playerId is attached.
Future<void> showQuickRakeSheet(
  BuildContext context, {
  Player? player,
}) async {
  final provider = context.read<SessionProvider>();
  final session = provider.current!;
  final fmt = CurrencyFormatter(session.currency);

  final potCtrl = TextEditingController();
  final rakeCtrl = TextEditingController();
  final needsPot = session.rakeMode != RakeMode.fixed;
  final quickAmounts =
      session.quickRakeAmounts ?? HouseRules.defaultQuickRakeAmounts;

  if (session.rakeMode == RakeMode.fixed) {
    rakeCtrl.text = (session.fixedRakeAmount ?? 0).toStringAsFixed(0);
  }

  final amount = await showModalBottomSheet<double>(
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
              Row(
                children: [
                  const Icon(Icons.percent, size: 18, color: AppColors.gold),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      '${tr('collect_rake')} (${session.rakeMode.label})',
                      style: const TextStyle(
                          fontSize: 17, fontWeight: FontWeight.bold),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 4),
              // Make the mode unmistakable before any money is recorded.
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
                decoration: BoxDecoration(
                  color: (player == null ? AppColors.textSecondary : AppColors.gold)
                      .withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(9),
                  border: Border.all(
                    color: (player == null
                            ? AppColors.textSecondary
                            : AppColors.gold)
                        .withValues(alpha: 0.5),
                  ),
                ),
                child: Row(
                  children: [
                    Icon(
                      player == null
                          ? Icons.table_bar_outlined
                          : Icons.person_outline,
                      size: 14,
                      color: player == null
                          ? AppColors.textSecondary
                          : AppColors.gold,
                    ),
                    const SizedBox(width: 7),
                    Expanded(
                      child: Text(
                        player == null
                            ? tr('rake_general_note')
                            : '${tr('rake_from_player')} ${player.name}',
                        style: TextStyle(
                          fontSize: 11.5,
                          color: player == null
                              ? AppColors.textSecondary
                              : AppColors.gold,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 14),
              if (quickAmounts.isEmpty)
                Text(tr('no_quick_rake_set'),
                    style: const TextStyle(
                        fontSize: 12, color: AppColors.textSecondary))
              else ...[
                Text(tr('one_tap'),
                    style: const TextStyle(
                        fontSize: 12, color: AppColors.textSecondary)),
                const SizedBox(height: 8),
                // The banker's own five slots, in the order they defined
                // them — positions never shuffle, so muscle memory works.
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: quickAmounts
                      .map((amt) => ActionChip(
                            // formatRaw: a quick-rake button whose amount
                            // is masked is unusable — you'd be tapping
                            // blind on money.
                            label: Text(fmt.formatRaw(amt),
                                style: const TextStyle(
                                    fontWeight: FontWeight.bold,
                                    color: AppColors.gold)),
                            backgroundColor: AppColors.gold.withValues(alpha: 0.12),
                            side:
                                BorderSide(color: AppColors.gold.withValues(alpha: 0.55)),
                            onPressed: () => Navigator.pop(ctx, amt),
                          ))
                      .toList(),
                ),
              ],
              const SizedBox(height: 16),
              const Divider(),
              const SizedBox(height: 8),
              Text(tr('or_custom_amount'),
                  style: const TextStyle(
                      fontSize: 12, color: AppColors.textSecondary)),
              const SizedBox(height: 8),
              if (needsPot) ...[
                TextField(
                  controller: potCtrl,
                  keyboardType: TextInputType.number,
                  decoration: InputDecoration(labelText: tr('pot_size')),
                  onChanged: (v) {
                    final pot = double.tryParse(v.replaceAll(',', ''));
                    if (pot != null) {
                      rakeCtrl.text = RakeCalculator.suggestForSession(
                              session, pot)
                          .toStringAsFixed(0);
                      setSheetState(() {});
                    }
                  },
                ),
                const SizedBox(height: 8),
              ],
              TextField(
                controller: rakeCtrl,
                keyboardType:
                    const TextInputType.numberWithOptions(decimal: true),
                decoration: InputDecoration(labelText: tr('rake_amount')),
              ),
              const SizedBox(height: 12),
              ElevatedButton(
                onPressed: () => Navigator.pop(
                    ctx, double.tryParse(rakeCtrl.text.replaceAll(',', ''))),
                child: Text(tr('confirm_custom_amount')),
              ),
            ],
          ),
        ),
      ),
    ),
  );

  if (amount == null || amount <= 0) return;

  // Sound fires on the confirmed write, not on the chip tap, so a
  // cancelled sheet never sounds like money was taken.
  await provider.recordTransaction(
    playerId: player?.id,
    type: TransactionType.rakeCollection,
    amount: amount,
    hostSignatureBase64: '',
  );
  AppSounds.play(SoundEffect.rake);
}
