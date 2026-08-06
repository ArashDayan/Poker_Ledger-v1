import 'package:hive/hive.dart';

part 'chip_type.g.dart';

/// One denomination of physical poker chip the banker owns.
///
/// SCOPE
/// This is a real-world inventory record — a count of plastic discs in a
/// case — not part of the money ledger. It never participates in
/// settlement, player balances, or any transaction. Chip value here is
/// the denomination printed on the chip; it is deliberately NOT linked to
/// buy-ins, because a banker's chip set and their cash are separate
/// things and conflating them would corrupt the ledger.
///
/// IDENTIFICATION
/// A chip is identified by its VALUE and QUANTITY. [name] and
/// [colorValue] are both optional decoration: the inventory is fully
/// usable with neither set, which is why nothing in the maths or the
/// list rendering depends on them.
///
/// Uses typeId 9 — the next free id after 0-8. Fields are contiguous from
/// 0 so the hand-written adapter stays in step with the rest of the repo.
@HiveType(typeId: 9)
class ChipType extends HiveObject {
  @HiveField(0)
  String id;

  /// Optional label, e.g. "Premium Chip". May be empty.
  @HiveField(1)
  String? name;

  /// Optional ARGB colour, stored as an int so no Flutter type leaks into
  /// the model layer. Null means "no colour set", which is a first-class
  /// state, not a missing value.
  @HiveField(2)
  int? colorValue;

  /// Denomination printed on the chip. Required.
  @HiveField(3)
  double value;

  /// How many of this chip the banker physically owns. Required.
  @HiveField(4)
  int quantity;

  /// Free-text note, e.g. "kept in the spare case".
  @HiveField(5)
  String? note;

  @HiveField(6)
  DateTime createdAt;

  /// Last time the banker corrected the count. Shown in the UI so a stale
  /// inventory is visible rather than silently trusted.
  @HiveField(7)
  DateTime updatedAt;

  /// Reserved for the future session/table integration described in the
  /// spec: chips physically handed out to a running table.
  ///
  /// Present in the schema NOW so that adding the feature later needs no
  /// migration and no adapter change. Deliberately always 0 today —
  /// nothing reads or writes it, so it cannot affect current behaviour.
  @HiveField(8)
  int assignedToTables;

  ChipType({
    required this.id,
    required this.value,
    required this.quantity,
    this.name,
    this.colorValue,
    this.note,
    this.assignedToTables = 0,
    DateTime? createdAt,
    DateTime? updatedAt,
  })  : createdAt = createdAt ?? DateTime.now(),
        updatedAt = updatedAt ?? DateTime.now();

  /// Total money this stack of chips represents.
  double get totalValue => value * quantity;

  /// Chips not currently out on a table. Today this always equals
  /// [quantity]; it becomes meaningful when table assignment lands.
  int get availableQuantity => quantity - assignedToTables;

  /// True when a colour has actually been chosen. Used by the UI to
  /// decide between a colour swatch and a neutral value badge.
  bool get hasColor => colorValue != null;

  /// True when the banker gave this chip a label.
  bool get hasName => name != null && name!.trim().isNotEmpty;

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'colorValue': colorValue,
        'value': value,
        'quantity': quantity,
        'note': note,
        'createdAt': createdAt.toIso8601String(),
        'updatedAt': updatedAt.toIso8601String(),
        'assignedToTables': assignedToTables,
      };

  static ChipType fromJson(Map<String, dynamic> j) => ChipType(
        id: j['id'] as String,
        name: j['name'] as String?,
        colorValue: j['colorValue'] as int?,
        value: (j['value'] as num).toDouble(),
        quantity: (j['quantity'] as num).toInt(),
        note: j['note'] as String?,
        assignedToTables: (j['assignedToTables'] as num?)?.toInt() ?? 0,
        createdAt: DateTime.tryParse(j['createdAt']?.toString() ?? ''),
        updatedAt: DateTime.tryParse(j['updatedAt']?.toString() ?? ''),
      );
}
