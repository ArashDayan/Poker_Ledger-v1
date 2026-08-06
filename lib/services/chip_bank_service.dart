import 'package:uuid/uuid.dart';

import '../models/chip_type.dart';
import 'hive_service.dart';

const _uuid = Uuid();

/// Aggregate totals for the whole chip bank.
class ChipBankSummary {
  /// Sum of value x quantity across every chip type.
  final double totalValue;

  /// Total number of physical chips owned.
  final int totalChips;

  /// How many distinct denominations are defined.
  final int typeCount;

  const ChipBankSummary({
    required this.totalValue,
    required this.totalChips,
    required this.typeCount,
  });

  static const empty =
      ChipBankSummary(totalValue: 0, totalChips: 0, typeCount: 0);
}

/// Owns the banker's physical chip inventory.
///
/// STRICTLY SEPARATE FROM THE LEDGER
/// This service reads and writes ONE Hive box of its own. It never
/// touches sessions, players, transactions, or the settlement engine, and
/// nothing in those paths reads chip inventory. A wrong chip count can
/// therefore never move a single unit of money — which is the whole
/// reason it is modelled as its own module rather than bolted onto
/// SessionService.
class ChipBankService {
  ChipBankService._();

  static List<ChipType> get _all => HiveService.chips.values.toList();

  /// Every chip type, ordered by denomination (highest first).
  ///
  /// Sorted by VALUE rather than name or insertion order because value is
  /// the required field — the list must read sensibly for a banker who
  /// never entered a single name or colour.
  static List<ChipType> allChips() {
    final list = _all;
    list.sort((a, b) {
      final byValue = b.value.compareTo(a.value);
      if (byValue != 0) return byValue;
      // Stable tie-break so equal denominations don't shuffle between
      // rebuilds.
      return a.createdAt.compareTo(b.createdAt);
    });
    return list;
  }

  static ChipType? byId(String id) => HiveService.chips.get(id);

  /// Adds a denomination. Returns the created record.
  ///
  /// [value] and [quantity] are required; name and colour are optional
  /// and may be left null forever.
  static Future<ChipType> addChip({
    required double value,
    required int quantity,
    String? name,
    int? colorValue,
    String? note,
  }) async {
    final chip = ChipType(
      id: _uuid.v4(),
      value: value,
      quantity: quantity < 0 ? 0 : quantity,
      name: (name == null || name.trim().isEmpty) ? null : name.trim(),
      colorValue: colorValue,
      note: (note == null || note.trim().isEmpty) ? null : note.trim(),
    );
    await HiveService.chips.put(chip.id, chip);
    return chip;
  }

  /// Edits any subset of a chip's fields.
  ///
  /// Uses explicit `clearName` / `clearColor` flags because null is a
  /// meaningful value here: "leave unchanged" and "remove the colour" are
  /// different intentions, and a plain nullable parameter cannot express
  /// both.
  static Future<void> updateChip(
    String id, {
    double? value,
    int? quantity,
    String? name,
    int? colorValue,
    String? note,
    bool clearName = false,
    bool clearColor = false,
    bool clearNote = false,
  }) async {
    final chip = HiveService.chips.get(id);
    if (chip == null) return;

    if (value != null) chip.value = value;
    if (quantity != null) chip.quantity = quantity < 0 ? 0 : quantity;

    if (clearName) {
      chip.name = null;
    } else if (name != null) {
      chip.name = name.trim().isEmpty ? null : name.trim();
    }

    if (clearColor) {
      chip.colorValue = null;
    } else if (colorValue != null) {
      chip.colorValue = colorValue;
    }

    if (clearNote) {
      chip.note = null;
    } else if (note != null) {
      chip.note = note.trim().isEmpty ? null : note.trim();
    }

    chip.updatedAt = DateTime.now();
    await chip.save();
  }

  /// Sets an absolute count — the "I recounted the case" operation, which
  /// is how the spec describes day-to-day use.
  static Future<void> setQuantity(String id, int quantity) =>
      updateChip(id, quantity: quantity);

  /// Adjusts a count by a delta, clamped at zero so an inventory can
  /// never go negative.
  static Future<void> adjustQuantity(String id, int delta) async {
    final chip = HiveService.chips.get(id);
    if (chip == null) return;
    await updateChip(id, quantity: chip.quantity + delta);
  }

  static Future<void> removeChip(String id) => HiveService.chips.delete(id);

  /// Removes every chip type. Only reachable behind a confirmation.
  static Future<void> clearAll() => HiveService.chips.clear();

  /// Totals across the whole bank.
  static ChipBankSummary summary() {
    final chips = _all;
    if (chips.isEmpty) return ChipBankSummary.empty;

    var totalValue = 0.0;
    var totalChips = 0;
    for (final c in chips) {
      totalValue += c.totalValue;
      totalChips += c.quantity;
    }
    return ChipBankSummary(
      totalValue: totalValue,
      totalChips: totalChips,
      typeCount: chips.length,
    );
  }

  // -----------------------------------------------------------------
  // FUTURE SESSION / TABLE INTEGRATION
  //
  // Read-only seams, deliberately not wired into session start-up. The
  // spec asked to prepare for this WITHOUT forcing automatic deduction,
  // so these are pure queries: they compute an answer and change
  // nothing. A future screen can call them before seating a table, and
  // no existing code path is affected because nothing calls them today.
  // -----------------------------------------------------------------

  /// Whether the bank physically holds at least [amount] in chips.
  static bool hasEnoughValue(double amount) =>
      summary().totalValue >= amount;

  /// Total chip value the banker could hand out right now.
  ///
  /// Uses [ChipType.availableQuantity], so it already accounts for chips
  /// assigned to tables once that feature is turned on.
  static double availableValue() {
    var total = 0.0;
    for (final c in _all) {
      total += c.value * c.availableQuantity;
    }
    return total;
  }

  /// Shortfall between what a session needs and what is in the case.
  /// Returns 0 when the inventory is sufficient.
  static double shortfallFor(double requiredValue) {
    final available = availableValue();
    final gap = requiredValue - available;
    return gap > 0 ? gap : 0;
  }
}
