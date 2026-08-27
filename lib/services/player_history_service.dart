import '../models/enums.dart';
import '../models/player.dart';
import '../models/session.dart';
import 'hive_service.dart';
import 'session_service.dart';

/// One player's appearance in a single session.
class PlayerSessionRecord {
  final PokerSession session;
  final Player player;
  final double buyIn;
  final double rebuy;
  final double cashOut;
  final double profitLoss;
  final int rebuyCount;
  final bool settled;

  PlayerSessionRecord({
    required this.session,
    required this.player,
    required this.buyIn,
    required this.rebuy,
    required this.cashOut,
    required this.profitLoss,
    required this.rebuyCount,
    required this.settled,
  });

  double get totalIn => buyIn + rebuy;
  DateTime get date => session.dateTime;
}

/// A player's whole career across every session the host has run.
class PlayerCareer {
  /// Display name (as most recently spelled).
  final String name;

  /// Normalised name key (legacy grouping) or `person:<id>`.
  final String key;

  /// Permanent identity when this career is a real person. Null means
  /// a legacy name-only group that was never linked — not a personId.
  final String? personId;

  /// True when seats were grouped only by display name because they
  /// have no personId. Those rows are not a financial account.
  final bool isLegacyNameGroup;

  final List<PlayerSessionRecord> records;

  PlayerCareer({
    required this.name,
    required this.key,
    required this.records,
    this.personId,
    this.isLegacyNameGroup = false,
  });

  bool get hasPersistentIdentity =>
      personId != null && personId!.isNotEmpty && !isLegacyNameGroup;

  int get sessionsPlayed => records.length;

  double get totalBuyIn => records.fold(0.0, (s, r) => s + r.buyIn);
  double get totalRebuy => records.fold(0.0, (s, r) => s + r.rebuy);
  double get totalIn => records.fold(0.0, (s, r) => s + r.totalIn);
  double get totalCashOut => records.fold(0.0, (s, r) => s + r.cashOut);

  /// Lifetime profit/loss. Sum of each session's authoritative
  /// [SessionService.playerProfitLoss] (re-entry corrected). Never
  /// `totalCashOut - totalIn`, which would ignore re-entry and
  /// double-count carried chips.
  double get netResult => records.fold(0.0, (s, r) => s + r.profitLoss);

  int get totalRebuys => records.fold(0, (s, r) => s + r.rebuyCount);

  /// Sessions where they finished ahead. Only counts sessions that are
  /// actually finished for that player (a cash-out was recorded), since a
  /// player still sitting at a live table hasn't won or lost yet.
  int get sessionsWon => _completed.where((r) => r.profitLoss > 0).length;
  int get sessionsLost => _completed.where((r) => r.profitLoss < 0).length;
  int get sessionsBreakEven => _completed.where((r) => r.profitLoss == 0).length;

  List<PlayerSessionRecord> get _completed =>
      records.where((r) => r.settled).toList();

  int get completedSessions => _completed.length;

  /// Win rate over completed sessions only. Null when they have never
  /// finished one — showing "0%" for a player who has simply never
  /// cashed out yet would be a lie.
  double? get winRate {
    final done = completedSessions;
    if (done == 0) return null;
    return sessionsWon / done * 100;
  }

  /// Average result per completed session.
  double? get averageResult {
    final done = _completed;
    if (done.isEmpty) return null;
    return done.fold(0.0, (s, r) => s + r.profitLoss) / done.length;
  }

  double get averageBuyIn =>
      records.isEmpty ? 0 : totalIn / records.length;

  PlayerSessionRecord? get biggestWin {
    final done = _completed.where((r) => r.profitLoss > 0).toList();
    if (done.isEmpty) return null;
    done.sort((a, b) => b.profitLoss.compareTo(a.profitLoss));
    return done.first;
  }

  PlayerSessionRecord? get biggestLoss {
    final done = _completed.where((r) => r.profitLoss < 0).toList();
    if (done.isEmpty) return null;
    done.sort((a, b) => a.profitLoss.compareTo(b.profitLoss));
    return done.first;
  }

  DateTime? get firstPlayed =>
      records.isEmpty ? null : records.map((r) => r.date).reduce((a, b) => a.isBefore(b) ? a : b);

  DateTime? get lastPlayed =>
      records.isEmpty ? null : records.map((r) => r.date).reduce((a, b) => a.isAfter(b) ? a : b);

  /// Most recent appearances first.
  List<PlayerSessionRecord> get recentSessions {
    final sorted = [...records]..sort((a, b) => b.date.compareTo(a.date));
    return sorted;
  }

  /// Every currency this player's sessions were played in. Totals are
  /// only meaningful when there is exactly one — see
  /// [hasConsistentCurrency].
  Set<AppCurrency> get currencies => records.map((r) => r.session.currency).toSet();

  bool get hasConsistentCurrency => currencies.length <= 1;

  AppCurrency get currency =>
      currencies.isEmpty ? AppCurrency.usd : currencies.first;
}

/// Builds cross-session player history.
///
/// IMPORTANT — how players are linked across sessions:
/// A [Player] row belongs to exactly one session; there is no global
/// player registry in this app, and adding one would mean migrating
/// every existing saved session. So a "career" is assembled by grouping
/// player rows by their **normalised name** (see [normaliseName]).
///
/// That is a deliberate trade-off and it has a real limitation: two
/// different people who share a name are treated as one player, and one
/// person entered as "Ali" one week and "Ali K" the next is treated as
/// two. The alternative — silently merging on fuzzy similarity — risks
/// mixing up two people's money history, which is far worse for a
/// banker than an obviously-split record they can see and correct by
/// renaming. Nothing here writes to the ledger; it is a read-only view
/// over data that already exists.
class PlayerHistoryService {
  /// Case- and spacing-insensitive key for grouping the same human across
  /// sessions. Collapses internal whitespace so "Ali  Reza" and
  /// "ali reza" are one person.
  static String normaliseName(String name) =>
      name.trim().toLowerCase().replaceAll(RegExp(r'\s+'), ' ');

  /// Builds one record for a specific player row.
  ///
  /// A pre-seat registration that never took a seat and never recorded
  /// a transaction is not a session appearance — listing it would
  /// inflate "sessions played" with nights the person never played.
  /// A player who DID play (has transactions) keeps their appearance
  /// record even after being unseated, so unseating a player can never
  /// erase their history.
  static PlayerSessionRecord? recordFor(Player player) {
    final session = HiveService.sessions.get(player.sessionId);
    if (session == null) return null;
    if (!player.seated &&
        SessionService.transactionsFor(session.id, includeVoided: true)
                .where((t) => t.playerId == player.id)
                .isEmpty) {
      return null;
    }
    return PlayerSessionRecord(
      session: session,
      player: player,
      buyIn: SessionService.playerBuyInOnly(session.id, player.id),
      rebuy: SessionService.playerRebuyOnly(session.id, player.id),
      cashOut: SessionService.playerTotalCashOut(session.id, player.id),
      profitLoss: SessionService.playerProfitLoss(session.id, player.id),
      rebuyCount: SessionService.rebuyCountForPlayer(session.id, player.id),
      settled: SessionService.hasCashedOut(session.id, player.id),
    );
  }

  /// Every career the host has on record, best-known name first.
  static List<PlayerCareer> allCareers() {
    final grouped = <String, List<Player>>{};
    for (final p in HiveService.players.values) {
      if (p.name.trim().isEmpty) continue;
      grouped.putIfAbsent(normaliseName(p.name), () => []).add(p);
    }

    final careers = <PlayerCareer>[];
    grouped.forEach((key, players) {
      final records = <PlayerSessionRecord>[];
      for (final p in players) {
        final r = recordFor(p);
        if (r != null) records.add(r);
      }
      if (records.isEmpty) return;

      // Display the most recently used spelling of the name.
      records.sort((a, b) => b.date.compareTo(a.date));
      careers.add(PlayerCareer(
        name: records.first.player.name.trim(),
        key: key,
        records: records,
        isLegacyNameGroup: true,
      ));
    });

    careers.sort((a, b) {
      final aLast = a.lastPlayed;
      final bLast = b.lastPlayed;
      if (aLast == null || bLast == null) return a.name.compareTo(b.name);
      return bLast.compareTo(aLast);
    });
    return careers;
  }

  /// Identity-scoped when the seat is linked; otherwise the legacy
  /// name group. Does not invent a personId.
  static PlayerCareer careerFor(Player player) {
    final id = player.personId;
    if (id != null && id.isNotEmpty) {
      return careerForPersonId(id, fallbackName: player.name);
    }
    return careerForName(player.name);
  }

  /// Seats linked to [personId] only. Another human with the same
  /// display name is never included.
  static PlayerCareer careerForPersonId(String personId,
      {String? fallbackName}) {
    final records = <PlayerSessionRecord>[];
    for (final p in HiveService.players.values) {
      if (p.personId != personId) continue;
      final r = recordFor(p);
      if (r != null) records.add(r);
    }
    records.sort((a, b) => b.date.compareTo(a.date));
    String name = fallbackName?.trim() ?? '';
    try {
      final identity = HiveService.playerIdentities.get(personId);
      if (identity != null && identity.displayName.trim().isNotEmpty) {
        name = identity.displayName.trim();
      }
    } catch (_) {}
    if (name.isEmpty && records.isNotEmpty) {
      name = records.first.player.name.trim();
    }
    return PlayerCareer(
      name: name,
      key: 'person:$personId',
      records: records,
      personId: personId,
    );
  }

  static PlayerCareer careerForName(String name) {
    final key = normaliseName(name);
    final records = <PlayerSessionRecord>[];
    for (final p in HiveService.players.values) {
      if (normaliseName(p.name) != key) continue;
      final r = recordFor(p);
      if (r != null) records.add(r);
    }
    records.sort((a, b) => b.date.compareTo(a.date));
    return PlayerCareer(
      name: records.isNotEmpty ? records.first.player.name.trim() : name.trim(),
      key: key,
      records: records,
      isLegacyNameGroup: true,
    );
  }

  /// Player Bank: one row per identity, plus unlinked seats by name.
  static List<PlayerCareer> bankCareers() {
    final out = <PlayerCareer>[];
    try {
      for (final identity in HiveService.playerIdentities.values) {
        out.add(careerForPersonId(identity.id,
            fallbackName: identity.displayName));
      }
    } catch (_) {}

    final leftover = <String, List<Player>>{};
    for (final p in HiveService.players.values) {
      if (p.personId != null && p.personId!.isNotEmpty) continue;
      if (p.name.trim().isEmpty) continue;
      leftover.putIfAbsent(normaliseName(p.name), () => []).add(p);
    }
    leftover.forEach((key, players) {
      final records = <PlayerSessionRecord>[];
      for (final p in players) {
        final r = recordFor(p);
        if (r != null) records.add(r);
      }
      if (records.isEmpty) return;
      records.sort((a, b) => b.date.compareTo(a.date));
      out.add(PlayerCareer(
        name: records.first.player.name.trim(),
        key: 'legacy:$key',
        records: records,
        isLegacyNameGroup: true,
      ));
    });

    out.sort((a, b) {
      final aLast = a.lastPlayed;
      final bLast = b.lastPlayed;
      if (aLast == null && bLast == null) {
        return a.name.toLowerCase().compareTo(b.name.toLowerCase());
      }
      if (aLast == null) return 1;
      if (bLast == null) return -1;
      return bLast.compareTo(aLast);
    });
    return out;
  }

  /// Legacy name search (reports / old callers).
  static List<PlayerCareer> search(String query) {
    final q = query.trim().toLowerCase();
    final all = allCareers();
    if (q.isEmpty) return all;
    return all.where((c) => c.name.toLowerCase().contains(q)).toList();
  }

  static List<PlayerCareer> searchBank(String query) {
    final q = query.trim().toLowerCase();
    final all = bankCareers();
    if (q.isEmpty) return all;
    return all.where((c) {
      if (c.name.toLowerCase().contains(q)) return true;
      final id = c.personId;
      return id != null && id.toLowerCase().contains(q);
    }).toList();
  }
}
