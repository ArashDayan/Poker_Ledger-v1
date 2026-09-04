import 'package:uuid/uuid.dart';

import '../models/chip_type.dart';
import 'dual_verification_service.dart';
import 'hive_service.dart';

const _uuid = Uuid();

/// Aggregate totals for the whole chip bank.
class ChipBankSummary {
  /// Value of the chips physically IN THE BANK right now.
  ///
  /// Derived: starting inventory plus everything returned, minus
  /// everything handed out. This is what the banker sees on the Chip
  /// Bank screen, so it has to move the moment chips leave or come back.
  final double totalValue;

  /// Number of chips physically in the Bank right now.
  final int totalChips;

  /// How many distinct denominations are defined.
  final int typeCount;

  /// The Bank's starting inventory value, before any movement. Kept
  /// alongside the live figure so the screen can show both, and so the
  /// low-inventory thresholds have a stable baseline to measure against.
  final double startingValue;

  /// Chips owned in total, ignoring movements.
  final int startingChips;

  const ChipBankSummary({
    required this.totalValue,
    required this.totalChips,
    required this.typeCount,
    this.startingValue = 0,
    this.startingChips = 0,
  });

  /// Value currently out of the Bank — with players or on tables.
  double get outValue => startingValue - totalValue;

  /// Fraction of the starting inventory still in the Bank, or null when
  /// no inventory has been configured.
  double? get remainingFraction =>
      startingValue <= 0 ? null : totalValue / startingValue;

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
  ///
  /// D1 (finalised): creating owned inventory IS a manual inventory
  /// adjustment (previous 0 -> counted N) and always requires the
  /// two-person authorisation -- no threshold, and no exemption for
  /// the first denomination, so remove-and-readd can never bypass the
  /// gate.
  static Future<ChipType> addChip({
    required double value,
    required int quantity,
    String? name,
    int? colorValue,
    String? note,
    required DualAuthorization authorization,
  }) async {
    DualVerificationService.requireAlways(
        authorization, 'a chip bank inventory addition');
    final chip = ChipType(
      id: _uuid.v4(),
      value: value,
      quantity: quantity < 0 ? 0 : quantity,
      name: (name == null || name.trim().isEmpty) ? null : name.trim(),
      colorValue: colorValue,
      note: (note == null || note.trim().isEmpty) ? null : note.trim(),
    );
    await HiveService.chips.put(chip.id, chip);
    await DualVerificationService.recordAlways(
      operation: 'inventory_adjustment',
      authorization: authorization,
      chipTypeId: chip.id,
      previousQuantity: 0,
      countedQuantity: chip.quantity,
      denominationValue: chip.value,
    );
    return chip;
  }

  /// Edits any subset of a chip's fields.
  ///
  /// Uses explicit `clearName` / `clearColor` flags because null is a
  /// meaningful value here: "leave unchanged" and "remove the colour" are
  /// different intentions, and a plain nullable parameter cannot express
  /// both.
  ///
  /// D1 (finalised): a change to the owned QUANTITY or the unit VALUE
  /// is a manual inventory adjustment and ALWAYS requires the
  /// two-person authorisation -- no threshold. A purely cosmetic edit
  /// (name / colour / note) is not an inventory adjustment and stays
  /// single-operator.
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
    DualAuthorization? authorization,
  }) async {
    final chip = HiveService.chips.get(id);
    if (chip == null) return;

    final previousQuantity = chip.quantity;
    final previousValue = chip.value;
    final quantityChanges = quantity != null && quantity != previousQuantity;
    final valueChanges = value != null && value != previousValue;
    final inventoryChange = quantityChanges || valueChanges;
    if (inventoryChange) {
      if (authorization == null) {
        throw StateError(
          'A manual chip bank inventory adjustment always requires '
          'second-person verification.',
        );
      }
      DualVerificationService.requireAlways(
          authorization, 'a chip bank inventory adjustment');
    }

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

    if (inventoryChange) {
      await DualVerificationService.recordAlways(
        operation: 'inventory_adjustment',
        authorization: authorization!,
        chipTypeId: id,
        previousQuantity: previousQuantity,
        countedQuantity: chip.quantity,
        denominationValue: chip.value,
        detail: valueChanges
            ? 'unit value $previousValue -> ${chip.value}'
            : null,
      );
    }
  }


  /// Sets the INVENTORY record (chips owned), e.g. after genuinely
  /// acquiring or destroying chips.
  ///
  /// SEMANTICS (Phase 2b): this is NOT "I recounted the case" and it is
  /// NOT a variance correction. Recounting the case is a [BankCount]
  /// (count sheet) -- a physical fact that becomes the case ledger's
  /// baseline. Once any count sheet exists, editing [ChipType.quantity]
  /// no longer moves the case ledger baseline at all; it only updates
  /// the owned-inventory record. Variances are documented through
  /// counts + the reconciliation report, never by rewriting a number
  /// here (no silent history rewrites).
  ///
  /// D1 (finalised): always a two-person inventory adjustment.
  static Future<void> setQuantity(
    String id,
    int quantity, {
    required DualAuthorization authorization,
  }) =>
      updateChip(id, quantity: quantity, authorization: authorization);

  /// Adjusts a count by a delta, clamped at zero so an inventory can
  /// never go negative. D1 (finalised): always a two-person inventory
  /// adjustment -- the +/- steppers on the Chip Bank screen route
  /// through the same authorisation flow as every other correction.
  static Future<void> adjustQuantity(
    String id,
    int delta, {
    required DualAuthorization authorization,
  }) async {
    final chip = HiveService.chips.get(id);
    if (chip == null) return;
    await updateChip(
      id,
      quantity: chip.quantity + delta,
      authorization: authorization,
    );
  }

  /// Removes a denomination. D1 (finalised): removing owned inventory
  /// (previous N -> counted 0) is always a two-person inventory
  /// adjustment, audited on the immutable two-actor event stream.
  static Future<void> removeChip(
    String id, {
    required DualAuthorization authorization,
  }) async {
    final chip = HiveService.chips.get(id);
    if (chip == null) return;
    DualVerificationService.requireAlways(
        authorization, 'a chip bank inventory removal');
    await HiveService.chips.delete(id);
    await DualVerificationService.recordAlways(
      operation: 'inventory_adjustment',
      authorization: authorization,
      chipTypeId: id,
      previousQuantity: chip.quantity,
      countedQuantity: 0,
      denominationValue: chip.value,
    );
  }


  /// NOTE: a bulk "clear every chip type" primitive was removed as a
  /// dead path with no caller — a silent wipe of the whole inventory is
  /// exactly the kind of destructive operation that must not survive as
  /// an unreachable-but-public API.

  /// Totals across the whole bank.
  /// Totals for the bank.
  ///
  /// [ChipBankSummary.totalValue] is LIVE — it folds the movement log so
  /// handing chips to a player lowers it immediately. [ChipType.quantity]
  /// stays the untouched STARTING count; deducting from it as well would
  /// double-count, because quantityAt() already starts from it.
  ///
  /// The live figure is resolved through a callback so this service does
  /// not import the tracking service (which imports this one).
  static ChipBankSummary summary() {
    final chips = _all;
    if (chips.isEmpty) return ChipBankSummary.empty;

    var startingValue = 0.0;
    var startingChips = 0;
    for (final c in chips) {
      startingValue += c.totalValue;
      startingChips += c.quantity;
    }

    final resolver = liveQuantityResolver;
    if (resolver == null) {
      // No resolver installed (e.g. a unit test touching only the bank):
      // fall back to the starting counts rather than reporting zero.
      return ChipBankSummary(
        totalValue: startingValue,
        totalChips: startingChips,
        typeCount: chips.length,
        startingValue: startingValue,
        startingChips: startingChips,
      );
    }

    var liveValue = 0.0;
    var liveChips = 0;
    for (final c in chips) {
      final q = resolver(c.id);
      liveValue += c.value * q;
      liveChips += q;
    }
    return ChipBankSummary(
      totalValue: liveValue,
      totalChips: liveChips,
      typeCount: chips.length,
      startingValue: startingValue,
      startingChips: startingChips,
    );
  }

  /// Supplies the live in-bank quantity for a chip type.
  ///
  /// Injected by ChipTrackingService at startup. This indirection exists
  /// purely to avoid a circular import: the tracking service already
  /// depends on this one for the baseline count.
  static int Function(String chipTypeId)? liveQuantityResolver;

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
