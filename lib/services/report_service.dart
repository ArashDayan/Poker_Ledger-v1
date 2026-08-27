import '../core/localization/app_localizations.dart';
import '../models/enums.dart';
import '../models/session.dart';
import 'financial_ledger_service.dart';
import 'hive_service.dart';
import 'player_history_service.dart';
import 'session_service.dart';
import 'tournament_service.dart';

/// One row of the banker's lifetime/monthly performance figures.
///
/// In-memory only. Does not change [SessionService] formulas.
class PeriodStats {
  /// English label. Consumed by the PDF/CSV export, which has no Persian
  /// font bundled, so it must stay English — see [localizedLabel] for the
  /// on-screen text.
  final String label;

  /// Localization key for [label], when one exists.
  ///
  /// Display-only: nothing in the aggregation reads this, and the export
  /// keeps using [label], so report figures and file output are
  /// unchanged.
  final String? labelKey;

  /// Month labels also carry the year, which is appended after the
  /// translated month name.
  final String labelSuffix;
  final DateTime from;
  final DateTime to;
  final int sessions;
  final int players;

  /// Purchases only: buy-in + rebuy. Never includes re-entry.
  /// Same value as [purchases]. Kept so existing callers compile.
  final double moneyIn;

  /// Session `cashOut` legs only. After Phase 7 a cage redemption
  /// writes none of these, so this is often 0. Not "cash returned to
  /// players". Same value as [sessionCashOut].
  final double cashedOut;

  /// Buy-in + rebuy. Re-entry is not a purchase.
  final double purchases;

  /// Carried chips committed back to a table. Not new money in.
  final double reentry;

  /// Session ledger `cashOut` legs only.
  final double sessionCashOut;

  /// Table cash-outs: chips left table play and stayed person-held.
  final double tableCashOut;

  /// Financial Ledger `cashOutForChips` — cage cash actually returned.
  final double cageCashOut;

  /// Financial Ledger `cashOutUnbacked` — cash paid that was not covered.
  final double cageCashOutUnbacked;

  /// Poker rake only. Never includes house-banked game wins.
  final double rake;

  /// House-banked game wins only. Never includes poker rake.
  final double houseWin;

  /// Host / banker profit: rake + house win for cash games (or the
  /// tournament house-fee definition). Not a synonym for rake.
  final double bankerProfit;

  const PeriodStats({
    required this.label,
    this.labelKey,
    this.labelSuffix = '',
    required this.from,
    required this.to,
    required this.sessions,
    required this.players,
    required this.moneyIn,
    required this.cashedOut,
    this.purchases = 0,
    this.reentry = 0,
    this.sessionCashOut = 0,
    this.tableCashOut = 0,
    this.cageCashOut = 0,
    this.cageCashOutUnbacked = 0,
    required this.rake,
    this.houseWin = 0,
    required this.bankerProfit,
  });

  /// The label as it should appear in the app's UI.
  String get localizedLabel => labelKey == null
      ? label
      : '${tr(labelKey!)}${labelSuffix.isEmpty ? '' : ' $labelSuffix'}';

  double get averagePerSession => sessions == 0 ? 0 : bankerProfit / sessions;
  double get averageBuyIn => players == 0 ? 0 : purchases / players;
}

/// A player's line in a cross-session performance report.
class PlayerPerformanceRow {
  final String name;

  /// Linked identity, when this row is person-scoped. Null for a
  /// leftover name-only group.
  final String? personId;
  final bool isLegacyNameGroup;
  final int sessions;

  /// Buy-in + rebuy. Re-entry is not included.
  final double purchases;
  final double totalIn;
  final double net;
  final int rebuys;
  final DateTime? lastPlayed;
  final double tableCashOut;
  final double cageCash;
  final double cageCashUnbacked;
  final double reentry;

  const PlayerPerformanceRow({
    required this.name,
    this.personId,
    this.isLegacyNameGroup = false,
    required this.sessions,
    required this.purchases,
    double? totalIn,
    required this.net,
    required this.rebuys,
    required this.lastPlayed,
    this.tableCashOut = 0,
    this.cageCash = 0,
    this.cageCashUnbacked = 0,
    this.reentry = 0,
  }) : totalIn = totalIn ?? purchases;
}

/// Aggregates the numbers behind every report.
///
/// Read-only over data that already exists: this class never writes to
/// the ledger, so generating a report can never alter a session's
/// accounting. Every figure is derived from the same
/// [SessionService]/[TournamentService] functions the live screens use,
/// so a report can never disagree with what the banker saw at the table.
class ReportService {
  /// Sessions in a currency, newest first. Reports are always scoped to
  /// one currency — adding Toman to dollars would produce a meaningless
  /// total, so mixed-currency data is reported separately rather than
  /// summed.
  static List<PokerSession> sessionsIn(
    AppCurrency currency, {
    DateTime? from,
    DateTime? to,
    bool endedOnly = false,
  }) {
    final all = HiveService.sessions.values.where((s) {
      if (s.currency != currency) return false;
      if (endedOnly && s.status != SessionStatus.ended) return false;
      if (from != null && s.dateTime.isBefore(from)) return false;
      if (to != null && s.dateTime.isAfter(to)) return false;
      return true;
    }).toList()
      ..sort((a, b) => b.dateTime.compareTo(a.dateTime));
    return all;
  }

  /// Every currency that actually has sessions, so the UI can offer only
  /// the ones worth reporting on.
  static List<AppCurrency> currenciesInUse() {
    final set = HiveService.sessions.values.map((s) => s.currency).toSet();
    final list = set.toList()..sort((a, b) => a.index.compareTo(b.index));
    return list.isEmpty ? [AppCurrency.usd] : list;
  }

  /// Aggregate figures across a set of sessions.
  static PeriodStats aggregate(
    List<PokerSession> sessions, {
    required String label,
    String? labelKey,
    String labelSuffix = '',
    DateTime? from,
    DateTime? to,
  }) {
    var purchases = 0.0,
        reentry = 0.0,
        sessionCashOut = 0.0,
        tableCashOut = 0.0,
        cageCashOut = 0.0,
        cageUnbacked = 0.0,
        rake = 0.0,
        houseWin = 0.0,
        profit = 0.0;
    var playerCount = 0;

    for (final s in sessions) {
      purchases +=
          SessionService.totalBuyIn(s.id) + SessionService.totalRebuy(s.id);
      reentry += SessionService.totalReentry(s.id);
      sessionCashOut += SessionService.totalCashOut(s.id);
      tableCashOut += SessionService.totalTableCashOut(s.id);
      rake += SessionService.totalRake(s.id);
      houseWin += SessionService.totalHouseWin(s.id);
      // Cash game: hostProfit = rake + houseWin. Tournament: house fee
      // (plus any rake already inside TournamentService.houseFee).
      profit += s.isTournament
          ? TournamentService.houseFee(s)
          : SessionService.hostProfit(s.id);
      playerCount += SessionService.playersFor(s.id).length;
      final fin = FinancialLedgerService.snapshotForSession(
        s.id,
        currency: s.currency,
      );
      cageCashOut += fin.cashOutForChips;
      cageUnbacked += fin.cashOutUnbacked;
    }

    final dates = sessions.map((s) => s.dateTime).toList()..sort();
    return PeriodStats(
      label: label,
      labelKey: labelKey,
      labelSuffix: labelSuffix,
      from: from ?? (dates.isEmpty ? DateTime.now() : dates.first),
      to: to ?? (dates.isEmpty ? DateTime.now() : dates.last),
      sessions: sessions.length,
      players: playerCount,
      moneyIn: purchases,
      cashedOut: sessionCashOut,
      purchases: purchases,
      reentry: reentry,
      sessionCashOut: sessionCashOut,
      tableCashOut: tableCashOut,
      cageCashOut: cageCashOut,
      cageCashOutUnbacked: cageUnbacked,
      rake: rake,
      houseWin: houseWin,
      bankerProfit: profit,
    );
  }

  /// Lifetime figures for a currency.
  static PeriodStats lifetime(AppCurrency currency) =>
      aggregate(sessionsIn(currency),
          label: 'Lifetime', labelKey: 'lifetime_label');

  /// One [PeriodStats] per calendar month that has sessions, newest
  /// month first.
  static List<PeriodStats> monthly(AppCurrency currency, {int maxMonths = 12}) {
    final sessions = sessionsIn(currency);
    final buckets = <String, List<PokerSession>>{};
    for (final s in sessions) {
      final key =
          '${s.dateTime.year}-${s.dateTime.month.toString().padLeft(2, '0')}';
      buckets.putIfAbsent(key, () => []).add(s);
    }

    final keys = buckets.keys.toList()..sort((a, b) => b.compareTo(a));
    return [
      for (final k in keys.take(maxMonths))
        () {
          final parts = k.split('-');
          final year = int.parse(parts[0]);
          final month = int.parse(parts[1]);
          return aggregate(
            buckets[k]!,
            label: '${_monthName(month)} $year',
            labelKey: 'month_$month',
            labelSuffix: '$year',
            from: DateTime(year, month, 1),
            to: DateTime(year, month + 1, 0),
          );
        }(),
    ];
  }

  /// Cross-session player performance, biggest winners first.
  ///
  /// Identity-aware: linked seats use [PlayerHistoryService.bankCareers]
  /// so two people named Ali stay two rows. Leftover unlinked seats
  /// remain a name-only group and are never merged into an identity.
  static List<PlayerPerformanceRow> playerPerformance(
    AppCurrency currency, {
    DateTime? from,
    DateTime? to,
  }) {
    final scoped =
        sessionsIn(currency, from: from, to: to).map((s) => s.id).toSet();
    if (scoped.isEmpty) return [];

    final rows = <PlayerPerformanceRow>[];
    for (final career in PlayerHistoryService.bankCareers()) {
      final records =
          career.records.where((r) => scoped.contains(r.session.id)).toList();
      if (records.isEmpty) continue;

      final purchases = records.fold<double>(0, (a, r) => a + r.totalIn);
      final rebuys = records.fold<int>(0, (a, r) => a + r.rebuyCount);
      final last =
          records.map((r) => r.date).reduce((a, b) => a.isAfter(b) ? a : b);
      // Authoritative session P/L (re-entry corrected), not cashOut − in.
      final net = records.fold<double>(0, (a, r) => a + r.profitLoss);
      var tableOut = 0.0, reentry = 0.0, cage = 0.0, unbacked = 0.0;
      for (final r in records) {
        tableOut += _playerSum(
            r.session.id, r.player.id, TransactionType.tableCashOut);
        reentry += SessionService.playerReentry(r.session.id, r.player.id);
        final personId = r.player.personId;
        if (personId == null || personId.isEmpty) continue;
        final fin = FinancialLedgerService.snapshotForSession(
          r.session.id,
          currency: r.session.currency,
          personId: personId,
        );
        cage += fin.cashOutForChips;
        unbacked += fin.cashOutUnbacked;
      }

      rows.add(PlayerPerformanceRow(
        name: career.name,
        personId: career.personId,
        isLegacyNameGroup: career.isLegacyNameGroup,
        sessions: records.length,
        purchases: purchases,
        net: net,
        rebuys: rebuys,
        lastPlayed: last,
        tableCashOut: tableOut,
        cageCash: cage,
        cageCashUnbacked: unbacked,
        reentry: reentry,
      ));
    }

    rows.sort((a, b) => b.net.compareTo(a.net));
    return rows;
  }

  /// Biggest winner and loser in a session, for the summary header.
  static ({String? winner, double winAmount, String? loser, double lossAmount})
      sessionExtremes(PokerSession session) {
    String? winner, loser;
    var best = 0.0, worst = 0.0;
    for (final p in SessionService.playersFor(session.id)) {
      if (!SessionService.hasCashedOut(session.id, p.id)) continue;
      final pl = SessionService.playerProfitLoss(session.id, p.id);
      if (pl > best) {
        best = pl;
        winner = p.name;
      }
      if (pl < worst) {
        worst = pl;
        loser = p.name;
      }
    }
    return (winner: winner, winAmount: best, loser: loser, lossAmount: worst);
  }

  static double _playerSum(
    String sessionId,
    String playerId,
    TransactionType type,
  ) {
    return SessionService.transactionsFor(sessionId)
        .where((t) => t.playerId == playerId && t.type == type)
        .fold(0.0, (s, t) => s + t.amount);
  }

  static String _monthName(int m) {
    const names = [
      'January', 'February', 'March', 'April', 'May', 'June',
      'July', 'August', 'September', 'October', 'November', 'December',
    ];
    return names[(m - 1).clamp(0, 11)];
  }
}
