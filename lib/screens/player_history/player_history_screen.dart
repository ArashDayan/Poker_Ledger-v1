import 'package:flutter/material.dart';
import '../../core/localization/app_localizations.dart';

import '../../core/theme/app_theme.dart';
import '../../core/utils/currency_formatter.dart';
import '../../services/player_history_service.dart';
import '../../services/player_identity_service.dart';
import '../../services/player_registry_service.dart';
import '../../services/session_settlement_view.dart';
import '../../widgets/player_type_badge.dart';
import '../player_account/player_account_screen.dart';
import '../reports/reports_screen.dart';
import '../shell/open_floor_session.dart';
import '../../models/enums.dart';

/// One player's complete record across every session the host has run.
///
/// Read-only: this screen never writes to the ledger. It aggregates
/// transactions that already exist, so it cannot affect settlement.
class PlayerHistoryScreen extends StatelessWidget {
  /// Display name. Used only when [personId] is missing (legacy seats).
  final String playerName;

  /// Permanent identity. When set, session history and the Financial
  /// Account are this person only.
  final String? personId;

  const PlayerHistoryScreen({
    super.key,
    required this.playerName,
    this.personId,
  });

  @override
  Widget build(BuildContext context) {
    final career = (personId != null && personId!.isNotEmpty)
        ? PlayerHistoryService.careerForPersonId(personId!,
            fallbackName: playerName)
        : PlayerHistoryService.careerForName(playerName);
    final fmt = CurrencyFormatter(career.currency);
    final mixed = !career.hasConsistentCurrency;

    return Scaffold(
      appBar: AppBar(title: Text(career.name)),
      body: career.records.isEmpty
          ? ListView(
              padding: const EdgeInsets.fromLTRB(16, 24, 16, 32),
              children: [
                Text(tr('no_player_sessions'),
                    textAlign: TextAlign.center,
                    style: const TextStyle(color: AppColors.textSecondary)),
                const SizedBox(height: 16),
                _financialAccountEntry(context),
              ],
            )
          : ListView(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
              children: [
                _headline(career, fmt, mixed),
                if (career.isLegacyNameGroup) ...[
                  const SizedBox(height: 10),
                  Text(tr('identity_legacy_history_note'),
                      style: const TextStyle(
                          fontSize: 12,
                          color: AppColors.textSecondary,
                          height: 1.35)),
                ],
                const SizedBox(height: 12),
                _financialAccountEntry(context),
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

  Widget _financialAccountEntry(BuildContext context) {
    final linkedId = personId;
    if (linkedId != null && linkedId.isNotEmpty) {
      final identity = PlayerIdentityService.byId(linkedId);
      return ListTile(
        contentPadding: const EdgeInsets.symmetric(horizontal: 12),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          side: const BorderSide(color: AppColors.divider),
        ),
        tileColor: AppColors.surfaceElevated,
        leading: const Icon(Icons.account_balance_wallet_outlined,
            color: AppColors.gold),
        title: Text(tr('view_financial_account')),
        subtitle: Text(
          identity?.displayName ?? playerName,
          style: const TextStyle(fontSize: 11),
        ),
        trailing: const Icon(Icons.chevron_right, color: AppColors.textSecondary),
        onTap: () => Navigator.of(context).push(MaterialPageRoute(
          builder: (_) => PlayerAccountScreen(
            personId: linkedId,
            displayName: identity?.displayName ?? playerName,
          ),
        )),
      );
    }

    // Unlinked / legacy seats stay unlinked. A name match is not a
    // personId — opening an account here would silently pick an identity.
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppColors.surfaceElevated,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.divider),
      ),
      child: Text(tr('not_recorded_no_identity'),
          style: const TextStyle(
              fontSize: 12, color: AppColors.textSecondary, height: 1.35)),
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
            final tag = PlayerRegistryService.tagForPersonId(c.personId, c.name);
            final blacklisted =
                PlayerRegistryService.statusForPersonId(c.personId, c.name)
                    .isBlacklisted;
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

    var tableOut = 0.0, sessionOut = 0.0, cage = 0.0, reentry = 0.0;
    for (final r in c.records) {
      final row = PlayerSettlementRow.load(
          r.session.id, r.session.currency, r.player);
      tableOut += row.tableCashOut;
      sessionOut += row.sessionCashOut;
      cage += row.cageCashOut;
      reentry += row.reentry;
    }

    final tiles = <List<String>>[
      [tr('report_purchases'), money(c.totalIn)],
      [tr('report_reentry'), money(reentry)],
      [tr('report_table_cash_outs'), money(tableOut)],
      [tr('report_session_cash_out'), money(sessionOut)],
      [tr('report_cage_cash'), money(cage)],
      [tr('average_buy_in'), money(c.averageBuyIn)],
      [
        tr('profit_loss'),
        c.averageResult == null ? '—' : money(c.averageResult!)
      ],
      [tr('sessions_played'), '${c.completedSessions}/${c.sessionsPlayed}'],
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
          onTap: () {
            // ICR-02: a live session opens on the Floor; ended nights
            // keep the report/review path.
            if (ended) {
              Navigator.of(context).push(
                MaterialPageRoute(
                    builder: (_) => ReportsScreen(sessionId: r.session.id)),
              );
              return;
            }
            openFloorSession(context, r.session);
          },
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
                        () {
                          final split = PlayerSettlementRow.load(
                              r.session.id, r.session.currency, r.player);
                          return '${tr('report_purchases')} ${fmt.format(r.totalIn)}'
                              ' · ${tr('report_table_cash_outs')} ${fmt.format(split.tableCashOut)}'
                              ' · ${tr('report_session_cash_out')} ${fmt.format(split.sessionCashOut)}'
                              '${split.cageCashOut > 0 ? ' · ${tr('report_cage_cash')} ${fmt.format(split.cageCashOut)}' : ''}'
                              '${r.rebuyCount > 0 ? ' · ${r.rebuyCount} ${tr('rebuy')}' : ''}';
                        }(),
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
                          : tr('in_play'),
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
                      ended ? tr('ended') : tr('live'),
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
