import 'package:uuid/uuid.dart';

import '../models/bank_count.dart';
import '../models/chip_movement.dart';
import 'chip_bank_service.dart';
import 'hive_service.dart';

const _uuid = Uuid();

/// How many chips of one denomination sit somewhere.
class ChipStack {
  final String chipTypeId;
  final double chipValue;
  final int quantity;

  const ChipStack({
    required this.chipTypeId,
    required this.chipValue,
    required this.quantity,
  });

  double get totalValue => chipValue * quantity;

  ChipStack copyWith({int? quantity}) => ChipStack(
        chipTypeId: chipTypeId,
        chipValue: chipValue,
        quantity: quantity ?? this.quantity,
      );
}

/// A holding: every denomination at one location.
class ChipHolding {
  final ChipLocation location;
  final List<ChipStack> stacks;

  const ChipHolding({required this.location, required this.stacks});

  int get totalChips =>
      stacks.fold(0, (sum, s) => sum + s.quantity);

  double get totalValue =>
      stacks.fold(0.0, (sum, s) => sum + s.totalValue);

  bool get isEmpty => stacks.every((s) => s.quantity == 0);

  /// Only the denominations actually present.
  List<ChipStack> get nonEmpty =>
      stacks.where((s) => s.quantity != 0).toList();
}

/// Whole-session physical chip reconciliation.
///
/// The identity being checked:
///   starting bank = current bank + with players + on tables + removed
///
/// Every chip that left the Bank must be somewhere. [discrepancy] is the
/// part that is NOT explained by any known location — which means a real
/// movement was never written down. It is reported, never auto-corrected:
/// silently inventing chips to force a zero would destroy the only signal
/// the banker has.
class ChipReconciliation {
  final double startingBankValue;

  /// What the log says should be in the Bank.
  final double currentBankValue;

  /// What the banker actually counted in the case, when they counted.
  /// Null means not verified this session.
  final double? countedBankValue;

  final double withPlayers;
  final double onTables;
  final double removed;
  final double rakeReturnedToBank;

  /// Phase 7: house-banked game value that became casino-owned (chips
  /// lost at a house game such as roulette, reason
  /// [ChipMovementReason.houseWin]). Reported on its OWN figure — never
  /// folded into [rakeReturnedToBank] — so casino revenue stays
  /// classifiable by source (poker rake vs house-game wins).
  final double houseWinToBank;

  const ChipReconciliation({
    required this.startingBankValue,
    required this.currentBankValue,
    required this.withPlayers,
    required this.onTables,
    required this.removed,
    required this.rakeReturnedToBank,
    this.houseWinToBank = 0,
    this.countedBankValue,
  });

  /// Physical chip value across every known location, per the log.
  double get totalAccountedFor =>
      currentBankValue + withPlayers + onTables + removed;

  /// True once the banker has physically counted the case.
  bool get wasVerified => countedBankValue != null;

  /// Unexplained value: what the log expects in the Bank minus what is
  /// actually there. Positive means chips are missing.
  ///
  /// IMPORTANT — why this needs a physical count.
  /// `totalAccountedFor` is derived from the same baseline as
  /// [startingBankValue], so subtracting one from the other is an
  /// identity that is always zero. It would report "balanced" even after
  /// a genuine loss. Only comparing the derived expectation against a
  /// real count can detect a movement nobody wrote down.
  ///
  /// Without a count this returns 0 and [wasVerified] is false — the
  /// report says where everything is, but claims nothing it cannot know.
  double get discrepancy =>
      countedBankValue == null ? 0 : currentBankValue - countedBankValue!;

  /// Tolerance absorbs floating-point noise only, never a real chip.
  bool get balances => discrepancy.abs() < 0.005;

  /// Chip value currently out of the Bank and in play.
  double get inPlay => withPlayers + onTables;

  /// The money-side identity the banker checks at close:
  /// chips issued out should equal chips still in play plus chips
  /// returned. Descriptive only; never feeds settlement.
  double get issuedOut => startingBankValue - currentBankValue + rakeReturnedToBank;
}

/// One line of the reconciliation report, for a single denomination.
///
/// HOW A DISCREPANCY CAN ARISE — worth being precise about.
/// [expectedInBank] is derived: total owned minus everything the log says
/// is out in circulation. If the movement log were the only source of
/// truth, the identity would hold trivially and the report would be
/// theatre.
///
/// It becomes a real check when the banker physically counts the case and
/// supplies [countedInBank]. Then this line answers the question that
/// actually matters: does the tray in front of me match what the records
/// say should be there? A mismatch means a movement happened in the real
/// world that nobody wrote down.
class ChipAuditLine {
  final String chipTypeId;
  final double chipValue;

  /// Total chips of this denomination the banker owns, from Chip Bank.
  final int totalInventory;

  /// What SHOULD be in the case: owned minus what is out.
  final int expectedInBank;

  /// What the banker actually counted, when they did. Null means they
  /// did not count this denomination, so it is taken on trust.
  final int? countedInBank;

  final int onTables;
  final int withPlayers;
  final int removed;

  const ChipAuditLine({
    required this.chipTypeId,
    required this.chipValue,
    required this.totalInventory,
    required this.expectedInBank,
    required this.onTables,
    required this.withPlayers,
    required this.removed,
    this.countedInBank,
  });

  /// True when the banker physically verified this denomination.
  bool get wasCounted => countedInBank != null;

  /// The figure to trust for "in bank": the physical count when there is
  /// one, otherwise the derived expectation.
  int get inBank => countedInBank ?? expectedInBank;

  int get accountedFor => inBank + onTables + withPlayers + removed;

  /// Positive means chips are unaccounted for (fewer counted than
  /// expected); negative means more were found than the records allow.
  ///
  /// Always 0 for an uncounted denomination — with nothing to compare
  /// against, claiming a discrepancy would be inventing information.
  int get discrepancy =>
      countedInBank == null ? 0 : expectedInBank - countedInBank!;

  bool get balances => discrepancy == 0;

  double get discrepancyValue => discrepancy * chipValue;
}

/// The full audit.
class ChipAuditReport {
  final List<ChipAuditLine> lines;
  final DateTime generatedAt;

  ChipAuditReport({required this.lines, DateTime? generatedAt})
      : generatedAt = generatedAt ?? DateTime.now();

  bool get balances => lines.every((l) => l.balances);

  int get totalInventory =>
      lines.fold(0, (s, l) => s + l.totalInventory);
  int get totalInBank => lines.fold(0, (s, l) => s + l.inBank);
  int get totalOnTables => lines.fold(0, (s, l) => s + l.onTables);
  int get totalWithPlayers => lines.fold(0, (s, l) => s + l.withPlayers);
  int get totalRemoved => lines.fold(0, (s, l) => s + l.removed);
  int get totalAccountedFor =>
      lines.fold(0, (s, l) => s + l.accountedFor);

  /// Net chips unaccounted for across every counted denomination.
  int get chipDiscrepancy => lines.fold(0, (s, l) => s + l.discrepancy);

  double get valueDiscrepancy =>
      lines.fold(0.0, (s, l) => s + l.discrepancyValue);

  /// True once the banker has physically counted at least one
  /// denomination — i.e. this report actually verified something.
  bool get wasVerified => lines.any((l) => l.wasCounted);

  /// Denominations that do not reconcile — where to look first.
  List<ChipAuditLine> get problemLines =>
      lines.where((l) => !l.balances).toList();
}

/// Tracks where every physical chip is.
///
/// ══════════════════════════════════════════════════════════════════
/// THIS LAYER MOVES NO MONEY.
/// ══════════════════════════════════════════════════════════════════
/// It never reads or writes a LedgerTransaction, never touches a player
/// balance, and is never consulted by the settlement engine. Chip counts
/// and cash are tracked in parallel and are deliberately allowed to
/// disagree — because in a real game they do, constantly, as players win
/// chips from each other.
///
/// HOW BALANCES ARE COMPUTED
/// Every holding is DERIVED by folding the append-only movement log. No
/// running total is stored anywhere, so a holding and the audit report
/// can never drift apart: they are the same arithmetic over the same
/// records. This is why reconciliation is meaningful rather than
/// decorative.
class ChipTrackingService {
  ChipTrackingService._();

  /// Teaches ChipBankService how to read the LIVE in-bank quantity.
  ///
  /// Called once from HiveService.init(), and idempotent so tests that
  /// re-open boxes can call it again safely. Without it the Chip Bank
  /// screen would keep showing the starting inventory instead of what is
  /// actually left in the case.
  static void installBankResolver() {
    ChipBankService.liveQuantityResolver =
        (chipTypeId) => quantityAt(ChipLocation.bank, chipTypeId);
  }

  static List<ChipMovement> get _all => HiveService.chipMovements.values.toList();

  /// Every movement, newest first.
  static List<ChipMovement> allMovements({String? sessionId}) {
    final list = _all
        .where((m) => sessionId == null || m.sessionId == sessionId)
        .toList();
    list.sort((a, b) => b.timestamp.compareTo(a.timestamp));
    return list;
  }

  /// Movements touching one location, newest first.
  static List<ChipMovement> movementsFor(ChipLocation location,
      {String? sessionId}) {
    final key = location.encoded;
    return allMovements(sessionId: sessionId)
        .where((m) => m.fromLocation == key || m.toLocation == key)
        .toList();
  }

  static List<ChipMovement> movementsForPlayer(String playerId,
          {String? sessionId}) =>
      movementsFor(ChipLocation.player(playerId), sessionId: sessionId);

  /// The chip-holder reference for a session seat.
  ///
  /// Phase 2a: chip holdings are PERSON-scoped. A linked seat resolves
  /// to its `personId`, so the same human's chips stay in one holding
  /// across seats, tables and sessions. An unlinked seat keeps its own
  /// row id (the legacy reference) — identities are never invented, and
  /// unlinked records remain readable until the banker links the seat.
  ///
  /// Callers pass the seat row's fields; this service deliberately does
  /// not take a [Player] object so the chip layer stays free of
  /// session-model imports.
  static String holderRef({required String playerId, String? personId}) =>
      (personId != null && personId.isNotEmpty) ? personId : playerId;

  static List<ChipMovement> movementsForTable(String tableId,
          {String? sessionId}) =>
      movementsFor(ChipLocation.table(tableId), sessionId: sessionId);

  // -----------------------------------------------------------------
  // Recording
  // -----------------------------------------------------------------

  /// Appends one movement.
  ///
  /// Deliberately permissive: it will record a move that takes a
  /// location negative rather than refusing. A banker reconciling a
  /// messy night needs to be able to write down what actually happened;
  /// a negative balance is surfaced loudly by the audit report instead
  /// of being silently prevented. Refusing here would push them to
  /// simply not record the movement, which is far worse for the audit.
  static Future<ChipMovement> record({
    required String chipTypeId,
    required int quantity,
    required ChipLocation from,
    required ChipLocation to,
    required ChipMovementReason reason,
    String? sessionId,
    String? transactionId,
    String? note,
    double? chipValueOverride,
  }) async {
    if (quantity <= 0) {
      throw ArgumentError('Chip movement quantity must be positive');
    }
    if (from == to) {
      throw ArgumentError('Chip movement source and destination are the same');
    }

    final chip = ChipBankService.byId(chipTypeId);
    final value = chipValueOverride ?? chip?.value ?? 0;

    final movement = ChipMovement(
      id: _uuid.v4(),
      sessionId: sessionId,
      chipTypeId: chipTypeId,
      chipValue: value,
      quantity: quantity,
      fromLocation: from.encoded,
      toLocation: to.encoded,
      reason: reason.wire,
      transactionId: transactionId,
      note: note,
    );
    await HiveService.chipMovements.put(movement.id, movement);
    return movement;
  }

  /// Records a whole distribution — several denominations at once — as
  /// individual movements sharing one transaction id.
  ///
  /// [distribution] maps chipTypeId to quantity.
  static Future<List<ChipMovement>> recordDistribution({
    required Map<String, int> distribution,
    required ChipLocation from,
    required ChipLocation to,
    required ChipMovementReason reason,
    String? sessionId,
    String? transactionId,
    String? note,
  }) async {
    final made = <ChipMovement>[];
    for (final entry in distribution.entries) {
      if (entry.value <= 0) continue;
      made.add(await record(
        chipTypeId: entry.key,
        quantity: entry.value,
        from: from,
        to: to,
        reason: reason,
        sessionId: sessionId,
        transactionId: transactionId,
        note: note,
      ));
    }
    return made;
  }

  /// Removes a movement. Only for undoing a mistake made seconds ago —
  /// the UI does not expose this for historical records, because an
  /// audit log you can quietly rewrite is not an audit log.
  static Future<void> deleteMovement(String id) =>
      HiveService.chipMovements.delete(id);

  /// Deletes every movement tied to one money transaction. Used when a
  /// transaction is voided and the banker confirms the chips came back.
  static Future<int> deleteForTransaction(String transactionId) async {
    final ids = _all
        .where((m) => m.transactionId == transactionId)
        .map((m) => m.id)
        .toList();
    for (final id in ids) {
      await HiveService.chipMovements.delete(id);
    }
    return ids.length;
  }

  // -----------------------------------------------------------------
  // Reversal, edit, exchange, transfer
  //
  // All of these are expressed as ORDINARY movements appended to the log.
  // Nothing is ever mutated or deleted, so the audit trail stays intact
  // and every derived balance keeps folding the same records.
  // -----------------------------------------------------------------

  /// Movements belonging to one money transaction that are still in
  /// force — i.e. the originals minus anything already reversed.
  ///
  /// Reversals are matched by count per (chipType, from, to) triple, so
  /// reversing twice cannot double-count and a partially-reversed
  /// transaction still reports the remainder correctly.
  static List<ChipMovement> activeMovementsForTransaction(
      String transactionId) {
    final all = _all.where((m) => m.transactionId == transactionId).toList()
      ..sort((a, b) => a.timestamp.compareTo(b.timestamp));

    // Count reversal legs by their (chipType, direction) signature.
    final reversedCounts = <String, int>{};
    for (final m in all) {
      if (m.reasonEnum != ChipMovementReason.reversal) continue;
      // A reversal runs opposite to the movement it undoes.
      final key = '${m.chipTypeId}|${m.toLocation}|${m.fromLocation}';
      reversedCounts[key] = (reversedCounts[key] ?? 0) + m.quantity;
    }

    final active = <ChipMovement>[];
    for (final m in all) {
      if (m.reasonEnum == ChipMovementReason.reversal) continue;
      final key = '${m.chipTypeId}|${m.fromLocation}|${m.toLocation}';
      final cancelled = reversedCounts[key] ?? 0;
      if (cancelled >= m.quantity) {
        reversedCounts[key] = cancelled - m.quantity;
        continue;
      }
      if (cancelled > 0) reversedCounts[key] = 0;
      active.add(m);
    }
    return active;
  }

  /// True when a transaction still has chip movements in force.
  static bool hasActiveChips(String transactionId) =>
      activeMovementsForTransaction(transactionId).isNotEmpty;

  /// Appends compensating movements that undo everything currently in
  /// force for [transactionId].
  ///
  /// Used by void/undo and as the first half of an edit. Deliberately
  /// additive: the original records stay visible in the movement history
  /// so the banker can see what happened and why it was undone.
  ///
  /// Safe to call twice — the second call finds nothing active and does
  /// nothing.
  static Future<List<ChipMovement>> reverseForTransaction(
    String transactionId, {
    String? note,
  }) async {
    final active = activeMovementsForTransaction(transactionId);
    final made = <ChipMovement>[];
    for (final m in active) {
      made.add(await record(
        chipTypeId: m.chipTypeId,
        quantity: m.quantity,
        // Swapped: this is the mirror image of the original.
        from: m.to,
        to: m.from,
        reason: ChipMovementReason.reversal,
        sessionId: m.sessionId,
        transactionId: transactionId,
        note: note,
        chipValueOverride: m.chipValue,
      ));
    }
    return made;
  }

  /// Replaces a transaction's chip composition.
  ///
  /// Reverses whatever is currently in force, then applies the new
  /// composition. The end state is mathematically identical to having
  /// entered [distribution] in the first place, while the log still
  /// shows the original, the correction, and the corrected values.
  ///
  /// [from]/[to] describe the direction of the CORRECTED movement (e.g.
  /// bank -> player for a buy-in).
  static Future<List<ChipMovement>> editDistribution({
    required String transactionId,
    required Map<String, int> distribution,
    required ChipLocation from,
    required ChipLocation to,
    required ChipMovementReason reason,
    String? sessionId,
    String? note,
  }) async {
    await reverseForTransaction(transactionId, note: note ?? 'edit');
    if (distribution.isEmpty) return const [];
    return recordDistribution(
      distribution: distribution,
      from: from,
      to: to,
      reason: reason,
      sessionId: sessionId,
      transactionId: transactionId,
      note: note,
    );
  }

  /// Re-applies a previously reversed composition, for unvoid/redo.
  ///
  /// Rebuilds the distribution from the reversal legs so the restored
  /// movement matches exactly what was undone, denomination for
  /// denomination.
  static Future<List<ChipMovement>> reapplyForTransaction(
      String transactionId) async {
    if (hasActiveChips(transactionId)) return const [];

    final all = _all.where((m) => m.transactionId == transactionId).toList()
      ..sort((a, b) => a.timestamp.compareTo(b.timestamp));
    final originals =
        all.where((m) => m.reasonEnum != ChipMovementReason.reversal).toList();
    if (originals.isEmpty) return const [];

    final made = <ChipMovement>[];
    for (final m in originals) {
      made.add(await record(
        chipTypeId: m.chipTypeId,
        quantity: m.quantity,
        from: m.from,
        to: m.to,
        reason: m.reasonEnum,
        sessionId: m.sessionId,
        transactionId: transactionId,
        note: 'restored',
        chipValueOverride: m.chipValue,
      ));
    }
    return made;
  }

  /// A denomination exchange: chips in from a player, different chips
  /// out to them, at exactly equal value.
  ///
  /// Creates NO money transaction and cannot affect settlement. Both
  /// legs share an `exchange:<uuid>` tag in [ChipMovement.note], which is
  /// why no new Hive field is needed.
  ///
  /// Throws if the two sides are not exactly equal in value — unlike a
  /// buy-in there is no money leg to fall back on, so an unbalanced
  /// exchange would silently create or destroy chips.
  static Future<List<ChipMovement>> recordExchange({
    required ChipLocation counterparty,
    required Map<String, int> chipsIn,
    required Map<String, int> chipsOut,
    String? sessionId,
    ChipLocation? bank,
  }) async {
    final valueIn = valueOf(chipsIn);
    final valueOut = valueOf(chipsOut);
    if ((valueIn - valueOut).abs() > 0.005) {
      throw ArgumentError(
        'Exchange must balance: received $valueIn, given $valueOut',
      );
    }
    if (valueIn == 0) {
      throw ArgumentError('Exchange cannot be empty');
    }

    final target = bank ?? ChipLocation.bank;
    final tag = 'exchange:${_uuid.v4()}';
    final made = <ChipMovement>[];

    // Leg 1: the denominations the player hands over.
    made.addAll(await recordDistribution(
      distribution: chipsIn,
      from: counterparty,
      to: target,
      reason: ChipMovementReason.exchange,
      sessionId: sessionId,
      note: tag,
    ));
    // Leg 2: the denominations they get back.
    made.addAll(await recordDistribution(
      distribution: chipsOut,
      from: target,
      to: counterparty,
      reason: ChipMovementReason.exchange,
      sessionId: sessionId,
      note: tag,
    ));
    return made;
  }

  // Player-to-player chip transfer is REMOVED (E7): a pot being pushed
  // or players settling up is physical play, not a financial
  // operation. The ledger captures the net effect through physical
  // counts ([adjustPlayerHoldingToCount]) and the approved
  // person-scoped holding, never through recorded player↔player
  // movements. The `transfer` reason survives for parsing legacy
  // records only.

  /// Reconciles one player's RECORDED holding with the ACTUAL physical
  /// count of their stack.
  ///
  /// WHY THIS EXISTS
  /// Chip holdings are derived purely from recorded movements. Chips won
  /// at the table only enter the log when somebody records them (a P2P
  /// transfer), so a player can physically hold more than the log shows
  /// — e.g. bought in for 2M, won 3M, never recorded. A denomination
  /// exchange against that player then refuses, because it correctly
  /// trusts the log. This method is the auditable bridge: the banker
  /// counts the stack and the ledger is brought to match reality.
  ///
  /// APPEND-ONLY. Every prior movement is left exactly as stored; this
  /// appends one compensating [ChipMovementReason.adjustment] movement
  /// per denomination whose count differs, so the audit trail shows the
  /// recorded state, the count, and the correction. After the call:
  ///
  ///     derived holding == physical counted holding
  ///
  /// PHYSICAL ONLY — NO MONEY ANYWHERE.
  /// No [LedgerTransaction], no FinancialEvent, no buy-in/rebuy/cash-out,
  /// no rake, nothing the settlement engine or the Discount engine can
  /// see. A chip-only operation must stay chip-only.
  ///
  /// The compensating counterparty is the Bank: an unrecorded surplus
  /// came from somewhere the ledger never tracked, and the reconciliation
  /// report surfaces that as a bank-side discrepancy to be verified by a
  /// physical case count — the honest signal, never silently absorbed.
  ///
  /// [counted] maps chipTypeId to the number of chips physically
  /// counted; denominations absent from the map count as zero.
  /// Returns the movements appended (empty when the count already
  /// matches — nothing to record, and a zero adjustment would be noise).
  static Future<List<ChipMovement>> adjustPlayerHoldingToCount({
    required String playerId,
    required Map<String, int> counted,
    String? sessionId,
    String? note,
  }) async {
    if (playerId.isEmpty) {
      throw ArgumentError('Adjustment needs a player.');
    }
    if (counted.isEmpty) {
      throw ArgumentError('Physical count cannot be empty');
    }
    for (final q in counted.values) {
      if (q < 0) {
        throw ArgumentError('A physical count cannot be negative');
      }
    }

    final location = ChipLocation.player(playerId);
    final tag = 'count:${_uuid.v4()}';
    final made = <ChipMovement>[];

    // Every denomination that exists either in the inventory or in the
    // recorded holding — so chips the bank never stocked but the log
    // somehow holds can still be corrected.
    final ids = <String>{...counted.keys};
    for (final chip in ChipBankService.allChips()) {
      ids.add(chip.id);
    }

    for (final id in ids) {
      final target = counted[id] ?? 0;
      final held = quantityAt(location, id);
      final delta = target - held;
      if (delta == 0) continue;
      made.add(await record(
        chipTypeId: id,
        quantity: delta.abs(),
        // Surplus: chips surface into the recorded holding (bank is the
        // accounting counterparty). Shortfall: they return to it.
        from: delta > 0 ? ChipLocation.bank : location,
        to: delta > 0 ? location : ChipLocation.bank,
        reason: ChipMovementReason.adjustment,
        sessionId: sessionId,
        note: note == null
            ? '$tag recorded=$held counted=$target'
            : '$tag recorded=$held counted=$target · $note',
      ));
    }
    return made;
  }

  // -----------------------------------------------------------------
  // Derived balances
  // -----------------------------------------------------------------

  /// The latest physical case count sheet, or null when none exists.
  ///
  /// Latest by [BankCount.countedAt], with the id as a deterministic
  /// tie-break. Earlier counts remain in the box as audit history.
  static BankCount? latestBankCount() {
    try {
      final box = HiveService.bankCounts;
      BankCount? latest;
      for (final c in box.values) {
        if (latest == null) {
          latest = c;
          continue;
        }
        final cmp = c.countedAt.compareTo(latest.countedAt);
        if (cmp > 0 || (cmp == 0 && c.id.compareTo(latest.id) > 0)) {
          latest = c;
        }
      }
      return latest;
    } catch (_) {
      // Box not open (unit tests that only open the chip ledger).
      return null;
    }
  }

  /// Net quantity of one denomination at one location.
  ///
  /// BANK BASELINE (Phase 2b): the case's starting point is the LATEST
  /// physical count sheet — `latest BankCount + movements strictly
  /// AFTER its countedAt`. Only when NO count sheet exists yet does the
  /// baseline fall back to the `ChipType.quantity` record, which
  /// preserves the exact pre-2b derived values for count-less (legacy)
  /// devices — covered by an invariance test.
  ///
  /// Every other location starts empty and is built purely from
  /// movements (their timestamp is never a filter — full history).
  static int quantityAt(ChipLocation location, String chipTypeId,
      {String? sessionId}) {
    final key = location.encoded;
    int net;
    DateTime? sinceCount;

    if (location.isBank) {
      final count = latestBankCount();
      if (count != null) {
        // Counted as the physical fact; denominations absent from the
        // sheet were counted as zero (or not yet in the inventory).
        net = count.counts[chipTypeId] ?? 0;
        sinceCount = count.countedAt;
      } else {
        net = ChipBankService.byId(chipTypeId)?.quantity ?? 0;
      }
    } else {
      net = 0;
    }

    for (final m in _all) {
      if (m.chipTypeId != chipTypeId) continue;
      if (sessionId != null && m.sessionId != sessionId) continue;
      // Post-count only, and only for the bank baseline: a count
      // sheet already includes everything that happened before it.
      // Movements are included only when strictly AFTER the count —
      // a movement at the exact same instant is ambiguous and the
      // honest answer is "count again".
      if (sinceCount != null && !m.timestamp.isAfter(sinceCount)) continue;
      if (m.toLocation == key) net += m.quantity;
      if (m.fromLocation == key) net -= m.quantity;
    }
    return net;
  }

  /// Everything at one location.
  static ChipHolding holdingAt(ChipLocation location, {String? sessionId}) {
    final stacks = <ChipStack>[];
    for (final chip in ChipBankService.allChips()) {
      final qty = quantityAt(location, chip.id, sessionId: sessionId);
      if (qty == 0) continue;
      stacks.add(ChipStack(
        chipTypeId: chip.id,
        chipValue: chip.value,
        quantity: qty,
      ));
    }
    return ChipHolding(location: location, stacks: stacks);
  }

  static ChipHolding bankHolding() => holdingAt(ChipLocation.bank);

  static ChipHolding playerHolding(String playerId, {String? sessionId}) =>
      holdingAt(ChipLocation.player(playerId), sessionId: sessionId);

  static ChipHolding tableHolding(String tableId, {String? sessionId}) =>
      holdingAt(ChipLocation.table(tableId), sessionId: sessionId);

  static ChipHolding removedHolding({String? sessionId}) =>
      holdingAt(ChipLocation.removed, sessionId: sessionId);

  /// Every player currently holding chips, with their holdings.
  static Map<String, ChipHolding> allPlayerHoldings({String? sessionId}) {
    final ids = <String>{};
    for (final m in _all) {
      if (sessionId != null && m.sessionId != sessionId) continue;
      for (final loc in [m.from, m.to]) {
        if (loc.isPlayer && loc.refId != null) ids.add(loc.refId!);
      }
    }
    final result = <String, ChipHolding>{};
    for (final id in ids) {
      final holding = playerHolding(id, sessionId: sessionId);
      if (!holding.isEmpty) result[id] = holding;
    }
    return result;
  }

  /// Every table currently holding chips.
  static Map<String, ChipHolding> allTableHoldings({String? sessionId}) {
    final ids = <String>{};
    for (final m in _all) {
      if (sessionId != null && m.sessionId != sessionId) continue;
      for (final loc in [m.from, m.to]) {
        if (loc.isTable && loc.refId != null) ids.add(loc.refId!);
      }
    }
    final result = <String, ChipHolding>{};
    for (final id in ids) {
      final holding = tableHolding(id, sessionId: sessionId);
      if (!holding.isEmpty) result[id] = holding;
    }
    return result;
  }

  /// Total chip value physically in play — on tables plus with players.
  static double totalInPlayValue({String? sessionId}) {
    var total = 0.0;
    for (final h in allTableHoldings(sessionId: sessionId).values) {
      total += h.totalValue;
    }
    for (final h in allPlayerHoldings(sessionId: sessionId).values) {
      total += h.totalValue;
    }
    return total;
  }

  // -----------------------------------------------------------------
  // Reconciliation
  // -----------------------------------------------------------------

  /// Builds the audit report.
  ///
  /// THE IDENTITY BEING CHECKED
  ///   total owned = bank + tables + players + removed
  ///
  /// [physicalCount] optionally maps chipTypeId to the number the banker
  /// just counted in the case. Supplying it is what turns this from a
  /// summary into a genuine reconciliation: the expected bank figure is
  /// derived from the log, and comparing it against a real count is the
  /// only way an unrecorded movement can surface.
  ///
  /// Without a count the report still shows where everything is, but
  /// reports no discrepancy — it has nothing independent to check
  /// against, and inventing one would be dishonest.
  static ChipAuditReport audit({
    String? sessionId,
    Map<String, int>? physicalCount,
  }) {
    final lines = <ChipAuditLine>[];

    for (final chip in ChipBankService.allChips()) {
      final removed =
          quantityAt(ChipLocation.removed, chip.id, sessionId: sessionId);

      var onTables = 0;
      for (final id in _tableIds(sessionId)) {
        onTables +=
            quantityAt(ChipLocation.table(id), chip.id, sessionId: sessionId);
      }

      var withPlayers = 0;
      for (final id in _playerIds(sessionId)) {
        withPlayers +=
            quantityAt(ChipLocation.player(id), chip.id, sessionId: sessionId);
      }

      // What the case should hold right now, per the log.
      final expectedInBank = quantityAt(ChipLocation.bank, chip.id);

      // Total owned = what should be in the case plus everything out.
      final totalInventory =
          expectedInBank + onTables + withPlayers + removed;

      final line = ChipAuditLine(
        chipTypeId: chip.id,
        chipValue: chip.value,
        totalInventory: totalInventory,
        expectedInBank: expectedInBank,
        countedInBank: physicalCount?[chip.id],
        onTables: onTables,
        withPlayers: withPlayers,
        removed: removed,
      );

      // Skip denominations with nothing anywhere — a banker auditing a
      // small game should not scroll past a page of zeroes.
      if (line.totalInventory == 0 &&
          line.accountedFor == 0 &&
          !line.wasCounted) {
        continue;
      }
      lines.add(line);
    }

    return ChipAuditReport(lines: lines);
  }

  static Set<String> _tableIds(String? sessionId) {
    final ids = <String>{};
    for (final m in _all) {
      if (sessionId != null && m.sessionId != sessionId) continue;
      for (final loc in [m.from, m.to]) {
        if (loc.isTable && loc.refId != null) ids.add(loc.refId!);
      }
    }
    return ids;
  }

  static Set<String> _playerIds(String? sessionId) {
    final ids = <String>{};
    for (final m in _all) {
      if (sessionId != null && m.sessionId != sessionId) continue;
      for (final loc in [m.from, m.to]) {
        if (loc.isPlayer && loc.refId != null) ids.add(loc.refId!);
      }
    }
    return ids;
  }

  // -----------------------------------------------------------------
  // Bank inventory + session reconciliation
  // -----------------------------------------------------------------

  /// The Bank's BASELINE inventory value — the total of the LATEST
  /// count sheet, or the `ChipType.quantity` record when no count
  /// sheet exists yet (legacy fallback; identical to the pre-2b value).
  ///
  /// This is the baseline the low-inventory thresholds are measured
  /// against ("the case is nearly empty RELATIVE TO ITS LAST KNOWN
  /// COUNTED STATE"). It deliberately ignores movements.
  static double startingBankValue() {
    final count = latestBankCount();
    var total = 0.0;
    for (final c in ChipBankService.allChips()) {
      total += c.value * (count != null ? (count.counts[c.id] ?? 0) : c.quantity);
    }
    return total;
  }

  /// The Bank's CURRENT chip value: starting inventory plus everything
  /// that has come back, minus everything handed out.
  ///
  /// Derived from the movement log every time. There is deliberately no
  /// stored "current quantity" counter anywhere — a second copy could
  /// drift away from the log, and then neither number could be trusted.
  static double currentBankValue() {
    var total = 0.0;
    for (final c in ChipBankService.allChips()) {
      total += c.value * quantityAt(ChipLocation.bank, c.id);
    }
    return total;
  }

  /// Fraction of the starting inventory still in the Bank, 0..1.
  /// Returns null when no inventory has been set up, so callers can tell
  /// "nothing configured" apart from "everything gone".
  static double? bankRemainingFraction() {
    final start = startingBankValue();
    if (start <= 0) return null;
    return currentBankValue() / start;
  }

  /// Whole-session physical chip reconciliation.
  ///
  /// Answers the only question that matters at close: is every chip that
  /// ever existed still accounted for somewhere?
  /// [physicalCount] maps chipTypeId to the number the banker just
  /// counted in the case. Supplying it is what turns this from a summary
  /// into a real reconciliation — see [ChipReconciliation.discrepancy].
  static ChipReconciliation reconcile({
    String? sessionId,
    Map<String, int>? physicalCount,
  }) {
    final starting = startingBankValue();
    final inBank = currentBankValue();

    var withPlayers = 0.0;
    for (final h in allPlayerHoldings(sessionId: sessionId).values) {
      withPlayers += h.totalValue;
    }
    var onTables = 0.0;
    for (final h in allTableHoldings(sessionId: sessionId).values) {
      onTables += h.totalValue;
    }
    final removed = removedHolding(sessionId: sessionId).totalValue;

    // Rake is money-neutral here: it is counted as part of the Bank
    // because that is where the physical chips now sit.
    // Dealer tips ride alongside rake here for the same reason: those
    // chips physically sit in the Bank now. Counting them keeps the
    // reconciliation identity true — without this, a session that paid
    // tips would report the tip value as unexplained.
    // House wins (Phase 7) also physically sit in the Bank now, but
    // they are folded into their OWN figure: house-game revenue must
    // stay distinguishable from poker rake in the report.
    var rakeToBank = 0.0;
    var houseWinToBank = 0.0;
    for (final m in _all) {
      if (sessionId != null && m.sessionId != sessionId) continue;
      final r = m.reasonEnum;
      if (r == ChipMovementReason.houseWin) {
        if (m.to.isBank) houseWinToBank += m.totalValue;
        if (m.from.isBank) houseWinToBank -= m.totalValue;
        continue;
      }
      if (r != ChipMovementReason.rake &&
          r != ChipMovementReason.dealerTips) {
        continue;
      }
      if (m.to.isBank) rakeToBank += m.totalValue;
      if (m.from.isBank) rakeToBank -= m.totalValue;
    }

    double? counted;
    if (physicalCount != null && physicalCount.isNotEmpty) {
      counted = 0;
      for (final c in ChipBankService.allChips()) {
        final q = physicalCount[c.id];
        // Uncounted denominations fall back to the derived figure, so a
        // partial count only flags what was actually checked.
        counted = counted! + c.value * (q ?? quantityAt(ChipLocation.bank, c.id));
      }
    }

    return ChipReconciliation(
      startingBankValue: starting,
      currentBankValue: inBank,
      countedBankValue: counted,
      withPlayers: withPlayers,
      onTables: onTables,
      removed: removed,
      rakeReturnedToBank: rakeToBank,
      houseWinToBank: houseWinToBank,
    );
  }

  // -----------------------------------------------------------------
  // Helpers for the distribution UI
  // -----------------------------------------------------------------

  /// Total money value of a proposed distribution.
  static double valueOf(Map<String, int> distribution) {
    var total = 0.0;
    distribution.forEach((id, qty) {
      final chip = ChipBankService.byId(id);
      if (chip != null) total += chip.value * qty;
    });
    return total;
  }

  /// Suggests a distribution for [amount] from a location's holdings,
  /// greedily from the largest denomination down, never exceeding what
  /// that location actually holds.
  ///
  /// DIRECTION-CORRECT COMPOSITION (Phase 2b): the composition
  /// available to the banker follows the direction of the movement —
  /// bank-originating flows suggest from the bank; return /
  /// redemption-shaped flows suggest from the holder's (person-scoped)
  /// holding. A player's chip return is NEVER validated against bank
  /// inventory: the bank may not even hold the denominations being
  /// returned.
  ///
  /// [source] null = the Bank (the historical default).
  ///
  /// Returns whatever it can cover; the caller compares [valueOf]
  /// against the target and warns if they differ. Deliberately does not
  /// throw on an impossible amount — the banker may still want a
  /// partial suggestion to adjust by hand.
  static Map<String, int> suggestFrom(ChipLocation? source, double amount) {
    final loc = source ?? ChipLocation.bank;
    final result = <String, int>{};
    var remaining = amount;

    final chips = ChipBankService.allChips()
        .where((c) => c.value > 0)
        .toList()
      ..sort((a, b) => b.value.compareTo(a.value));

    for (final chip in chips) {
      final available = quantityAt(loc, chip.id);
      if (available <= 0) continue;
      // Epsilon guards against 0.1+0.2 style float drift leaving a
      // denomination one short.
      final wanted = (remaining + 1e-9) ~/ chip.value;
      final take = wanted > available ? available : wanted;
      if (take <= 0) continue;
      result[chip.id] = take;
      remaining -= take * chip.value;
      if (remaining <= 1e-9) break;
    }
    return result;
  }

  /// Bank-anchored suggestion — the historical API.
  static Map<String, int> suggestDistribution(double amount) =>
      suggestFrom(null, amount);

  /// Whether [source] (null = Bank) physically holds [distribution].
  static bool locationCanCover(ChipLocation? source, Map<String, int> distribution) {
    final loc = source ?? ChipLocation.bank;
    for (final e in distribution.entries) {
      if (quantityAt(loc, e.key) < e.value) return false;
    }
    return true;
  }

  /// Whether the bank physically holds a proposed distribution.
  static bool bankCanCover(Map<String, int> distribution) {
    for (final e in distribution.entries) {
      if (quantityAt(ChipLocation.bank, e.key) < e.value) return false;
    }
    return true;
  }

  // -----------------------------------------------------------------
  // Table float (Phase 2b).
  //
  // The table's imprest fund: chips the bank deliberately places at a
  // table so rake/tips and play have chips to work with. The float is
  // the table's chip location — derived, never stored.
  //
  // NEGATIVE FLOAT IS A STATE, NOT AN ERROR (E4 / Phase 0): on a
  // float-less (home) table, rake and tips debit the table location
  // and drive it negative. That is "pot consumption" — the table took
  // chips out of play beyond its float — and is reported as such by
  // the reconciliation, never treated as a discrepancy by itself. The
  // conservation identity still holds because those chips are in the
  // Bank.
  // -----------------------------------------------------------------

  /// The table's current derived chip position (float + anything else
  /// recorded at the table location). May be negative (pot
  /// consumption) — see section note.
  static double tableFloatValue(String tableId) =>
      tableHolding(tableId).totalValue;

  /// Seeds the table float: bank → table. Requires bank cover; a float
  /// can only be funded with chips the case actually holds.
  static Future<List<ChipMovement>> seedTableFloat(
    String tableId,
    Map<String, int> distribution, {
    String? sessionId,
    String? note,
  }) =>
      _floatMove(
        tableId,
        distribution,
        outbound: true,
        sessionId: sessionId,
        note: note ?? 'float seed',
      );

  /// Replenishes the table float: bank → table (same mechanics as the
  /// seed; the note keeps the audit trail saying which was which).
  static Future<List<ChipMovement>> replenishTableFloat(
    String tableId,
    Map<String, int> distribution, {
    String? sessionId,
    String? note,
  }) =>
      _floatMove(
        tableId,
        distribution,
        outbound: true,
        sessionId: sessionId,
        note: note ?? 'float replenish',
      );

  /// Returns the table float to the bank: table → bank.
  ///
  /// [counted] — the table-close count-back. When given, the movement
  /// records the COUNTED quantities (the physical fact), and the note
  /// records expected vs counted per denomination — the variance slip.
  /// The tray's derived residual after the return is deliberately left
  /// in place for the reconciliation report: a count-back NEVER
  /// auto-corrects the ledger (counts are facts, not corrections).
  /// When omitted, the entire derived tray is returned.
  static Future<List<ChipMovement>> returnTableFloat(
    String tableId, {
    Map<String, int>? counted,
    String? sessionId,
    String? note,
  }) async {
    final tray = tableHolding(tableId);
    Map<String, int> dist;
    String varianceNote;

    if (counted != null) {
      dist = {
        for (final e in counted.entries)
          if (e.value > 0) e.key: e.value,
      };
      // Expected (derived tray) vs counted, per denomination that
      // differs — the variance slip lives in the movement note.
      final diffs = <String>[];
      final ids = <String>{...dist.keys};
      for (final s in tray.nonEmpty) {
        ids.add(s.chipTypeId);
      }
      for (final id in ids) {
        final expected = quantityAt(ChipLocation.table(tableId), id);
        final actual = counted[id] ?? 0;
        if (expected != actual) {
          diffs.add('$id: expected $expected, counted $actual');
        }
      }
      varianceNote = diffs.isEmpty
          ? 'float count-back: clean'
          : 'float count-back variance — ${diffs.join('; ')}';
    } else {
      dist = {
        for (final s in tray.nonEmpty)
          if (s.quantity > 0) s.chipTypeId: s.quantity,
      };
      varianceNote = 'float return';
    }

    if (dist.isEmpty) return const [];
    return _floatMove(
      tableId,
      dist,
      outbound: false,
      sessionId: sessionId,
      note: note == null ? varianceNote : '$note · $varianceNote',
    );
  }

  /// Shared mechanics for float movements.
  ///
  /// [outbound] true = bank → table (seed/replenish): bank cover is
  /// required. [outbound] false = table → bank (return): the
  /// distribution must not exceed the derived tray UNLESS it is a
  /// count-back (the physical fact wins; the residual is reported).
  /// Count-backs pass through as-is because [returnTableFloat] builds
  /// them from the counted map — the cover check there would compare
  /// the count against the ledger, which is exactly the thing a
  /// count-back may legitimately disagree with.
  static Future<List<ChipMovement>> _floatMove(
    String tableId,
    Map<String, int> distribution, {
    required bool outbound,
    String? sessionId,
    required String note,
  }) async {
    final cleaned = {
      for (final e in distribution.entries)
        if (e.value > 0) e.key: e.value,
    };
    if (cleaned.isEmpty) return const [];
    if (outbound && !bankCanCover(cleaned)) {
      throw ArgumentError('The bank does not hold the float distribution.');
    }
    return recordDistribution(
      distribution: cleaned,
      from: outbound ? ChipLocation.bank : ChipLocation.table(tableId),
      to: outbound ? ChipLocation.table(tableId) : ChipLocation.bank,
      reason: ChipMovementReason.tableFloat,
      sessionId: sessionId,
      note: note,
    );
  }
}
