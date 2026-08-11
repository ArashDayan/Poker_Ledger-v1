import 'package:flutter/material.dart';
import '../../core/localization/app_localizations.dart';

import '../../core/theme/app_theme.dart';
import '../../core/utils/currency_formatter.dart';
import '../../services/player_history_service.dart';
import '../../services/player_registry_service.dart';
import '../../widgets/player_type_badge.dart';
import '../reports/reports_screen.dart';
import '../session_shell/session_shell_screen.dart';
import '../../models/enums.dart';

/// One player's complete record across every session the host has run.
///
/// Read-only: this screen never writes to the ledger. It aggregates
/// transactions that already exist, so it cannot affect settlement.
class PlayerHistoryScreen extends StatelessWidget {
  /// The player's name — careers are grouped by name, since a Player row
  /// belongs to a single session (see PlayerHistoryService).
  final String playerName;

  const PlayerHistoryScreen({super.key, required this.playerName});

  @override
  Widget build(BuildContext context) {
    final career = PlayerHistoryService.careerForName(playerName);
    final fmt = CurrencyFormatter(career.currency);
    final mixed = !career.hasConsistentCurrency;

    return Scaffold(
      appBar: AppBar(title: Text(career.name)),
      body: career.records.isEmpty
          ? Center(
              child: Padding(
                padding: EdgeInsets.all(24),
                child: Text(tr('no_player_sessions'),
                    textAlign: TextAlign.center,
                    style: TextStyle(color: AppColors.textSecondary)),
              ),
            )
          : ListView(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
              children: [
                _headline(career, fmt, mixed),
                const SizedBox(height: 14),
                _statsGrid(career, fmt, mixed),
                if (mixed) ...[
                  const SizedBox(height: 10),
                  _mixedCurrencyNotice(),
                ],
                const SizedBox(height: 22),
                Row(
                  children: [
                    Container(width: 3, height: 13, color: AppColors.gold),
                    const SizedBox(width: 9),
                    Text(
                      'RECENT SESSIONS (${career.sessionsPlayed})',
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
                ...career.recentSessions.map((r) => _sessionRow(context, r)),
              ],
            ),
    );
  }

  Widget _headline(PlayerCareer c, CurrencyFormatter fmt, bool mixed) {
    final net = c.netResult;
    final up = net >= 0;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        gradient: AppColors.heroGradient,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppColors.divider),
      ),
      child: Column(
        children: [
          // Classification and access status, stated before the numbers
          // so the banker sees WHO this is before HOW MUCH they are worth.
          Builder(builder: (_) {
            final tag = PlayerRegistryService.tagForName(c.name);
            final blacklisted =
                PlayerRegistryService.isBlacklistedName(c.name);
            if (tag == null && !blacklisted) return const SizedBox.shrink();
            return Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: Wrap(
                alignment: WrapAlignment.center,
                spacing: 6,
                runSpacing: 6,
                children: [
                  if (tag != null) PlayerTypeBadge(tag: tag, scale: 1.25),
                  if (blacklisted) const BlacklistBadge(scale: 1.25),
                ],
              ),
            );
          }),
          Text(
            '${c.sessionsPlayed} session${c.sessionsPlayed == 1 ? '' : 's'} played',
            style: const TextStyle(fontSize: 12, color: AppColors.textSecondary),
          ),
          const SizedBox(height: 8),
          Text(tr('lifetime_pl'),
              style: TextStyle(
                  fontSize: 10,
                  letterSpacing: 1.1,
                  color: AppColors.textSecondary)),
          const SizedBox(height: 4),
          FittedBox(
            fit: BoxFit.scaleDown,
            child: Text(
              mixed ? '—' : '${up ? '+' : ''}${fmt.format(net)}',
              style: TextStyle(
                fontSize: 30,
                fontWeight: FontWeight.bold,
                color: mixed
                    ? AppColors.textSecondary
                    : (up ? AppColors.accentGreen : AppColors.danger),
              ),
            ),
          ),
          if (c.completedSessions > 0 && !mixed) ...[
            const SizedBox(height: 8),
            Text(
              '${c.sessionsWon}W · ${c.sessionsLost}L'
              '${c.sessionsBreakEven > 0 ? ' · ${c.sessionsBreakEven}E' : ''}'
              '${c.winRate != null ? '   (${c.winRate!.toStringAsFixed(0)}% win rate)' : ''}',
              style: const TextStyle(fontSize: 11.5, color: AppColors.textSecondary),
            ),
          ],
        ],
      ),
    );
  }

  Widget _statsGrid(PlayerCareer c, CurrencyFormatter fmt, bool mixed) {
    String money(double v) => mixed ? '—' : fmt.format(v);

    final tiles = <List<String>>[
      ['Total Buy-in', money(c.totalBuyIn)],
      ['Total Rebuy', money(c.totalRebuy)],
      ['Total Cash-out', money(c.totalCashOut)],
      ['Total In', money(c.totalIn)],
      ['Average Buy-in', money(c.averageBuyIn)],
      [
        'Average Result',
        c.averageResult == null ? '—' : money(c.averageResult!)
      ],
      ['Rebuys Taken', '${c.totalRebuys}'],
      ['Sessions Settled', '${c.completedSessions}/${c.sessionsPlayed}'],
    ];

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: AppColors.surfaceElevated,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AppColors.divider),
      ),
      child: Column(
        children: [
          for (var i = 0; i < tiles.length; i += 2)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 6),
              child: Row(
                children: [
                  _stat(tiles[i][0], tiles[i][1]),
                  if (i + 1 < tiles.length)
                    _stat(tiles[i + 1][0], tiles[i + 1][1])
                  else
                    const Spacer(),
                ],
              ),
            ),
          const Divider(height: 18),
          Row(
            children: [
              _stat(
                'First Played',
                c.firstPlayed == null
                    ? '—'
                    : c.firstPlayed.toString().substring(0, 10),
              ),
              _stat(
                'Last Played',
                c.lastPlayed == null
                    ? '—'
                    : c.lastPlayed.toString().substring(0, 10),
              ),
            ],
          ),
          if (!mixed && (c.biggestWin != null || c.biggestLoss != null)) ...[
            const Divider(height: 18),
            Row(
              children: [
                _stat(
                  'Biggest Win',
                  c.biggestWin == null
                      ? '—'
                      : '+${fmt.format(c.biggestWin!.profitLoss)}',
                  color: AppColors.accentGreen,
                ),
                _stat(
                  'Biggest Loss',
                  c.biggestLoss == null
                      ? '—'
                      : fmt.format(c.biggestLoss!.profitLoss),
                  color: AppColors.danger,
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }

  Widget _stat(String label, String value, {Color? color}) {
    return Expanded(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label,
              style: const TextStyle(fontSize: 10.5, color: AppColors.textSecondary)),
          const SizedBox(height: 3),
          FittedBox(
            fit: BoxFit.scaleDown,
            alignment: AlignmentDirectional.centerStart,
            child: Text(value,
                style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.bold,
                    color: color ?? AppColors.textPrimary)),
          ),
        ],
      ),
    );
  }

  Widget _mixedCurrencyNotice() {
    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: AppColors.warning.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: AppColors.warning.withValues(alpha: 0.5)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.info_outline, size: 15, color: AppColors.warning),
          SizedBox(width: 8),
          Expanded(
            child: Text(
              tr('mixed_currency_note'),
              style: TextStyle(fontSize: 11, color: AppColors.textPrimary),
            ),
          ),
        ],
      ),
    );
  }

  Widget _sessionRow(BuildContext context, PlayerSessionRecord r) {
    final fmt = CurrencyFormatter(r.session.currency);
    final up = r.profitLoss >= 0;
    final ended = r.session.status == SessionStatus.ended;

    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Material(
        color: AppColors.surfaceElevated,
        borderRadius: BorderRadius.circular(14),
        child: InkWell(
          borderRadius: BorderRadius.circular(14),
          onTap: () => Navigator.of(context).push(
            MaterialPageRoute(
              builder: (_) => ended
                  ? ReportsScreen(sessionId: r.session.id)
                  : SessionShellScreen(sessionId: r.session.id),
            ),
          ),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 12),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: AppColors.divider),
            ),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(r.session.name,
                          style: const TextStyle(
                              fontWeight: FontWeight.bold, fontSize: 13.5),
                          overflow: TextOverflow.ellipsis),
                      const SizedBox(height: 3),
                      Text(
                        '${r.date.toString().substring(0, 16)} · Seat ${r.player.seatNumber}',
                        style: const TextStyle(
                            fontSize: 11, color: AppColors.textSecondary),
                      ),
                      const SizedBox(height: 3),
                      Text(
                        'In ${fmt.format(r.totalIn)} · Out ${fmt.format(r.cashOut)}'
                        '${r.rebuyCount > 0 ? ' · ${r.rebuyCount} rebuy${r.rebuyCount == 1 ? '' : 's'}' : ''}',
                        style: const TextStyle(
                            fontSize: 10.5, color: AppColors.textSecondary),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Text(
                      r.settled
                          ? '${up ? '+' : ''}${fmt.format(r.profitLoss)}'
                          : 'In play',
                      style: TextStyle(
                        fontWeight: FontWeight.bold,
                        fontSize: 13.5,
                        color: !r.settled
                            ? AppColors.warning
                            : (up ? AppColors.accentGreen : AppColors.danger),
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      ended ? 'Ended' : 'Live',
                      style: const TextStyle(
                          fontSize: 9, color: AppColors.textSecondary),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
