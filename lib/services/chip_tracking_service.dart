import 'package:uuid/uuid.dart';

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
  // Derived balances
  // -----------------------------------------------------------------

  /// Net quantity of one denomination at one location.
  static int quantityAt(ChipLocation location, String chipTypeId,
      {String? sessionId}) {
    final key = location.encoded;
    var net = 0;

    // The bank's balance starts from the physical count the banker
    // entered in Chip Bank; every other location starts empty and is
    // built purely from movements.
    if (location.isBank) {
      net = ChipBankService.byId(chipTypeId)?.quantity ?? 0;
    }

    for (final m in _all) {
      if (m.chipTypeId != chipTypeId) continue;
      if (sessionId != null && m.sessionId != sessionId) continue;
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

  /// Suggests a distribution for [amount], greedily from the largest
  /// denomination down, never exceeding what the bank actually holds.
  ///
  /// Returns whatever it can cover; the caller compares [valueOf] against
  /// the target and warns if they differ. Deliberately does not throw on
  /// an impossible amount — the banker may still want a partial
  /// suggestion to adjust by hand.
  static Map<String, int> suggestDistribution(double amount) {
    final result = <String, int>{};
    var remaining = amount;

    final chips = ChipBankService.allChips()
        .where((c) => c.value > 0)
        .toList()
      ..sort((a, b) => b.value.compareTo(a.value));

    for (final chip in chips) {
      final available = quantityAt(ChipLocation.bank, chip.id);
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

  /// Whether the bank physically holds a proposed distribution.
  static bool bankCanCover(Map<String, int> distribution) {
    for (final e in distribution.entries) {
      if (quantityAt(ChipLocation.bank, e.key) < e.value) return false;
    }
    return true;
  }
}
