import 'package:flutter/material.dart';
import '../../core/localization/app_localizations.dart';
import 'package:provider/provider.dart';
import '../../core/theme/app_theme.dart';
import '../../widgets/polish.dart';
import '../../core/utils/currency_formatter.dart';
import '../../models/enums.dart';
import '../../models/session.dart';
import '../../providers/session_provider.dart';
import '../../services/table_service.dart';
import '../../widgets/balance_check_banner.dart';
import '../../widgets/balance_indicator.dart';
import '../../widgets/confirm_action_dialog.dart';
import '../chip_bank/session_reconciliation_screen.dart';
import '../house_rules/house_rules_screen.dart';
import '../reports/reports_screen.dart';

/// Overview tab: where things stand right now, at a glance. Deliberately
/// compact — the banker's actual work happens on Players/Table/Actions,
/// so this stays a quick read, not a second scrolling screen to manage.
/// The full balance breakdown only gets a big banner at session close;
/// during live play it's a small tappable indicator.
class DashboardTab extends StatelessWidget {
  final VoidCallback onViewHistory;
  final VoidCallback onViewPlayers;
  final VoidCallback onViewTable;
  const DashboardTab({
    super.key,
    required this.onViewHistory,
    required this.onViewPlayers,
    required this.onViewTable,
  });

  String _formatDuration(Duration d) {
    String two(int n) => n.toString().padLeft(2, '0');
    return '${two(d.inHours)}:${two(d.inMinutes.remainder(60))}:${two(d.inSeconds.remainder(60))}';
  }

  Future<void> _endSessionFlow(BuildContext context, SessionProvider provider, CurrencyFormatter fmt) {
    final balance = provider.balance!;
    bool closing = false;
    return showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (ctx) => Padding(
        padding: const EdgeInsets.all(20),
        child: StatefulBuilder(
          builder: (ctx, setSheetState) {
            return Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(tr('end_session'), style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
                const SizedBox(height: 6),
                Text(
                  tr('verified_session_level'),
                  style: TextStyle(fontSize: 12, color: AppColors.textSecondary),
                ),
                const SizedBox(height: 16),
                BalanceCheckBanner(result: balance, formatter: fmt),
                const SizedBox(height: 12),
                // The money check above and the chip check here answer
                // two different questions: the banner proves the LEDGER
                // balances, this proves the PHYSICAL CHIPS do. A session
                // can settle perfectly on paper while chips are missing
                // from the case, so the banker is offered the count
                // before closing rather than after.
                OutlinedButton.icon(
                  onPressed: () => Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (_) => SessionReconciliationScreen(
                        sessionId: provider.current!.id,
                        currency: provider.current!.currency,
                      ),
                    ),
                  ),
                  icon: const Icon(Icons.fact_check_outlined, size: 18),
                  label: Text(tr('reconcile_chips_before_closing')),
                ),
                const SizedBox(height: 16),
                ElevatedButton(
                  onPressed: closing
                      ? null
                      : () async {
                          final confirmed = await confirmSensitiveAction(
                            ctx,
                            title: 'End Session',
                            message: 'This closes the session for further transactions. Continue?',
                          );
                          if (!confirmed) return;
                          setSheetState(() => closing = true);
                          await provider.endSession();
                          if (context.mounted) {
                            Navigator.pop(ctx);
                            Navigator.of(context).push(
                              MaterialPageRoute(
                                  builder: (_) => ReportsScreen(sessionId: provider.current!.id)),
                            );
                          }
                        },
                  child: closing
                      ? const SizedBox(
                          height: 20, width: 20, child: CircularProgressIndicator(strokeWidth: 2))
                      : Text(tr('confirm_close_session')),
                ),
                const SizedBox(height: 8),
                OutlinedButton(onPressed: () => Navigator.pop(ctx), child: Text(tr('go_back_fix'))),
              ],
            );
          },
        ),
      ),
    );
  }

  /// Simple cash-game timer setup: pick a length, or clear it. This is
  /// NOT the tournament blind timer — it only counts down and warns.
  Future<void> _pickDuration(
      BuildContext context, SessionProvider provider, PokerSession session) {
    const options = [60, 90, 120, 180, 240];
    return showModalBottomSheet(
      context: context,
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(18, 18, 18, 20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(tr('session_duration'),
                  style: const TextStyle(
                      fontSize: 17, fontWeight: FontWeight.bold)),
              const SizedBox(height: 4),
              Text(
                tr('timer_hint'),
                style: TextStyle(
                    fontSize: 11,
                    color: AppColors.textSecondary.withValues(alpha: 0.9)),
              ),
              const SizedBox(height: 16),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final m in options)
                    ChoiceChip(
                      label: Text('$m ${tr('minutes')}'),
                      selected: session.plannedMinutes == m,
                      onSelected: (_) {
                        provider.setPlannedMinutes(m);
                        Navigator.pop(ctx);
                      },
                    ),
                  ChoiceChip(
                    label: Text(tr('no_limit')),
                    selected: !session.hasTimer,
                    onSelected: (_) {
                      provider.setPlannedMinutes(null);
                      Navigator.pop(ctx);
                    },
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _miniStat(String label, String value, {Color? color}) {
    return Expanded(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: const TextStyle(fontSize: 10.5, color: AppColors.textSecondary)),
          const SizedBox(height: 3),
          FittedBox(
            fit: BoxFit.scaleDown,
            alignment: Alignment.centerLeft,
            // Animated so a freshly recorded buy-in visibly moves the
            // total, confirming the tap registered.
            child: AnimatedMoney(
              value: value,
              style: TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.bold,
                  color: color ?? AppColors.textPrimary),
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final provider = context.watch<SessionProvider>();
    final session = provider.current!;
    final fmt = CurrencyFormatter(session.currency);
    final onBreak = session.status == SessionStatus.onBreak;
    final isEnded = session.status == SessionStatus.ended;
    final balance = provider.balance!;

    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            gradient: const LinearGradient(
              colors: [AppColors.feltGreen, AppColors.surface],
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
            ),
            borderRadius: BorderRadius.circular(16),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  AnimatedSwitcher(
                    duration: const Duration(milliseconds: 250),
                    child: _StatusChip(key: ValueKey(session.status), status: session.status),
                  ),
                  Row(
                    children: [
                      Text('Level ${session.currentLevel}',
                          style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13)),
                      const SizedBox(width: 8),
                      InkWell(
                        onTap: () => Navigator.of(context)
                            .push(MaterialPageRoute(builder: (_) => const HouseRulesScreen())),
                        child: const Icon(Icons.gavel_outlined, size: 17, color: AppColors.textSecondary),
                      ),
                    ],
                  ),
                ],
              ),
              const SizedBox(height: 10),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(onBreak ? 'ON BREAK' : 'SESSION TIME',
                          style: const TextStyle(fontSize: 11, color: AppColors.textSecondary)),
                      Text(_formatDuration(session.elapsed),
                          style: const TextStyle(fontSize: 24, fontWeight: FontWeight.bold)),
                      // Simple cash-game countdown, only when the banker
                      // has opted into a planned length.
                      if (session.hasTimer) ...[
                        const SizedBox(height: 4),
                        Builder(builder: (_) {
                          final left = session.timeRemaining!;
                          final low = left <= const Duration(minutes: 10);
                          final done = left == Duration.zero;
                          return Row(
                            children: [
                              Icon(
                                done
                                    ? Icons.timer_off_outlined
                                    : Icons.timer_outlined,
                                size: 13,
                                color: done
                                    ? AppColors.danger
                                    : (low
                                        ? AppColors.warning
                                        : AppColors.textSecondary),
                              ),
                              const SizedBox(width: 5),
                              Text(
                                done
                                    ? tr('session_finished')
                                    : '${tr('time_remaining')}  ${_formatDuration(left)}',
                                style: TextStyle(
                                  fontSize: 11.5,
                                  fontWeight: FontWeight.bold,
                                  color: done
                                      ? AppColors.danger
                                      : (low
                                          ? AppColors.warning
                                          : AppColors.textSecondary),
                                ),
                              ),
                            ],
                          );
                        }),
                      ],
                    ],
                  ),
                  Row(
                    children: [
                      IconButton.filledTonal(
                        onPressed: isEnded
                            ? null
                            : () => onBreak ? provider.endBreak() : provider.startBreak(),
                        icon: Icon(onBreak ? Icons.play_arrow : Icons.pause, size: 20),
                        style: IconButton.styleFrom(
                          backgroundColor: isEnded
                              ? AppColors.divider
                              : (onBreak ? AppColors.accentGreen : AppColors.warning)
                                  .withValues(alpha: 0.85),
                        ),
                      ),
                      const SizedBox(width: 6),
                      IconButton.filledTonal(
                        onPressed: isEnded ? null : provider.advanceLevel,
                        icon: const Icon(Icons.arrow_upward, size: 18),
                        tooltip: tr('next_level'),
                      ),
                      const SizedBox(width: 6),
                      IconButton.filledTonal(
                        onPressed: isEnded
                            ? null
                            : () => _pickDuration(context, provider, session),
                        icon: Icon(
                          session.hasTimer
                              ? Icons.timer_outlined
                              : Icons.timer_off_outlined,
                          size: 18,
                        ),
                        tooltip: tr('session_timer'),
                      ),
                    ],
                  ),
                ],
              ),
            ],
          ),
        ),
        const SizedBox(height: 12),

        // Quick jump — the banker's actual work lives here, dashboard is
        // just the glance.
        Row(
          children: [
            Expanded(
              child: OutlinedButton.icon(
                onPressed: onViewPlayers,
                icon: const Icon(Icons.people_outline, size: 17),
                label: Text(tr('players')),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: OutlinedButton.icon(
                onPressed: onViewTable,
                icon: const Icon(Icons.table_restaurant_outlined, size: 17),
                label: Text(tr('table')),
              ),
            ),
          ],
        ),
        const SizedBox(height: 14),

        // Compact settlement snapshot — small chips, not full-size cards.
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          decoration: BoxDecoration(
            color: AppColors.surfaceElevated,
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: AppColors.divider),
          ),
          child: Column(
            children: [
              Row(
                children: [
                  _miniStat('Money In', fmt.format(balance.moneyIn)),
                  _miniStat('Money Out', fmt.format(balance.moneyOut)),
                  _miniStat('Current Pot', fmt.format(provider.moneyStillInPlay)),
                ],
              ),
              const SizedBox(height: 4),
              Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  "Current Pot is what's still on the table — it's the same figure "
                  'the balance check below watches, and should reach zero once '
                  'everyone has cashed out.',
                  style: TextStyle(fontSize: 9.5, color: AppColors.textSecondary.withValues(alpha: 0.8)),
                ),
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  _miniStat('Rake', fmt.format(provider.totalRake), color: AppColors.gold),
                  _miniStat('Host Profit', fmt.format(provider.hostProfit),
                      color: AppColors.accentGreen),
                  Expanded(
                    child: Align(
                      alignment: Alignment.centerRight,
                      child: BalanceIndicator(result: balance, formatter: fmt),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
        // Per-table financial breakdown — one card per table, in the same
        // visual language as the session summary above.
        //
        // Shown for EVERY session, including single-table ones: a banker
        // running one table still wants that table's takings stated
        // explicitly rather than having to infer that it equals the
        // session total.
        //
        // These are informational splits of the same money. The balance
        // check stays session-level, because the host settles one bank at
        // the end of the night, not one per table.
        if (provider.tableSummaries.isNotEmpty) ...[
          const SizedBox(height: 14),
          Row(
            children: [
              Text(tr('tables_upper'),
                  style: TextStyle(
                      fontSize: 10,
                      letterSpacing: 1.1,
                      fontWeight: FontWeight.bold,
                      color: AppColors.textSecondary)),
              const SizedBox(width: 8),
              Expanded(
                child: Divider(
                    color: AppColors.divider.withValues(alpha: 0.6)),
              ),
            ],
          ),
          const SizedBox(height: 8),
          ...provider.tableSummaries.map(
            (t) => Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: _TableFinancialCard(summary: t, fmt: fmt),
            ),
          ),
          Text(
            tr('per_table_note'),
            style: TextStyle(
                fontSize: 9.5,
                color: AppColors.textSecondary.withValues(alpha: 0.85)),
          ),
        ],
        if (provider.totalCashDrop > 0) ...[
          const SizedBox(height: 6),
          Text('Cash dropped to safe so far: ${fmt.format(provider.totalCashDrop)}',
              style: const TextStyle(fontSize: 11, color: AppColors.textSecondary)),
        ],
        const SizedBox(height: 10),
        TextButton(onPressed: onViewHistory, child: Text(tr('view_full_timeline'))),
        const SizedBox(height: 6),
        if (isEnded)
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(vertical: 12),
            decoration: BoxDecoration(
              color: AppColors.divider.withValues(alpha: 0.3),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: AppColors.divider),
            ),
            child: Center(
              child: Text(tr('session_ended_readonly'),
                  style: TextStyle(color: AppColors.textSecondary, fontWeight: FontWeight.bold)),
            ),
          )
        else
          OutlinedButton.icon(
            onPressed: () => _endSessionFlow(context, provider, fmt),
            icon: const Icon(Icons.flag_outlined, color: AppColors.danger, size: 18),
            label: Text(tr('end_session'), style: TextStyle(color: AppColors.danger)),
            style: OutlinedButton.styleFrom(side: const BorderSide(color: AppColors.danger)),
          ),
        const SizedBox(height: 24),
      ],
    );
  }
}

/// One table's financial summary, in the same shape as the session
/// header above it: Money In / Money Out / Current Pot on the first row,
/// Rake and Host Profit on the second.
///
/// EVERY FIGURE HERE IS TRANSACTION-DERIVED. [TableSummary] folds the
/// amounts of transactions whose `tableId` is this table (plus legacy
/// null-tableId rows for the first table). It deliberately does NOT use
/// the player-derived `moneyInPlay`, because a player who moves tables
/// would otherwise drag their whole buy-in history to the new table and
/// misstate both tables' takings.
///
/// Display only. No settlement rule reads any of it, and the session
/// totals above are computed independently and remain authoritative.
class _TableFinancialCard extends StatelessWidget {
  final TableSummary summary;
  final CurrencyFormatter fmt;

  const _TableFinancialCard({required this.summary, required this.fmt});

  @override
  Widget build(BuildContext context) {
    final t = summary.table;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: AppColors.surfaceElevated,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AppColors.divider),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Header: name, seated count, status.
          Row(
            children: [
              Expanded(
                child: Text(
                  t.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                      fontSize: 13, fontWeight: FontWeight.bold),
                ),
              ),
              if (!t.status.isActive) ...[
                Container(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 6, vertical: 2),
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(6),
                    border: Border.all(
                      color: t.status.isClosed
                          ? AppColors.danger
                          : AppColors.warning,
                    ),
                  ),
                  child: Text(
                    t.status.isClosed ? 'CLOSED' : 'PAUSED',
                    style: TextStyle(
                      fontSize: 8.5,
                      fontWeight: FontWeight.bold,
                      letterSpacing: 0.8,
                      color: t.status.isClosed
                          ? AppColors.danger
                          : AppColors.warning,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
              ],
              Text(
                '${summary.playerCount}/${t.seatCount} seated',
                style: const TextStyle(
                    fontSize: 11, color: AppColors.textSecondary),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              _cell('Money In', fmt.format(summary.moneyIn)),
              _cell('Money Out', fmt.format(summary.moneyOut)),
              // A CLOSED table no longer holds a pool of money, so it has
              // no Current Pot to state. Showing the arithmetic here
              // would be actively misleading: a settled table that took
              // rake computes a negative figure, which reads as though
              // the house owes the table money.
              //
              // Display only — the underlying Money In, Money Out and
              // Rake transactions are untouched and still reconcile as
              // Money In = Money Out + Rake.
              _cell(
                'Current Pot',
                t.status.isClosed ? '—' : fmt.format(summary.currentPot),
                color: t.status.isClosed ? AppColors.textSecondary : null,
              ),
            ],
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              _cell('Rake', fmt.format(summary.rake), color: AppColors.gold),
              _cell('Host Profit', fmt.format(summary.hostProfit),
                  color: AppColors.accentGreen),
              // Third slot keeps the two rows on the same grid so the
              // columns line up with the session summary above.
              summary.cashDrop > 0
                  ? _cell('Cash Drop', fmt.format(summary.cashDrop),
                      color: AppColors.textSecondary)
                  : const Expanded(child: SizedBox.shrink()),
            ],
          ),
        ],
      ),
    );
  }

  /// Mirrors the session summary's `_miniStat` so the two blocks read as
  /// one family. Kept local rather than shared because the session
  /// version animates its value; a per-table figure changing under the
  /// banker's eye would be noise, not confirmation.
  Widget _cell(String label, String value, {Color? color}) {
    return Expanded(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label,
              style: const TextStyle(
                  fontSize: 10, color: AppColors.textSecondary)),
          const SizedBox(height: 3),
          FittedBox(
            fit: BoxFit.scaleDown,
            alignment: Alignment.centerLeft,
            child: Text(
              value,
              style: TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.bold,
                color: color ?? AppColors.textPrimary,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _StatusChip extends StatelessWidget {
  final SessionStatus status;
  const _StatusChip({super.key, required this.status});

  @override
  Widget build(BuildContext context) {
    late final String label;
    late final Color color;
    switch (status) {
      case SessionStatus.active:
        label = 'ACTIVE';
        color = AppColors.accentGreen;
        break;
      case SessionStatus.onBreak:
        label = 'ON BREAK';
        color = AppColors.warning;
        break;
      case SessionStatus.ended:
        label = 'ENDED';
        color = AppColors.textSecondary;
        break;
    }
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: color),
      ),
      child: Text(label, style: TextStyle(color: color, fontSize: 11, fontWeight: FontWeight.bold)),
    );
  }
}
