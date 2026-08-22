import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/localization/app_localizations.dart';
import '../../core/localization/enum_labels.dart';
import '../../core/theme/app_theme.dart';
import '../../core/utils/currency_formatter.dart';
import '../../models/session.dart';
import '../../models/player.dart';
import '../../models/transaction.dart';
import '../../providers/session_provider.dart';
import '../../services/player_history_service.dart';
import '../../services/table_service.dart';
import '../../services/session_service.dart';
import '../../widgets/signature_compare_sheet.dart';

/// One player's COMPLETE ledger for this session: every buy-in, rebuy,
/// cash-out, edit, signature and note, in chronological order.
///
/// This is the page a banker opens during a dispute, so it deliberately
/// shows everything rather than a tidy summary — including voided rows
/// (struck through, never hidden) and edit stamps. Read-only: it renders
/// transactions that already exist and cannot alter the ledger.
class PlayerLedgerScreen extends StatelessWidget {
  final Player player;
  const PlayerLedgerScreen({super.key, required this.player});

  @override
  Widget build(BuildContext context) {
    final provider = context.watch<SessionProvider>();
    final session = provider.current!;
    // Live read, so a rename or table move made elsewhere is reflected
    // here rather than showing the snapshot this screen was pushed with.
    final live = provider.livePlayer(player);
    final fmt = CurrencyFormatter(session.currency);

    // Voided rows are INCLUDED on purpose: "why is this player's total
    // different from what they remember" is usually answered by a voided
    // entry, so hiding them would defeat the point of this screen.
    final all = SessionService.transactionsFor(session.id, includeVoided: true)
        .where((t) => t.playerId == live.id)
        .toList()
      ..sort((a, b) => a.timestamp.compareTo(b.timestamp));

    final buyIn = SessionService.playerBuyInOnly(session.id, live.id);
    final rebuy = SessionService.playerRebuyOnly(session.id, live.id);
    final out = SessionService.playerTotalCashOut(session.id, live.id);
    final net = SessionService.playerProfitLoss(session.id, live.id);
    final rake = SessionService.playerRakeTotal(session.id, live.id);
    // Cross-session career, so the banker sees this player's whole
    // record without leaving the page.
    final career = PlayerHistoryService.careerFor(live);
    final tableNameFor = _tableNamer(session);

    return Scaffold(
      appBar: AppBar(
        title: Text('${live.name} · ${tr('complete_ledger')}'),
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
        children: [
          _summary(fmt, buyIn, rebuy, out, net, rake),
          const SizedBox(height: 12),
          _careerCard(career, fmt),
          const SizedBox(height: 18),
          Row(
            children: [
              Container(width: 3, height: 13, color: AppColors.gold),
              const SizedBox(width: 9),
              Expanded(
                child: Text(
                  tr('every_action').toUpperCase(),
                  style: const TextStyle(
                    fontSize: 10.5,
                    fontWeight: FontWeight.bold,
                    letterSpacing: 1.1,
                    color: AppColors.textSecondary,
                  ),
                ),
              ),
              Text('${all.length}',
                  style: const TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.bold,
                      color: AppColors.gold)),
            ],
          ),
          const SizedBox(height: 12),
          if (all.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 28),
              child: Center(
                child: Text(tr('no_transactions_yet'),
                    style: const TextStyle(color: AppColors.textSecondary)),
              ),
            )
          else
            for (var i = 0; i < all.length; i++)
              _entry(context, all[i], fmt, live,
                  first: i == 0,
                  last: i == all.length - 1,
                  tableName: tableNameFor(all[i])),
        ],
      ),
    );
  }

  Widget _summary(CurrencyFormatter fmt, double buyIn, double rebuy,
      double out, double net, double rake) {
    final up = net >= 0;
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        gradient: AppColors.heroGradient,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppColors.divider),
      ),
      child: Column(
        children: [
          Row(
            children: [
              _cell(tr('buy_in'), fmt.format(buyIn)),
              _cell(tr('rebuy'), fmt.format(rebuy)),
              _cell(tr('cash_out'), fmt.format(out)),
            ],
          ),
          if (rake > 0) ...[
            const SizedBox(height: 10),
            Row(
              children: [
                const Icon(Icons.percent, size: 13, color: AppColors.gold),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(tr('rake_from_their_pots'),
                      style: const TextStyle(
                          fontSize: 11, color: AppColors.textSecondary)),
                ),
                Text(fmt.format(rake),
                    style: const TextStyle(
                        fontSize: 12.5,
                        fontWeight: FontWeight.bold,
                        color: AppColors.gold)),
              ],
            ),
            const SizedBox(height: 2),
            Text(
              tr('rake_not_in_pl'),
              style: TextStyle(
                  fontSize: 9.5,
                  color: AppColors.textSecondary.withValues(alpha: 0.85)),
            ),
          ],
          const Divider(height: 20),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(tr('lifetime_pl').replaceAll(' / LOSS', ''),
                  style: const TextStyle(
                      fontSize: 10.5, color: AppColors.textSecondary)),
              Text(
                '${up ? '+' : ''}${fmt.format(net)}',
                style: TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.bold,
                  color: up ? AppColors.accentGreen : AppColors.danger,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  /// Human-readable table name for a transaction, or null on a
  /// single-table session where the column would be noise.
  static String? Function(LedgerTransaction) _tableNamer(PokerSession s) {
    if (!TableService.isMultiTable(s)) return (_) => null;
    final tables = TableService.tablesFor(s);
    final firstId = tables.first.id;
    return (tx) {
      final id = tx.tableId ?? firstId;
      return tables
          .firstWhere((t) => t.id == id, orElse: () => tables.first)
          .name;
    };
  }

  /// Cross-session career summary: sessions played, lifetime result,
  /// win rate and average buy-in.
  Widget _careerCard(PlayerCareer career, CurrencyFormatter fmt) {
    final mixed = !career.hasConsistentCurrency;
    final cf = mixed ? null : CurrencyFormatter(career.currency);
    String money(double v) => cf == null ? '—' : cf.format(v);
    final win = career.winRate;

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
          Row(
            children: [
              const Icon(Icons.history, size: 14, color: AppColors.gold),
              const SizedBox(width: 7),
              Text(tr('across_all_sessions').toUpperCase(),
                  style: const TextStyle(
                      fontSize: 9.5,
                      letterSpacing: 1.1,
                      fontWeight: FontWeight.bold,
                      color: AppColors.textSecondary)),
            ],
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              _cell(tr('sessions'), '${career.sessionsPlayed}'),
              _cell(
                tr('profit_loss'),
                mixed
                    ? '—'
                    : '${career.netResult >= 0 ? '+' : ''}${money(career.netResult)}',
              ),
            ],
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              _cell(tr('win_rate'),
                  win == null ? '—' : '${win.toStringAsFixed(0)}%'),
              _cell(tr('average_buy_in'), money(career.averageBuyIn)),
            ],
          ),
        ],
      ),
    );
  }

  Widget _cell(String label, String value) => Expanded(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(label,
                style: const TextStyle(
                    fontSize: 10, color: AppColors.textSecondary)),
            const SizedBox(height: 3),
            FittedBox(
              fit: BoxFit.scaleDown,
              alignment: AlignmentDirectional.centerStart,
              child: Text(value,
                  style: const TextStyle(
                      fontSize: 14, fontWeight: FontWeight.bold)),
            ),
          ],
        ),
      );

  Widget _entry(BuildContext context, LedgerTransaction tx,
      CurrencyFormatter fmt, Player live,
      {required bool first, required bool last, String? tableName}) {
    final color = _colorFor(tx.type);
    final voided = tx.isVoided;
    final hasSig = tx.hostSignatureBase64 != null &&
        tx.hostSignatureBase64!.isNotEmpty;

    return IntrinsicHeight(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Timeline rail — makes the chronological order read at a glance.
          Column(
            children: [
              Container(
                width: 2,
                height: 8,
                color: first ? Colors.transparent : AppColors.divider,
              ),
              Container(
                width: 11,
                height: 11,
                decoration: BoxDecoration(
                  color: voided ? AppColors.divider : color,
                  shape: BoxShape.circle,
                  border: Border.all(color: AppColors.background, width: 2),
                ),
              ),
              Expanded(
                child: Container(
                  width: 2,
                  color: last ? Colors.transparent : AppColors.divider,
                ),
              ),
            ],
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Opacity(
              opacity: voided ? 0.55 : 1,
              child: Container(
                margin: const EdgeInsets.only(bottom: 10),
                padding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                decoration: BoxDecoration(
                  color: AppColors.surfaceElevated,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: AppColors.divider),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            tx.type.localizedLabel,
                            style: TextStyle(
                              fontWeight: FontWeight.bold,
                              fontSize: 13.5,
                              color: color,
                              decoration:
                                  voided ? TextDecoration.lineThrough : null,
                            ),
                          ),
                        ),
                        Text(
                          '${tx.type.isInflow ? '+' : '-'}${fmt.format(tx.amount)}',
                          style: TextStyle(
                            fontWeight: FontWeight.bold,
                            fontSize: 13.5,
                            color: color,
                            decoration:
                                voided ? TextDecoration.lineThrough : null,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 4),
                    Row(
                      children: [
                        Text(
                          tx.timestamp.toString().substring(0, 19),
                          style: const TextStyle(
                              fontSize: 11, color: AppColors.textSecondary),
                        ),
                        if (tableName != null) ...[
                          const SizedBox(width: 6),
                          Text('· $tableName',
                              style: const TextStyle(
                                  fontSize: 11,
                                  color: AppColors.textSecondary)),
                        ],
                      ],
                    ),
                    if (tx.note != null && tx.note!.trim().isNotEmpty) ...[
                      const SizedBox(height: 6),
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Icon(Icons.sticky_note_2_outlined,
                              size: 13, color: AppColors.textSecondary),
                          const SizedBox(width: 6),
                          Expanded(
                            child: Text(
                              tx.note!,
                              style: const TextStyle(
                                  fontSize: 11.5,
                                  fontStyle: FontStyle.italic,
                                  color: AppColors.textPrimary),
                            ),
                          ),
                        ],
                      ),
                    ],
                    const SizedBox(height: 8),
                    Wrap(
                      spacing: 6,
                      runSpacing: 6,
                      children: [
                        if (voided) _tag(tr('voided'), AppColors.danger),
                        if (tx.isEdited)
                          _tag(
                            tx.editedAt == null
                                ? tr('edited')
                                : '${tr('edited')} ${tx.editedAt.toString().substring(0, 16)}',
                            AppColors.warning,
                          ),
                        if (tx.signedWhileAbsent)
                          _tag('signed while away', AppColors.warning),
                        if (hasSig)
                          ActionChip(
                            visualDensity: VisualDensity.compact,
                            avatar: const Icon(Icons.draw_outlined,
                                size: 14, color: AppColors.gold),
                            label: Text(tr('verify_signature'),
                                style: const TextStyle(fontSize: 10.5)),
                            onPressed: () => showSignatureComparison(
                              context,
                              player: live,
                              transaction: tx,
                              formatter: fmt,
                            ),
                          )
                        else
                          _tag('no signature', AppColors.textSecondary),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _tag(String text, Color color) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(6),
          border: Border.all(color: color.withValues(alpha: 0.45)),
        ),
        child: Text(text,
            style: TextStyle(
                fontSize: 9.5, fontWeight: FontWeight.bold, color: color)),
      );

  static Color _colorFor(TransactionType type) {
    switch (type) {
      case TransactionType.buyIn:
      case TransactionType.rebuy:
        return AppColors.accentGreen;
      case TransactionType.cashOut:
        return AppColors.danger;
      case TransactionType.rakeCollection:
        return AppColors.gold;
      case TransactionType.cashDrop:
        return AppColors.textSecondary;
      // A table move is not a win or a loss for the player — it is the
      // same money in a different seat — so it is deliberately neutral
      // rather than green/red.
      case TransactionType.transferOut:
      case TransactionType.transferIn:
        return AppColors.textSecondary;
      case TransactionType.dealerTips:
        return AppColors.warning;
      // A table cash-out is money out of the table (the player carries
      // the chips — no cash changes hands).
      case TransactionType.tableCashOut:
        return AppColors.danger;
      // A re-entry is money INTO the table: the player's carried chips
      // are committed here (green, like a buy-in — without being one).
      case TransactionType.reentry:
        return AppColors.accentGreen;
      // A house win is money the player lost to the house at a
      // house-banked game — an outflow, like a cash-out.
      case TransactionType.houseWin:
        return AppColors.danger;
    }
  }
}
