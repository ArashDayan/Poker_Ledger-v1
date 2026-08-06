import '../models/enums.dart';
import '../models/session.dart';
import 'hive_service.dart';
import 'player_history_service.dart';
import 'session_service.dart';
import 'tournament_service.dart';

/// One row of the banker's lifetime/monthly performance figures.
class PeriodStats {
  final String label;
  final DateTime from;
  final DateTime to;
  final int sessions;
  final int players;
  final double moneyIn;
  final double cashedOut;
  final double rake;
  final double bankerProfit;

  const PeriodStats({
    required this.label,
    required this.from,
    required this.to,
    required this.sessions,
    required this.players,
    required this.moneyIn,
    required this.cashedOut,
    required this.rake,
    required this.bankerProfit,
  });

  double get averagePerSession => sessions == 0 ? 0 : bankerProfit / sessions;
  double get averageBuyIn => players == 0 ? 0 : moneyIn / players;
}

/// A player's line in a cross-session performance report.
class PlayerPerformanceRow {
  final String name;
  final int sessions;
  final double totalIn;
  final double totalOut;
  final double net;
  final int rebuys;
  final DateTime? lastPlayed;

  const PlayerPerformanceRow({
    required this.name,
    required this.sessions,
    required this.totalIn,
    required this.totalOut,
    required this.net,
    required this.rebuys,
    required this.lastPlayed,
  });
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
    DateTime? from,
    DateTime? to,
  }) {
    var moneyIn = 0.0, out = 0.0, rake = 0.0, profit = 0.0;
    var playerCount = 0;

    for (final s in sessions) {
      moneyIn += SessionService.totalBuyIn(s.id) + SessionService.totalRebuy(s.id);
      out += SessionService.totalCashOut(s.id);
      rake += SessionService.totalRake(s.id);
      // A tournament's house income is its entry fee plus any rake; a
      // cash game's is rake alone. Using each mode's own definition keeps
      // the banker's profit line honest across a mixed history.
      profit += s.isTournament
          ? TournamentService.houseFee(s)
          : SessionService.hostProfit(s.id);
      playerCount += SessionService.playersFor(s.id).length;
    }

    final dates = sessions.map((s) => s.dateTime).toList()..sort();
    return PeriodStats(
      label: label,
      from: from ?? (dates.isEmpty ? DateTime.now() : dates.first),
      to: to ?? (dates.isEmpty ? DateTime.now() : dates.last),
      sessions: sessions.length,
      players: playerCount,
      moneyIn: moneyIn,
      cashedOut: out,
      rake: rake,
      bankerProfit: profit,
    );
  }

  /// Lifetime figures for a currency.
  static PeriodStats lifetime(AppCurrency currency) =>
      aggregate(sessionsIn(currency), label: 'Lifetime');

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
            from: DateTime(year, month, 1),
            to: DateTime(year, month + 1, 0),
          );
        }(),
    ];
  }

  /// Cross-session player performance, biggest winners first.
  static List<PlayerPerformanceRow> playerPerformance(
    AppCurrency currency, {
    DateTime? from,
    DateTime? to,
  }) {
    final scoped = sessionsIn(currency, from: from, to: to).map((s) => s.id).toSet();
    if (scoped.isEmpty) return [];

    final rows = <PlayerPerformanceRow>[];
    for (final career in PlayerHistoryService.allCareers()) {
      final records =
          career.records.where((r) => scoped.contains(r.session.id)).toList();
      if (records.isEmpty) continue;

      final totalIn = records.fold<double>(0, (a, r) => a + r.totalIn);
      final totalOut = records.fold<double>(0, (a, r) => a + r.cashOut);
      final rebuys = records.fold<int>(0, (a, r) => a + r.rebuyCount);
      final last = records.map((r) => r.date).reduce((a, b) => a.isAfter(b) ? a : b);

      rows.add(PlayerPerformanceRow(
        name: career.name,
        sessions: records.length,
        totalIn: totalIn,
        totalOut: totalOut,
        net: totalOut - totalIn,
        rebuys: rebuys,
        lastPlayed: last,
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

  static String _monthName(int m) {
    const names = [
      'January', 'February', 'March', 'April', 'May', 'June',
      'July', 'August', 'September', 'October', 'November', 'December',
    ];
    return names[(m - 1).clamp(0, 11)];
  }
}
