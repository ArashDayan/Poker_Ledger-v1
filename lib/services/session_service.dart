import 'package:uuid/uuid.dart';
import '../core/house_rules.dart';
import '../models/player.dart';
import '../models/session.dart';
import '../models/transaction.dart';
import 'hive_service.dart';

const _uuid = Uuid();

/// How urgent a balance discrepancy looks — drives the compact indicator
/// shown while a session is ACTIVE (a big banner is only appropriate at
/// session close; during live play it should be a glance, not a wall of
/// text).
enum BalanceSeverity { balanced, small, large }

/// Result of the end-of-session accounting check.
///
/// IMPORTANT — this is a SESSION-LEVEL check only:
///   Money In  = Total Buy-ins + Total Rebuys
///   Money Out = Total Cash-outs + Total Rake
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
        'Rake may not have been fully logged for one or more pots.',
        'A buy-in or rebuy amount may have been entered too high.',
      ];
    }
    return [
      'A buy-in or rebuy may be missing from the log.',
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

  static double _sum(String sessionId, TransactionType type, {String? playerId}) {
    return transactionsFor(sessionId)
        .where((t) => t.type == type && (playerId == null || t.playerId == playerId))
        .fold(0.0, (sum, t) => sum + t.amount);
  }

  static double totalBuyIn(String sessionId) => _sum(sessionId, TransactionType.buyIn);
  static double totalRebuy(String sessionId) => _sum(sessionId, TransactionType.rebuy);
  static double totalCashOut(String sessionId) => _sum(sessionId, TransactionType.cashOut);
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

  /// Total cash a player has taken off the table. A player who busted out
  /// with a recorded $0 cash-out correctly contributes 0 here — that is
  /// different from never having cashed out at all (see [hasCashedOut]).
  static double playerTotalCashOut(String sessionId, String playerId) {
    return _sum(sessionId, TransactionType.cashOut, playerId: playerId);
  }

  /// Whether a cash-out has been RECORDED for this player at all,
  /// regardless of amount. A $0 cash-out (busted out) counts as "settled"
  /// — it is not the same as no record existing yet.
  static bool hasCashedOut(String sessionId, String playerId) {
    return transactionsFor(sessionId)
        .any((t) => t.type == TransactionType.cashOut && t.playerId == playerId);
  }

  /// Net result once a player is done: cash-out minus everything they put
  /// in. This is purely informational/reporting — it is a *result*, never
  /// a constraint on how much someone is allowed to cash out.
  static double playerProfitLoss(String sessionId, String playerId) {
    return playerTotalCashOut(sessionId, playerId) - playerTotalIn(sessionId, playerId);
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

  /// Host profit = the house's own earnings = rake collected.
  static double hostProfit(String sessionId) => totalRake(sessionId);

  /// Cash still physically on the table (or with players): everything
  /// that came in, minus everything paid out or taken as rake. This is
  /// the live "current pot" figure — mathematically identical to the
  /// balance-check's discrepancy figure once the session is fully
  /// settled; both are shown as the same value in the UI intentionally.
  static double moneyStillInPlay(String sessionId) {
    return totalBuyIn(sessionId) +
        totalRebuy(sessionId) -
        totalCashOut(sessionId) -
        totalRake(sessionId) -
        // Subtracted ONCE, for the same reason checkBalance adds it to
        // money out: tipped chips are no longer on the table.
        totalDealerTips(sessionId);
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
    final moneyIn = totalBuyIn(sessionId) + totalRebuy(sessionId);
    // Dealer tips are counted here ONCE, alongside cash-out and rake,
    // because those chips physically left the table for the Bank. A
    // settled session that paid tips would otherwise report a false
    // discrepancy equal to the tip total.
    final moneyOut = totalCashOut(sessionId) +
        totalRake(sessionId) +
        totalDealerTips(sessionId);
    final neverCashedOut = playersFor(sessionId)
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
  }) async {
    assertSessionActive(sessionId);
    if (amount < 0) {
      throw ArgumentError('Amount cannot be negative.');
    }
    if (amount == 0 && type != TransactionType.cashOut) {
      throw ArgumentError('Amount must be greater than zero for ${type.label}.');
    }
    final player = playerId == null ? null : HiveService.players.get(playerId);
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
    await HiveService.transactions.put(tx.id, tx);
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
  }) async {
    final tx = HiveService.transactions.get(transactionId);
    if (tx == null) {
      throw StateError('Transaction not found.');
    }
    assertSessionActive(tx.sessionId);
    if (amount < 0) {
      throw ArgumentError('Amount cannot be negative.');
    }
    if (amount == 0 && tx.type != TransactionType.cashOut) {
      throw ArgumentError('Amount must be greater than zero for ${tx.type.label}.');
    }
    if (tx.requiresSignature &&
        (hostSignatureBase64 == null || hostSignatureBase64.isEmpty)) {
      throw StateError(
        'A host signature is required to confirm this edit.',
      );
    }
    final player = tx.playerId == null ? null : HiveService.players.get(tx.playerId);
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
    return tx;
  }

  /// Voids ANY transaction (not just the most recent one) — the general
  /// case used from the transaction list. Preserves the audit trail:
  /// the record stays, just excluded from every balance calculation.
  static Future<LedgerTransaction> voidTransaction(String transactionId) async {
    final tx = HiveService.transactions.get(transactionId);
    if (tx == null) throw StateError('Transaction not found.');
    assertSessionActive(tx.sessionId);
    tx.isVoided = true;
    await tx.save();
    return tx;
  }

  static Future<LedgerTransaction> unvoidTransaction(String transactionId) async {
    final tx = HiveService.transactions.get(transactionId);
    if (tx == null) throw StateError('Transaction not found.');
    assertSessionActive(tx.sessionId);
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
    if (tx != null) assertSessionActive(tx.sessionId);
    await HiveService.transactions.delete(transactionId);
  }

  /// Explicit host action: mark a player as settled/left the table.
  /// Player "active" status is no longer inferred from stack math (a
  /// winner's cash-out can exceed their buy-in, so there is no zero-stack
  /// signal to key off of) — the host says when someone is done.
  static Future<void> markPlayerSettled(Player player, {bool settled = true}) async {
    assertSessionActive(player.sessionId);
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
    last.isVoided = true;
    last.save();
    return last;
  }

  static Future<LedgerTransaction?> redo(String sessionId, String txId) async {
    assertSessionActive(sessionId);
    final tx = HiveService.transactions.get(txId);
    if (tx == null) return null;
    tx.isVoided = false;
    await tx.save();
    return tx;
  }
}
