import 'package:uuid/uuid.dart';
import '../core/house_rules.dart';
import '../models/player.dart';
import '../models/session.dart';
import '../models/transaction.dart';
import 'dual_verification_service.dart';
import 'hive_service.dart';
import 'participation_service.dart';
import 'player_operation_guard.dart';

const _uuid = Uuid();

/// How urgent a balance discrepancy looks — drives the compact indicator
/// shown while a session is ACTIVE (a big banner is only appropriate at
/// session close; during live play it should be a glance, not a wall of
/// text).
enum BalanceSeverity { balanced, small, large }

/// Result of the end-of-session accounting check.
///
/// IMPORTANT — this is a SESSION-LEVEL check only:
///   Money In  = Buy-ins + Rebuys + Re-entries (carried chips back
///               into table play — Phase 7; never a new purchase)
///   Money Out = Cash-outs + Table Cash-outs + Rake + Dealer Tips +
///               House Wins (house-banked game revenue — Phase 7)
/// A single player's cash-out is NEVER compared against their own
/// buy-in/rebuy. A player can buy in for 2,000, win the session, and
/// cash out for 5,000 — that is correct and must never be blocked.
/// Only the table-wide totals have to reconcile to zero.
class BalanceResult {
  final double moneyIn; // buy-ins + rebuys
  final double moneyOut; // cash-outs + rake
  final double cashDropped; // moved to safe/owner — tracked, not part of the equation
  final double discrepancy; // moneyIn - moneyOut, 0 == balanced
  /// Things the app KNOWS for certain (e.g. a specific player has no
  /// cash-out recorded at all) — always shown before [possibleCauses],
  /// since a concrete lead is worth more than a list of maybes at the
  /// exact moment a tired banker needs the fastest path to a fix.
  final List<String> knownIssues;
  /// Generic, speculative explanations for a discrepancy — shown only
  /// when the totals don't reconcile, and only after [knownIssues].
  final List<String> possibleCauses;
  final List<Player> playersNeverCashedOut; // advisory only, does not block verification
  final bool isBalanced;

  BalanceResult({
    required this.moneyIn,
    required this.moneyOut,
    required this.cashDropped,
    required this.playersNeverCashedOut,
  })  : discrepancy = double.parse((moneyIn - moneyOut).toStringAsFixed(2)),
        isBalanced = (moneyIn - moneyOut).abs() < 0.005,
        knownIssues = _buildKnownIssues(playersNeverCashedOut),
        possibleCauses = _buildPossibleCauses(moneyIn - moneyOut);

  /// Balanced -> green. Within ~2% of total money in (or a small flat
  /// amount when money in is tiny/zero) -> orange, a rounding-sized gap
  /// worth a glance but not alarm. Anything bigger -> red.
  BalanceSeverity get severity {
    if (isBalanced) return BalanceSeverity.balanced;
    final threshold = moneyIn > 0 ? (moneyIn * 0.02).clamp(1000, double.infinity) : 1000;
    return discrepancy.abs() <= threshold ? BalanceSeverity.small : BalanceSeverity.large;
  }

  static List<String> _buildKnownIssues(List<Player> neverCashedOut) {
    if (neverCashedOut.isEmpty) return [];
    return [
      '${neverCashedOut.length} player(s) have no cash-out recorded at all '
      '(not even a 0 cash-out): ${neverCashedOut.map((p) => p.name).join(', ')}. '
      'Confirm they were actually settled before trusting this report.',
    ];
  }

  static List<String> _buildPossibleCauses(double diff) {
    if (diff.abs() < 0.005) return [];
    if (diff > 0) {
      return [
        'A cash-out may be missing from the log.',
        'A table cash-out or house win may be missing from the log.',
        'Rake may not have been fully logged for one or more pots.',
        'A buy-in or rebuy amount may have been entered too high.',
      ];
    }
    return [
      'A buy-in or rebuy may be missing from the log.',
      'A re-entry (carried chips) may be missing from the log.',
      'A cash-out may have been recorded twice, or for too high an amount.',
      'Rake may have been recorded twice.',
    ];
  }
}

/// Thrown when a mutation would violate a house rule. Carries enough
/// context for the UI to show a clear message — and, where appropriate,
/// offer a host override plus a "View Rule" shortcut. Never a hard,
/// unexplained block.
class HouseRuleViolation implements Exception {
  final String message;
  /// A stable key the UI can use to deep-link a "View Rule" action to the
  /// right section of the House Rules screen.
  final String ruleKey;
  HouseRuleViolation(this.message, {this.ruleKey = 'general'});
  @override
  String toString() => message;
}

/// Thrown by any mutation attempted on a session that has already ended.
/// An ended session is genuinely read-only — closing it is a real
/// commitment, not a label, since a report may already be in the owner's
/// hands by the time anyone tries to change something after the fact.
class SessionEndedException implements Exception {
  @override
  String toString() => 'This session has ended and can no longer be modified. '
      'Reopen a new session if further changes are needed.';
}

class SessionService {
  // ---------- Session lock helper ----------

  static void assertSessionActive(String sessionId) {
    final session = HiveService.sessions.get(sessionId);
    if (session != null && session.status == SessionStatus.ended) {
      throw SessionEndedException();
    }
  }

  // ---------- Transaction helpers ----------

  static List<LedgerTransaction> transactionsFor(String sessionId, {bool includeVoided = false}) {
    return HiveService.transactions.values
        .where((t) => t.sessionId == sessionId && (includeVoided || !t.isVoided))
        .toList()
      ..sort((a, b) => a.timestamp.compareTo(b.timestamp));
  }

  /// Transactions belonging to one table.
  ///
  /// A null [tableId] on a transaction means "the session's first table"
  /// — that is what everything recorded before multi-table support
  /// stored — so when filtering by the first table those legacy rows are
  /// included. Without that, an existing session would show an empty
  /// timeline the moment a second table was added.
  static List<LedgerTransaction> transactionsForTable(
    String sessionId,
    String tableId, {
    required bool isFirstTable,
    bool includeVoided = false,
  }) {
    return transactionsFor(sessionId, includeVoided: includeVoided)
        .where((t) =>
            t.tableId == tableId || (isFirstTable && t.tableId == null))
        .toList();
  }

  static List<Player> playersFor(String sessionId) {
    return HiveService.players.values
        .where((p) => p.sessionId == sessionId)
        .toList()
      ..sort((a, b) => a.seatNumber.compareTo(b.seatNumber));
  }

  /// Players currently occupying a seat. Seating-scoped consumers
  /// (table views, seat grids, money actions) must read this rather
  /// than [playersFor], so unseated registrations never leak into seat
  /// logic.
  static List<Player> seatedPlayersFor(String sessionId) =>
      playersFor(sessionId).where((p) => p.seated).toList();

  /// Players registered for the session who do not currently occupy a
  /// seat. Their registration, person link and any session records are
  /// all preserved while they are unseated.
  static List<Player> unseatedPlayersFor(String sessionId) =>
      playersFor(sessionId).where((p) => !p.seated).toList();

  /// This session's registration row for [personId] — seated or not —
  /// or null when the person is not registered for the session. Used to
  /// make pre-seat registration idempotent per (session, person).
  static Player? registeredForSession(String sessionId, String personId) {
    for (final p in playersFor(sessionId)) {
      if (p.personId == personId) return p;
    }
    return null;
  }

  /// The SEATED row for [personId], or null. Deposit-to-chips and the
  /// other flows that physically hand chips to a seat at a table require
  /// an actual seat; a registered-but-unseated person has no seat to
  /// hand chips to (wallet chip issuance is a later phase).
  static Player? seatedForSession(String sessionId, String personId) {
    for (final p in playersFor(sessionId)) {
      if (p.personId == personId && p.seated) return p;
    }
    return null;
  }

  static double _sum(String sessionId, TransactionType type, {String? playerId}) {
    return transactionsFor(sessionId)
        .where((t) => t.type == type && (playerId == null || t.playerId == playerId))
        .fold(0.0, (sum, t) => sum + t.amount);
  }

  static double totalBuyIn(String sessionId) => _sum(sessionId, TransactionType.buyIn);
  static double totalRebuy(String sessionId) => _sum(sessionId, TransactionType.rebuy);
  static double totalCashOut(String sessionId) => _sum(sessionId, TransactionType.cashOut);

  /// TABLE CASH-OUTS (Phase 7): money that left table play because a
  /// player left the table carrying counted chips. The chips stay the
  /// person's physical holding — this is session money OUT, but NOT
  /// the cage's final redemption (that is [totalCashOut]).
  ///
  /// A table cash-out is the table-level out of a carried-chips cycle;
  /// when the player re-enters another table with the same chips, the
  /// re-entry ([totalReentry]) brings the value back into table play,
  /// so the pair balances across the session.
  static double totalTableCashOut(String sessionId) =>
      _sum(sessionId, TransactionType.tableCashOut);

  /// RE-ENTRIES (Phase 7): carried chips committed to a table — the
  /// player's EXISTING person-scoped holding re-entering table play.
  /// Session money IN (it balances the table cash-out that carried the
  /// chips off the previous table), but never a new purchase:
  /// [totalBuyIn] and every wallet figure are untouched by it.
  static double totalReentry(String sessionId) =>
      _sum(sessionId, TransactionType.reentry);

  /// HOUSE WINS (Phase 7): house-banked game revenue (e.g. roulette).
  /// Session money OUT and house income — classified separately from
  /// [totalRake] everywhere it is reported; the two are never merged.
  static double totalHouseWin(String sessionId) =>
      _sum(sessionId, TransactionType.houseWin);
  static double totalRake(String sessionId) => _sum(sessionId, TransactionType.rakeCollection);
  static double totalCashDrop(String sessionId) => _sum(sessionId, TransactionType.cashDrop);

  /// Chips tipped to the dealer, across the session.
  ///
  /// A REAL money-out flow: these chips physically left the tables and
  /// went back to the Bank, so [moneyStillInPlay] and [checkBalance]
  /// must both account for them or a fully-settled session would look
  /// short by the tip total.
  ///
  /// Deliberately NOT part of [hostProfit]. The money is owed to the
  /// dealer, not kept by the host.
  static double totalDealerTips(String sessionId) =>
      _sum(sessionId, TransactionType.dealerTips);

  /// Total cash a player has put into play (buy-in + all rebuys).
  /// Informational only — display purposes and house-rule checks.
  /// NEVER used to cap or validate that player's cash-out amount.
  static double playerTotalIn(String sessionId, String playerId) {
    return _sum(sessionId, TransactionType.buyIn, playerId: playerId) +
        _sum(sessionId, TransactionType.rebuy, playerId: playerId);
  }

  /// Just the opening buy-in(s), separate from rebuys, for the player
  /// card's Buy-in / Rebuy / Cash-out breakdown.
  static double playerBuyInOnly(String sessionId, String playerId) =>
      _sum(sessionId, TransactionType.buyIn, playerId: playerId);

  static double playerRebuyOnly(String sessionId, String playerId) =>
      _sum(sessionId, TransactionType.rebuy, playerId: playerId);

  /// Total money a player has taken off the table(s): cage redemptions
  /// (cashOut) + table cash-outs (Phase 7 — the player left the table
  /// carrying counted chips). A player who busted out with a recorded
  /// $0 leg contributes 0 here — that is different from never having
  /// cashed out at all (see [hasCashedOut]).
  static double playerTotalCashOut(String sessionId, String playerId) {
    return _sum(sessionId, TransactionType.cashOut, playerId: playerId) +
        _sum(sessionId, TransactionType.tableCashOut, playerId: playerId);
  }

  /// Phase 7: the carried chips this player re-committed to tables via
  /// re-entry. These chips were already "put in" when they were first
  /// purchased — a re-entry never counts as new money in for P/L
  /// purposes; it only cancels the matching table cash-out(s) so the
  /// same chips are not taken twice.
  static double playerReentry(String sessionId, String playerId) =>
      _sum(sessionId, TransactionType.reentry, playerId: playerId);

  /// Phase 7: house wins this player paid at house-banked games
  /// (e.g. roulette). Session money OUT — settled, no longer in play.
  ///
  /// Deliberately NOT part of [playerProfitLoss]: the value went to the
  /// HOUSE, not back to the player. The loss surfaces in the P/L
  /// through the smaller carried-out amount (the player's chips left
  /// the books for the house, so less comes back via table cash-outs /
  /// redemption) — counting the house win as a player "out" would
  /// double-count the same chips.
  static double playerHouseWin(String sessionId, String playerId) =>
      _sum(sessionId, TransactionType.houseWin, playerId: playerId);

  /// Whether the player has settled a table: a cage redemption (cashOut)
  /// OR a table cash-out (Phase 7) has been RECORDED for them,
  /// regardless of amount. A $0 leg (busted out) counts as "settled" —
  /// it is not the same as no record existing yet.
  static bool hasCashedOut(String sessionId, String playerId) {
    return transactionsFor(sessionId).any((t) =>
        t.playerId == playerId &&
        (t.type == TransactionType.cashOut ||
            t.type == TransactionType.tableCashOut));
  }

  /// True when a $0 cash-out or $0 table cash-out exists for this
  /// player. A later $0 bust still counts after earlier non-zero
  /// table cash-outs. Query only — does not change P/L or money
  /// formulas. Discount inspect uses this instead of
  /// `hasCashedOut && playerTotalCashOut == 0`.
  static bool hasZeroBustOut(String sessionId, String playerId) {
    return transactionsFor(sessionId).any((t) =>
        t.playerId == playerId &&
        t.amount == 0 &&
        (t.type == TransactionType.cashOut ||
            t.type == TransactionType.tableCashOut));
  }

  /// Net result: the money the player truly took OUT of the session
  /// (final redemptions plus carried chips that did NOT come back) minus
  /// everything they put in.
  ///
  /// PHASE 7 RE-ENTRY CORRECTION: a table cash-out is NOT a final
  /// settlement — the player carries the chips and can re-enter with the
  /// SAME chips. So a carried-out amount that the player re-committed
  /// must be netted out, or the same chips would count as "taken" twice
  /// (once at the table cash-out, once at the later redemption). The
  /// re-entry subtracts exactly the amount that came back into play, so
  /// only the chips the player ultimately kept (and later redeemed) are
  /// counted as money taken out.
  ///
  /// This is purely informational/reporting — it is a *result*, never a
  /// constraint on how much someone is allowed to cash out.
  static double playerProfitLoss(String sessionId, String playerId) {
    return (playerTotalCashOut(sessionId, playerId) -
                playerReentry(sessionId, playerId)) -
            playerTotalIn(sessionId, playerId);
  }

  /// Rake attributed to one player.
  ///
  /// IMPORTANT: this is reporting only. Rake NEVER affects a player's
  /// profit/loss — [playerProfitLoss] counts buy-ins, rebuys and
  /// cash-outs alone. Attributing a rake to a player records WHO the pot
  /// belonged to so it shows in their history; the money itself is still
  /// house income and still lands in the session-wide [totalRake].
  static double playerRakeTotal(String sessionId, String playerId) =>
      _sum(sessionId, TransactionType.rakeCollection, playerId: playerId);

  /// Rake taken at table level, with no player attached.
  static double unattributedRake(String sessionId) =>
      transactionsFor(sessionId)
          .where((t) =>
              t.type == TransactionType.rakeCollection && t.playerId == null)
          .fold(0.0, (sum, t) => sum + t.amount);

  static int rebuyCountForPlayer(String sessionId, String playerId) {
    return transactionsFor(sessionId)
        .where((t) => t.type == TransactionType.rebuy && t.playerId == playerId)
        .length;
  }

  /// Most recent non-voided amount this player was given for [type], for
  /// pre-filling the amount field — returns null if they've never had
  /// one. Callers decide whether/how to fall back further (see
  /// SessionProvider.lastAmountFor — cash-out deliberately never falls
  /// back to any unrelated default).
  static double? lastAmountForPlayer(String sessionId, String playerId, TransactionType type) {
    final matches = transactionsFor(sessionId)
        .where((t) => t.type == type && t.playerId == playerId)
        .toList();
    if (matches.isEmpty) return null;
    return matches.last.amount;
  }

  /// The house's total earnings from the session: poker rake PLUS
  /// house-game wins (Phase 7).
  ///
  /// REVENUE BY SOURCE (Phase 7): the two components stay SEPARATE
  /// everywhere they are reported — [totalRake] is the house's fee on
  /// player-vs-player poker pots, [totalHouseWin] is the house playing
  /// against the player and winning their chips (e.g. roulette). They
  /// are never merged into a generic "rake" figure; this getter is only
  /// their sum (the house's total take), and both components remain
  /// individually queryable for the accounting/reporting layer.
  static double hostProfit(String sessionId) =>
      totalRake(sessionId) + totalHouseWin(sessionId);

  /// Cash still physically on the table (or with players): everything
  /// that came in, minus everything paid out or taken as rake. This is
  /// the live "current pot" figure — mathematically identical to the
  /// balance-check's discrepancy figure once the session is fully
  /// settled; both are shown as the same value in the UI intentionally.
  static double moneyStillInPlay(String sessionId) {
    return totalBuyIn(sessionId) +
        totalRebuy(sessionId) +
        // Re-entries (Phase 7) bring carried chips back into table
        // play — they are money IN, balancing the table cash-out that
        // carried those same chips off the previous table.
        totalReentry(sessionId) -
        totalCashOut(sessionId) -
        // Table cash-outs leave table play the same way redemptions
        // do (Phase 7): the chips are in the person's hand, not at
        // the table.
        totalTableCashOut(sessionId) -
        totalRake(sessionId) -
        // Subtracted ONCE, for the same reason checkBalance adds it to
        // money out: tipped chips are no longer on the table.
        totalDealerTips(sessionId) -
        // House wins (Phase 7) leave table play for the house — the
        // chips became casino-owned at a house-banked game.
        totalHouseWin(sessionId);
  }

  /// A soft, non-blocking check for whether [amount] looks unusually
  /// large compared to the largest transaction seen so far tonight — the
  /// kind of thing an extra typed zero produces. Scaled to the session's
  /// own numbers rather than a fixed threshold, so it works whether the
  /// game is played in hundreds or in millions of Toman, and doesn't
  /// nag legitimately big winners on a session that's been big all night.
  static bool isAmountOutlier(String sessionId, double amount) {
    if (amount <= 0) return false;
    final allAmounts = transactionsFor(sessionId).map((t) => t.amount).toList();
    if (allAmounts.isEmpty) return false;
    final maxSoFar = allAmounts.reduce((a, b) => a > b ? a : b);
    if (maxSoFar <= 0) return false;
    return amount > maxSoFar * 5;
  }

  // ---------- The balance check (SESSION LEVEL ONLY) ----------

  static BalanceResult checkBalance(String sessionId) {
    // Re-entries (Phase 7) are money IN: the player's carried chips
    // re-enter table play, exactly balancing the table cash-out that
    // carried them off the previous table. They are NOT a new purchase
    // (totalBuyIn is untouched) — but for the session identity they are
    // an inflow, just like a buy-in.
    final moneyIn = totalBuyIn(sessionId) +
        totalRebuy(sessionId) +
        totalReentry(sessionId);
    // Dealer tips are counted here ONCE, alongside cash-out and rake,
    // because those chips physically left the table for the Bank. A
    // settled session that paid tips would otherwise report a false
    // discrepancy equal to the tip total.
    // Table cash-outs (Phase 7) are session money OUT — the chips
    // left table play for the person's hand — counted exactly like
    // redemptions in the identity.
    // House wins (Phase 7) are session money OUT — the chips became
    // casino-owned at a house-banked game. Counted here like rake, but
    // kept on its own figure ([totalHouseWin]) so the report classifies
    // revenue by source instead of merging it into "rake".
    final moneyOut = totalCashOut(sessionId) +
        totalTableCashOut(sessionId) +
        totalRake(sessionId) +
        totalDealerTips(sessionId) +
        totalHouseWin(sessionId);
    // Seated players only: an unseated registration never played, so
    // flagging it as "never cashed out" would be a false lead.
    final neverCashedOut = seatedPlayersFor(sessionId)
        .where((p) => !hasCashedOut(sessionId, p.id))
        .toList();

    return BalanceResult(
      moneyIn: moneyIn,
      moneyOut: moneyOut,
      cashDropped: totalCashDrop(sessionId),
      playersNeverCashedOut: neverCashedOut,
    );
  }

  // ---------- House-rule checks (advisory, raise HouseRuleViolation) ----------

  /// Buy-in/rebuy cap check. Uses the session's own cap if set, otherwise
  /// no cap is enforced. Call before recording a buyIn/rebuy; catch
  /// [HouseRuleViolation] in the UI to offer a host override + "View Rule".
  static void assertWithinBuyInCap(PokerSession session, String playerId, double amount) {
    final cap = session.buyInCapAmount;
    if (cap == null || cap <= 0) return;
    final projected = playerTotalIn(session.id, playerId) + amount;
    if (projected > cap + 0.005) {
      throw HouseRuleViolation(
        'This would put the player at more than the buy-in cap '
        '(${cap.toStringAsFixed(0)}). Current total in: '
        '${playerTotalIn(session.id, playerId).toStringAsFixed(0)}.',
        ruleKey: 'buyInCap',
      );
    }
  }

  /// Standard rebuy eligibility at the session's current level, using the
  /// session's own (editable) rebuyLastLevel. When
  /// [PokerSession.rebuyLevelEnforcementEnabled] is off, rebuys are never
  /// gated by level at all — for tables that don't run formal blind
  /// levels, where level-based gating would otherwise fire a warning on
  /// every single rebuy of the night.
  static bool canRebuy(PokerSession session, String playerId) {
    if (!session.rebuyLevelEnforcementEnabled) return true;
    final used = rebuyCountForPlayer(session.id, playerId);
    final allowed = HouseRules.maxRebuysAllowedAtLevel(
      session.currentLevel,
      lastLevel: session.rebuyLastLevel,
    );
    return used < allowed;
  }

  // ---------- Mutations ----------

  /// Records a new transaction.
  ///
  /// IMPORTANT: a cash-out of exactly 0 is VALID and required to be
  /// accepted — a player who loses every chip busts out for $0, and the
  /// banker must be able to log that. Every other transaction type still
  /// requires a positive amount (a $0 buy-in/rebuy/rake/cash-drop isn't a
  /// real transaction and shouldn't be logged as one).
  ///
  /// If [playerId] refers to a player already marked settled/inactive,
  /// the transaction is stamped [LedgerTransaction.signedWhileAbsent] —
  /// the signature just captured cannot have been that player's own.
  static Future<LedgerTransaction> recordTransaction({
    required String sessionId,
    String? playerId,
    required TransactionType type,
    required double amount,
    String? hostSignatureBase64,
    String? note,
    String? voiceNotePath,
    String? tableId,
    String? operatorName,
    String? secondVerifierName,
    String? secondVerifierSignature,
  }) async {
    assertSessionActive(sessionId);
    if (amount < 0) {
      throw ArgumentError('Amount cannot be negative.');
    }
    // A zero is VALID for a cash-out and for a table cash-out: a busted
    // player leaves with (and re-enters nothing) $0. Every other type
    // requires a positive amount (a $0 buy-in/rebuy/rake/drop/re-entry is
    // not a real transaction).
    if (amount == 0 &&
        type != TransactionType.cashOut &&
        type != TransactionType.tableCashOut) {
      throw ArgumentError('Amount must be greater than zero for ${type.label}.');
    }
    final player = playerId == null ? null : HiveService.players.get(playerId);
    // J5 absolute gate at the central ledger service boundary. No new
    // player-attributed money leg is written without a registered Player
    // Master identity. There is no implicit identity creation here and no
    // legacy-permissive fallback.
    if (playerId != null) {
      PlayerOperationGuard.requireRegistered(player, '${type.label}');
    }
    // A player transaction is always attributed to the table that player
    // is actually sitting at, rather than whichever table the banker
    // happens to be viewing — moving a player mid-hand must never
    // misfile their money. Table-level rows (rake, cash drop) fall back
    // to the table passed in by the caller.
    final resolvedTableId = player?.tableId ?? tableId;
    final tx = LedgerTransaction(
      id: _uuid.v4(),
      sessionId: sessionId,
      playerId: playerId,
      type: type,
      amount: amount,
      hostSignatureBase64: hostSignatureBase64,
      note: note,
      voiceNotePath: voiceNotePath,
      signedWhileAbsent: player != null && !player.isActive,
      tableId: resolvedTableId,
    );
    if (tx.requiresSignature &&
        (hostSignatureBase64 == null || hostSignatureBase64.isEmpty)) {
      throw StateError(
        'A host signature is required for ${type.label} transactions.',
      );
    }
    // J8: configurable second-authorisation gate. This is not a numeric
    // constant — the House Rules/settings can enable it only after a
    // threshold has been configured; without it, ordinary transactions
    // are unchanged. The second signature is required BEFORE the leg is
    // written, and the check is recorded in the immutable audit event
    // stream below.
    final dual = DualVerificationService.requiresSecond(amount);
    if (dual &&
        (secondVerifierSignature == null ||
            secondVerifierSignature.isEmpty)) {
      throw StateError(
        'A second authorisation is required for this ${type.label} '
        '(sensitive operation).',
      );
    }
    // Phase 6: stamp player money legs onto their table participation
    // (opens on the first leg). Tracking never breaks money — any
    // failure here leaves the leg unstamped, which settles as before.
    ParticipationService.stampTransaction(tx);
    await HiveService.transactions.put(tx.id, tx);
    if (dual) {
      await DualVerificationService.recordVerification(
        operation: '${type.name}_transaction',
        playerId: playerId,
        personId: player?.personId,
        sourceTableId: resolvedTableId,
        amount: amount,
        operatorName: operatorName ?? '',
        secondVerifierName: secondVerifierName ?? '',
        hostSignatureBase64: hostSignatureBase64 ?? '',
        secondVerifierSignature: secondVerifierSignature ?? '',
        relatedTransactionId: tx.id,
      );
    }
    return tx;
  }

  /// Edits an already-recorded transaction's amount/note. The record is
  /// updated in place (never duplicated) and stamped [isEdited]/[editedAt]
  /// so the audit log always shows it was amended, and by when. A fresh
  /// signature is required whenever the transaction type normally
  /// requires one, since the amount is changing. If the player is no
  /// longer active, the edit is stamped [LedgerTransaction.signedWhileAbsent]
  /// for the same reason a new transaction would be.
  static Future<LedgerTransaction> updateTransaction({
    required String transactionId,
    required double amount,
    String? note,
    String? hostSignatureBase64,
    String? operatorName,
    String? secondVerifierName,
    String? secondVerifierSignature,
  }) async {
    final tx = HiveService.transactions.get(transactionId);
    if (tx == null) {
      throw StateError('Transaction not found.');
    }
    assertSessionActive(tx.sessionId);
    if (amount < 0) {
      throw ArgumentError('Amount cannot be negative.');
    }
    // A zero is VALID for a cash-out and for a table cash-out (a busted
    // player). Every other type requires a positive amount.
    if (amount == 0 &&
        tx.type != TransactionType.cashOut &&
        tx.type != TransactionType.tableCashOut) {
      throw ArgumentError('Amount must be greater than zero for ${tx.type.label}.');
    }
    if (tx.requiresSignature &&
        (hostSignatureBase64 == null || hostSignatureBase64.isEmpty)) {
      throw StateError(
        'A host signature is required to confirm this edit.',
      );
    }
    // J8: an edit to a sensitive/high-value leg is itself a sensitive
    // operation and must carry the second authorisation before the
    // record is changed.
    final dual = DualVerificationService.requiresSecond(amount);
    if (dual &&
        (secondVerifierSignature == null ||
            secondVerifierSignature.isEmpty)) {
      throw StateError(
        'A second authorisation is required to edit this ${tx.type.label}.',
      );
    }
    final player = tx.playerId == null ? null : HiveService.players.get(tx.playerId);
    // J5 absolute gate at the central ledger service boundary. An edit of
    // a player-attributed row is still a player financial operation and
    // must be performed against a registered identity, never a
    // legacy-permissive seat row.
    if (tx.playerId != null) {
      PlayerOperationGuard.requireRegistered(player, '${tx.type.label}');
    }
    tx.amount = amount;
    tx.note = note;
    if (hostSignatureBase64 != null && hostSignatureBase64.isNotEmpty) {
      tx.hostSignatureBase64 = hostSignatureBase64;
    }
    tx.isEdited = true;
    tx.editedAt = DateTime.now();
    if (player != null && !player.isActive) {
      tx.signedWhileAbsent = true;
    }
    await tx.save();
    if (dual) {
      await DualVerificationService.recordVerification(
        operation: '${tx.type.name}_edit',
        playerId: tx.playerId,
        personId: player?.personId,
        sourceTableId: tx.tableId,
        amount: amount,
        operatorName: operatorName ?? '',
        secondVerifierName: secondVerifierName ?? '',
        hostSignatureBase64: hostSignatureBase64 ?? '',
        secondVerifierSignature: secondVerifierSignature ?? '',
        relatedTransactionId: tx.id,
      );
    }
    return tx;
  }

  /// Voids ANY transaction (not just the most recent one) — the general
  /// case used from the transaction list. Preserves the audit trail:
  /// the record stays, just excluded from every balance calculation.
  static Future<LedgerTransaction> voidTransaction(String transactionId) async {
    final tx = HiveService.transactions.get(transactionId);
    if (tx == null) throw StateError('Transaction not found.');
    assertSessionActive(tx.sessionId);
    _requireRegisteredTxPlayer(tx, 'void');
    tx.isVoided = true;
    await tx.save();
    return tx;
  }

  static Future<LedgerTransaction> unvoidTransaction(String transactionId) async {
    final tx = HiveService.transactions.get(transactionId);
    if (tx == null) throw StateError('Transaction not found.');
    assertSessionActive(tx.sessionId);
    _requireRegisteredTxPlayer(tx, 'unvoid');
    tx.isVoided = false;
    await tx.save();
    return tx;
  }

  /// Permanently removes a transaction from the ledger. Unlike void, this
  /// cannot be undone — callers MUST confirm with the banker first (and
  /// PIN-gate it if a PIN is set). Used for genuine mistakes that
  /// shouldn't linger even as a voided record.
  static Future<void> deleteTransactionPermanently(String transactionId) async {
    final tx = HiveService.transactions.get(transactionId);
    if (tx == null) return;
    assertSessionActive(tx.sessionId);
    _requireRegisteredTxPlayer(tx, 'permanent delete of');
    await HiveService.transactions.delete(transactionId);
  }

  static void _requireRegisteredTxPlayer(
      LedgerTransaction tx, String operation) {
    if (tx.playerId == null) return;
    PlayerOperationGuard.requireRegistered(
      HiveService.players.get(tx.playerId),
      '$operation of a ${tx.type.label}',
    );
  }

  /// Explicit host action: mark a player as settled/left the table.
  /// Player "active" status is no longer inferred from stack math (a
  /// winner's cash-out can exceed their buy-in, so there is no zero-stack
  /// signal to key off of) — the host says when someone is done.
  static Future<void> markPlayerSettled(Player player, {bool settled = true}) async {
    assertSessionActive(player.sessionId);
    // J5 gate: leaving/settling a seat is a player table operation too.
    // The audited unseat/leave path is preferred, but this legacy helper
    // must still refuse anonymous/unregistered seat rows.
    PlayerOperationGuard.requireRegistered(player, 'settle/leave');
    player.isActive = !settled;
    await player.save();
  }

  static Future<void> advanceLevel(PokerSession session) async {
    assertSessionActive(session.id);
    session.currentLevel += 1;
    await session.save();
  }

  /// Voids the most recent non-voided transaction for a session (the
  /// quick "Undo" button). For editing/voiding an arbitrary earlier
  /// transaction, use [voidTransaction] from the transaction list instead.
  static LedgerTransaction? undoLast(String sessionId) {
    assertSessionActive(sessionId);
    final txs = transactionsFor(sessionId);
    if (txs.isEmpty) return null;
    final last = txs.last;
    _requireRegisteredTxPlayer(last, 'undo');
    last.isVoided = true;
    last.save();
    return last;
  }

  static Future<LedgerTransaction?> redo(String sessionId, String txId) async {
    assertSessionActive(sessionId);
    final tx = HiveService.transactions.get(txId);
    if (tx == null) return null;
    _requireRegisteredTxPlayer(tx, 'redo');
    tx.isVoided = false;
    await tx.save();
    return tx;
  }
}
