import 'package:hive/hive.dart';

part 'bank_count.g.dart';

/// One physical count of the banker's case — a count sheet.
///
/// WHY THIS EXISTS (Phase 2b)
/// The case ledger needs a baseline that is a PHYSICAL FACT, not the
/// mutable inventory record. [ChipType.quantity] is "chips owned" and
/// is editable at any time; a [BankCount] is "what was actually in the
/// case at this moment", taken by the banker. The bank's derived
/// holdings are:
///
///     latest BankCount  +  movements strictly after its countedAt
///
/// and only fall back to the `quantity` baseline when NO count sheet
/// exists yet (legacy devices keep their exact pre-2b derived values
/// until the first count is taken — covered by an invariance test).
///
/// COUNTS ARE FACTS, NOT CORRECTIONS
/// Taking a count never edits any movement, transaction, quantity or
/// financial record. If the case disagrees with the derived
/// expectation, that is a VARIANCE to be reported and investigated —
/// never auto-corrected. (Silently forcing a zero would destroy the
/// only signal the banker has — same rule as the chip audit.)
///
/// MULTIPLE COUNTS
/// The LATEST count (by countedAt, id as deterministic tie-break) is
/// the baseline. Earlier counts stay in the box as audit history.
///
/// STORAGE
/// typeId 17 — the next free id after 15/16 (reserved). Lives in its
/// own fail-loud box: a corrupted count-sheet file must surface, not
/// silently wipe the baseline history.
@HiveType(typeId: 17)
class BankCount extends HiveObject {
  @HiveField(0)
  String id;

  /// When the physical count was taken. This is the baseline anchor:
  /// only movements strictly AFTER this instant are added on top of
  /// the counted quantities.
  @HiveField(1)
  DateTime countedAt;

  /// chipTypeId -> physical quantity in the case at [countedAt].
  /// Denominations absent from the map were counted as zero (or were
  /// not yet in the inventory) — the fold treats them as 0.
  @HiveField(2)
  Map<String, int> counts;

  /// Context for the count: e.g. "session opening", "session close",
  /// "audit recount". Descriptive; the baseline math ignores it.
  @HiveField(3)
  String? note;

  @HiveField(4)
  DateTime createdAt;

  BankCount({
    required this.id,
    required this.countedAt,
    required this.counts,
    this.note,
    DateTime? createdAt,
  }) : createdAt = createdAt ?? DateTime.now();

  Map<String, dynamic> toJson() => {
        'id': id,
        'countedAt': countedAt.toIso8601String(),
        'counts': {
          for (final e in counts.entries) e.key: e.value,
        },
        'note': note,
        'createdAt': createdAt.toIso8601String(),
      };

  static BankCount fromJson(Map<String, dynamic> j) => BankCount(
        id: j['id'] as String,
        countedAt: DateTime.parse(j['countedAt'] as String),
        counts: (j['counts'] as Map? ?? {})
            .map((k, v) => MapEntry(k as String, (v as num).toInt())),
        note: j['note'] as String?,
        createdAt:
            DateTime.tryParse(j['createdAt']?.toString() ?? '') ??
                DateTime.now(),
      );
}
